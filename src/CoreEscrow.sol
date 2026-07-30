// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICoreEscrow} from "./interfaces/ICoreEscrow.sol";
import {ICreditLedger} from "./interfaces/ICreditLedger.sol";
import {ICoordinator} from "./interfaces/ICoordinator.sol";
import {DealHashing} from "./libraries/DealHashing.sol";
import {SettlementMath} from "./libraries/SettlementMath.sol";
import {
    Deal,
    DealTerms,
    FundingSpec,
    FundingAuth,
    ResolutionAction,
    ResolutionAuth,
    TerminalRecord,
    TerminalAllocation,
    DealState,
    Outcome,
    isTerminal
} from "./libraries/DealTypes.sol";
import {
    DealExists,
    Expired,
    InvalidBps,
    InvalidSignature,
    InvalidState,
    InvalidTerms,
    InvalidTiming,
    NonceUsed,
    ProfileNotSelected,
    TerminalDeal,
    Unauthorized,
    ZeroAddress
} from "./libraries/CoreErrors.sol";

/// @notice Tokenless CoreEscrow state machine per PROTOCOL.md §8.
/// @dev Never imports IERC20 or touches tokens. All custody via Ledger.
contract CoreEscrow is ICoreEscrow {
    using SettlementMath for uint256;

    // ── EIP-712 ────────────────────────────────────────────────────────────────

    bytes32 private constant _TYPE_HASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 private constant _NAME_HASH = keccak256(bytes("PluriSwap"));
    bytes32 private constant _VERSION_HASH = keccak256(bytes("2"));

    // ── Immutables ──────────────────────────────────────────────────────────────

    uint64 public immutable chainId;
    uint32 public immutable protocolVersion;
    bytes32 public immutable charterHash;
    bytes32 public immutable techSpecHash;
    ICreditLedger public immutable ledger;
    ICoordinator public immutable coordinator;
    bytes32 public immutable DOMAIN_SEPARATOR;
    bytes32 public immutable manifestHash;

    // ── State ───────────────────────────────────────────────────────────────────

    mapping(bytes32 => Deal) internal _deals;
    mapping(bytes32 => TerminalRecord) internal _terminalRecords;
    mapping(bytes32 => bool) internal _dealExists;
    mapping(address => mapping(uint256 => bool)) internal _holderNonceUsed;
    mapping(bytes32 => mapping(uint8 => mapping(uint256 => bool))) internal _resolutionNonceUsed;

    uint256 private _locked = 1;

    modifier nonReentrant() {
        require(_locked == 1, "REENTRANCY");
        _locked = 2;
        _;
        _locked = 1;
    }

    constructor(
        uint64 chainId_,
        uint32 protocolVersion_,
        bytes32 charterHash_,
        bytes32 techSpecHash_,
        address ledger_,
        address coordinator_,
        bytes32 manifestHash_
    ) {
        if (ledger_ == address(0) || coordinator_ == address(0)) revert ZeroAddress();
        if (ledger_ == coordinator_ || ledger_ == address(this) || coordinator_ == address(this)) {
            revert InvalidTerms();
        }
        chainId = chainId_;
        protocolVersion = protocolVersion_;
        charterHash = charterHash_;
        techSpecHash = techSpecHash_;
        ledger = ICreditLedger(ledger_);
        coordinator = ICoordinator(coordinator_);
        manifestHash = manifestHash_;
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(_TYPE_HASH, _NAME_HASH, _VERSION_HASH, uint256(chainId_), address(this))
        );
    }

    receive() external payable { revert(); }
    fallback() external payable { revert(); }

    // ── Activation ──────────────────────────────────────────────────────────────

    function activate(
        DealTerms calldata terms,
        FundingSpec calldata principalFunding,
        FundingSpec calldata activationFeeFunding,
        FundingAuth calldata principalFundingAuth,
        FundingAuth calldata activationFeeFundingAuth,
        bytes calldata principalFundingSig,
        bytes calldata activationFeeFundingSig,
        bytes calldata holderSig,
        bytes calldata providerSig
    ) external nonReentrant returns (bytes32 dealId) {
        // ── Core-only validation ────────────────────────────────────────────────
        if (terms.profileFlags != 0) revert ProfileNotSelected();
        if ((terms.packageSelectionHash | terms.packageContestTermsHash |
             terms.poolAuthorityHash | terms.arbitrationTermsHash |
             terms.reservationsHash | terms.modulesHash | terms.extensionsHash) != bytes32(0))
            revert ProfileNotSelected();

        // ── Basic field validation ──────────────────────────────────────────────
        if (terms.holder == address(0) || terms.provider == address(0)) revert ZeroAddress();
        if (terms.token == address(0)) revert ZeroAddress();
        if (terms.principal == 0) revert InvalidTerms();
        if (terms.disputeTimeoutProviderBps > 10_000) revert InvalidBps();
        if (terms.fiatDuration == 0 || terms.releaseDuration == 0) revert InvalidTerms();
        if (block.timestamp >= terms.createExpiry) revert Expired();
        if (terms.holder == terms.provider) revert InvalidTerms();
        if (terms.completionFee > terms.principal) revert InvalidTerms();
        if (terms.completionFee > 0 && terms.completionFeeRecipient == address(0)) revert ZeroAddress();
        if (terms.activationFee > 0 && terms.activationFeeRecipient == address(0)) revert ZeroAddress();

        // ── Custody boundary verification ──────────────────────────────────────
        bytes32 expectedBoundary = DealHashing.custodyBoundaryId(
            chainId, protocolVersion, address(ledger), terms.token
        );
        if (terms.custodyBoundaryId != expectedBoundary) revert InvalidTerms();

        // ── Funding spec hash verification ──────────────────────────────────────
        bytes32 principalSpecHash = DealHashing.hashFundingSpec(principalFunding);
        if (terms.principalFundingHash != principalSpecHash) revert InvalidTerms();
        if (terms.activationFee > 0) {
            bytes32 feeSpecHash = DealHashing.hashFundingSpec(activationFeeFunding);
            if (terms.activationFeeFundingHash != feeSpecHash) revert InvalidTerms();
        } else {
            if (terms.activationFeeFundingHash != bytes32(0)) revert InvalidTerms();
        }

        // ── Compute dealId and check non-existence ──────────────────────────────
        dealId = DealHashing.hashDealTerms(terms);
        if (_dealExists[dealId]) revert DealExists();

        // ── Verify party signatures on terms ────────────────────────────────────
        bytes32 termsDigest = DealHashing.digest(DOMAIN_SEPARATOR, dealId);
        _verifySigner(terms.holder, termsDigest, holderSig);
        _verifySigner(terms.provider, termsDigest, providerSig);

        // ── Verify holder nonce ─────────────────────────────────────────────────
        if (_holderNonceUsed[terms.holder][terms.nonce]) revert NonceUsed();

        // ── Fund via Ledger (pulls tokens, creates positions) ────────────────────
        ledger.fundDealAndReservations(
            dealId,
            terms.token,
            terms.principal,
            terms.activationFee,
            terms.activationFeeRecipient,
            principalFunding,
            activationFeeFunding,
            principalFundingAuth,
            activationFeeFundingAuth,
            principalFundingSig,
            activationFeeFundingSig
        );

        // ── Mark nonce used ─────────────────────────────────────────────────────
        _holderNonceUsed[terms.holder][terms.nonce] = true;

        // ── Snapshot deal ──────────────────────────────────────────────────────
        address holderReceiver =
            terms.holderReceiver != address(0) ? terms.holderReceiver : terms.holder;
        address providerReceiver =
            terms.providerReceiver != address(0) ? terms.providerReceiver : terms.provider;

        uint64 now_ = uint64(block.timestamp);
        _deals[dealId] = Deal({
            state: DealState.Funded,
            outcome: Outcome.Invalid,
            holder: terms.holder,
            provider: terms.provider,
            holderReceiver: holderReceiver,
            providerReceiver: providerReceiver,
            token: terms.token,
            principal: terms.principal,
            activationFee: terms.activationFee,
            activationFeeRecipient: terms.activationFeeRecipient,
            completionFee: terms.completionFee,
            completionFeeRecipient: terms.completionFeeRecipient,
            disputeTimeoutProviderBps: terms.disputeTimeoutProviderBps,
            activatedAt: now_,
            fiatDeadline: SettlementMath.checkedAdd64(now_, terms.fiatDuration),
            releaseDuration: terms.releaseDuration,
            releaseDeadline: 0,
            disputeDuration: terms.disputeDuration,
            disputeDeadline: 0,
            profileFlags: 0,
            termsHash: dealId,
            custodyBoundaryId: terms.custodyBoundaryId,
            modulesHash: bytes32(0),
            terminalHash: bytes32(0)
        });
        _dealExists[dealId] = true;

        emit DealActivated(dealId, terms.holder, terms.provider, terms.token, terms.principal);
    }

    // ── Core transitions ─────────────────────────────────────────────────────────

    /// @notice CASE-CORE-002: Provider marks fiat sent.
    function markFiatSent(bytes32 dealId) external nonReentrant {
        Deal storage d = _deals[dealId];
        if (d.state != DealState.Funded) revert InvalidState();
        if (msg.sender != d.provider) revert Unauthorized();

        d.state = DealState.FiatSent;
        d.releaseDeadline = SettlementMath.checkedAdd64(
            uint64(block.timestamp), d.releaseDuration
        );

        emit FiatSent(dealId);
    }

    /// @notice CASE-CORE-004: Provider cancels before fiat is marked.
    function providerCancel(bytes32 dealId) external nonReentrant {
        Deal storage d = _deals[dealId];
        if (d.state != DealState.Funded) revert InvalidState();
        if (msg.sender != d.provider) revert Unauthorized();

        _settle(d, dealId, DealState.Cancelled, Outcome.ProviderCancel, 0);
    }

    /// @notice CASE-CORE-005: Anyone executes fiat timeout.
    function fiatTimeoutCancel(bytes32 dealId) external nonReentrant {
        Deal storage d = _deals[dealId];
        if (d.state != DealState.Funded) revert InvalidState();
        if (block.timestamp < d.fiatDeadline) revert InvalidTiming();

        _settle(d, dealId, DealState.Cancelled, Outcome.FiatTimeoutCancel, 0);
    }

    /// @notice CASE-CORE-007: Holder releases to provider.
    function holderRelease(bytes32 dealId) external nonReentrant {
        Deal storage d = _deals[dealId];
        if (d.state != DealState.FiatSent) revert InvalidState();
        if (msg.sender != d.holder) revert Unauthorized();

        _settle(d, dealId, DealState.Released, Outcome.VoluntaryRelease, 10_000);
    }

    /// @notice CASE-CORE-009: Permissionless claim after release deadline.
    function claim(bytes32 dealId) external nonReentrant {
        Deal storage d = _deals[dealId];
        if (d.state != DealState.FiatSent) revert InvalidState();
        if (block.timestamp < d.releaseDeadline) revert InvalidTiming();

        _settle(d, dealId, DealState.Released, Outcome.TimeoutClaim, 10_000);
    }

    /// @notice CASE-CORE-021: Holder opens Core dispute.
    function openDispute(bytes32 dealId, bytes calldata openData) external nonReentrant {
        Deal storage d = _deals[dealId];
        if (d.state != DealState.FiatSent) revert InvalidState();
        if (msg.sender != d.holder) revert Unauthorized();
        if (block.timestamp >= d.releaseDeadline) revert InvalidTiming();

        d.state = DealState.Disputed;
        d.disputeDeadline = SettlementMath.checkedAdd64(
            uint64(block.timestamp), d.disputeDuration
        );

        emit DisputeOpened(dealId, msg.sender);
    }

    /// @notice CASE-CORE-025: Permissionless dispute timeout residual.
    function disputeTimeout(bytes32 dealId) external nonReentrant {
        Deal storage d = _deals[dealId];
        if (d.state != DealState.Disputed) revert InvalidState();
        if (block.timestamp < d.disputeDeadline) revert InvalidTiming();

        _settle(d, dealId, DealState.ResolvedByDisputeTimeout, Outcome.DisputeTimeout,
            d.disputeTimeoutProviderBps);
    }

    /// @notice CASE-CORE-006/011/022, 026, 012/024: Dual-signed resolution.
    function mutualResolve(
        bytes32 dealId,
        ResolutionAuth calldata auth,
        bytes calldata holderSig,
        bytes calldata providerSig
    ) external nonReentrant {
        Deal storage d = _deals[dealId];
        if (!_dealExists[dealId]) revert InvalidState();
        if (isTerminal(d.state)) revert TerminalDeal();

        // ── Validate auth ──────────────────────────────────────────────────────
        if (auth.dealId != dealId) revert InvalidTerms();
        if (auth.extensionsHash != bytes32(0)) revert InvalidTerms();
        if (auth.providerShareBps > 10_000) revert InvalidBps();
        if (block.timestamp >= auth.expiry) revert Expired();
        if (_resolutionNonceUsed[dealId][auth.action][auth.resolutionNonce]) revert NonceUsed();

        // ── Validate action vs state ─────────────────────────────────────────────
        uint8 action = auth.action;
        if (action == uint8(ResolutionAction.MutualCancel)) {
            if (auth.providerShareBps != 0) revert InvalidBps();
            // Valid from FUNDED, FIAT_SENT, DISPUTED
        } else if (action == uint8(ResolutionAction.CosignedRelease)) {
            if (auth.providerShareBps != 10_000) revert InvalidBps();
            if (d.state == DealState.Funded) revert InvalidState();
            // Valid from FIAT_SENT, DISPUTED
        } else if (action == uint8(ResolutionAction.Split)) {
            if (d.state == DealState.Funded) revert InvalidState();
            // Valid from FIAT_SENT, DISPUTED
        } else {
            revert InvalidTerms();
        }

        // ── Verify dual signatures ──────────────────────────────────────────────
        bytes32 resDigest = DealHashing.digest(DOMAIN_SEPARATOR, DealHashing.hashResolution(auth));
        _verifySigner(d.holder, resDigest, holderSig);
        _verifySigner(d.provider, resDigest, providerSig);

        _resolutionNonceUsed[dealId][action][auth.resolutionNonce] = true;

        // ── Settle ──────────────────────────────────────────────────────────────
        if (action == uint8(ResolutionAction.MutualCancel)) {
            _settle(d, dealId, DealState.Cancelled, Outcome.MutualCancel, 0);
        } else if (action == uint8(ResolutionAction.CosignedRelease)) {
            _settle(d, dealId, DealState.Released, Outcome.CosignedRelease, 10_000);
        } else {
            _settle(d, dealId, DealState.ResolvedSplit, Outcome.MutualSplit,
                auth.providerShareBps);
        }
    }

    // ── Extension stubs (reject when profile not selected) ──────────────────────

    function submitPaymentProof(bytes32, bytes calldata) external pure {
        revert ProfileNotSelected();
    }

    function openArbitration(bytes32, bytes calldata) external payable {
        revert ProfileNotSelected();
    }

    function submitArbitrationRuling(bytes32, bytes calldata) external pure {
        revert ProfileNotSelected();
    }

    function arbitrationTimeout(bytes32) external pure {
        revert ProfileNotSelected();
    }

    // ── Internal: settlement ────────────────────────────────────────────────────

    /// @dev Settle a deal with the given provider bps. Computes terminal record,
    ///      calls Ledger to create terminal positions, and updates deal state.
    function _settle(
        Deal storage d,
        bytes32 dealId,
        uint8 terminalState,
        uint8 outcome,
        uint16 providerBps
    ) internal {
        uint256 principal = d.principal;

        (uint256 holderGross, uint256 provGross) =
            SettlementMath.split(principal, providerBps);
        uint256 compCollected = SettlementMath.completionCollected(d.completionFee, provGross);
        uint256 provNet;
        unchecked { provNet = provGross - compCollected; }

        // Build terminal record (27 fields, Core-only defaults)
        TerminalRecord memory tr = TerminalRecord({
            chainId: chainId,
            protocolVersion: protocolVersion,
            escrow: address(this),
            ledger: address(ledger),
            dealId: dealId,
            terminalState: terminalState,
            outcome: outcome,
            operatorFaultCode: 0, // NoFault
            operatorFaultEvidenceHash: bytes32(0),
            token: d.token,
            principal: principal,
            holderSideReturn: holderGross,
            providerGross: provGross,
            providerNet: provNet,
            completionCollected: compCollected,
            operatorFeePaid: 0,
            operatorFeeUnlocked: 0,
            holderReceiver: d.holderReceiver,
            providerReceiver: d.providerReceiver,
            completionFeeRecipient: d.completionFeeRecipient,
            operatorFeeRecipient: address(0),
            operatorFeeReturnReceiver: address(0),
            termsHash: d.termsHash,
            modulesHash: d.modulesHash,
            evidenceHash: bytes32(0),
            reservationsHash: bytes32(0),
            reservationDispositionsHash: bytes32(0),
            terminatedAt: uint64(block.timestamp)
        });

        bytes32 terminalHash = DealHashing.hashTerminalRecord(tr);

        // Build allocations (skip zero amounts)
        TerminalAllocation[] memory allocs = _buildAllocs(
            d.custodyBoundaryId, dealId, terminalHash,
            d.holderReceiver, holderGross,
            d.providerReceiver, provNet,
            d.completionFeeRecipient, compCollected
        );

        ledger.settleDealAndReservations(dealId, d.token, terminalHash, allocs);

        d.state = terminalState;
        d.outcome = outcome;
        d.terminalHash = terminalHash;
        _terminalRecords[dealId] = tr;

        emit DealClosed(dealId, terminalState, outcome, terminalHash);
    }

    function _buildAllocs(
        bytes32 boundaryId, bytes32 dealId, bytes32 terminalHash,
        address hR, uint256 hG, address pR, uint256 pN,
        address cR, uint256 cC
    ) internal pure returns (TerminalAllocation[] memory) {
        uint256 count;
        if (hG > 0) ++count;
        if (pN > 0) ++count;
        if (cC > 0) ++count;
        TerminalAllocation[] memory allocs = new TerminalAllocation[](count);
        uint256 i;
        if (hG > 0) allocs[i++] = TerminalAllocation(hR, hG,
            DealHashing.positionId(boundaryId, 3, dealId, terminalHash, hR));
        if (pN > 0) allocs[i++] = TerminalAllocation(pR, pN,
            DealHashing.positionId(boundaryId, 3, dealId, terminalHash, pR));
        if (cC > 0) allocs[i++] = TerminalAllocation(cR, cC,
            DealHashing.positionId(boundaryId, 3, dealId, terminalHash, cR));
        return allocs;
    }

    // ── Internal: signature verification ─────────────────────────────────────────

    function _verifySigner(address expected, bytes32 digest_, bytes calldata signature)
        internal
        pure
    {
        if (signature.length != 65) revert InvalidSignature();
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        address signer = ecrecover(digest_, v, r, s);
        if (signer != expected) revert InvalidSignature();
    }

    // ── Views ───────────────────────────────────────────────────────────────────

    function getDeal(bytes32 dealId) external view returns (Deal memory) {
        return _deals[dealId];
    }

    function dealState(bytes32 dealId) external view returns (uint8) {
        return _deals[dealId].state;
    }

    function termsHashOf(bytes32 dealId) external view returns (bytes32) {
        return _deals[dealId].termsHash;
    }

    function getTerminalRecord(bytes32 dealId) external view returns (TerminalRecord memory) {
        return _terminalRecords[dealId];
    }

    function getTerminalHash(bytes32 dealId) external view returns (bytes32) {
        return _deals[dealId].terminalHash;
    }

    function usedHolderNonce(address holder, uint256 nonce) external view returns (bool) {
        return _holderNonceUsed[holder][nonce];
    }

    function usedResolutionNonce(bytes32 dealId, ResolutionAction action, uint256 nonce)
        external
        view
        returns (bool)
    {
        return _resolutionNonceUsed[dealId][uint8(action)][nonce];
    }

    // ── Events ──────────────────────────────────────────────────────────────────

    event DealActivated(
        bytes32 indexed dealId, address indexed holder, address indexed provider,
        address token, uint256 principal
    );
    event FiatSent(bytes32 indexed dealId);
    event DisputeOpened(bytes32 indexed dealId, address indexed opener);
    event DealClosed(
        bytes32 indexed dealId, uint8 terminalState, uint8 outcome, bytes32 terminalHash
    );
}
