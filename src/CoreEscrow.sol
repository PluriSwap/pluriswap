// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICoreEscrow} from "./interfaces/ICoreEscrow.sol";
import {ICreditLedger} from "./interfaces/ICreditLedger.sol";
import {ICoordinator} from "./interfaces/ICoordinator.sol";
import {DealHashing} from "./libraries/DealHashing.sol";
import {SettlementMath} from "./libraries/SettlementMath.sol";
import {SignatureValidation} from "./libraries/SignatureValidation.sol";
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
    ReconciliationStatus,
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
    Reentrancy,
    TerminalDeal,
    Unauthorized,
    ZeroAddress,
    InvalidChainId
} from "./libraries/CoreErrors.sol";

/// @notice Tokenless CoreEscrow state machine per PROTOCOL.md §8.
/// @dev Never imports IERC20 or touches tokens. All custody via Ledger.
contract CoreEscrow is ICoreEscrow {
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
    bytes32 public immutable intentHash;

    // ── State ───────────────────────────────────────────────────────────────────

    mapping(bytes32 => Deal) internal _deals;
    mapping(bytes32 => TerminalRecord) internal _terminalRecords;
    mapping(bytes32 => bool) internal _dealExists;
    mapping(address => mapping(uint256 => bool)) internal _holderNonceUsed;
    mapping(bytes32 => mapping(uint8 => mapping(uint256 => bool))) internal _resolutionNonceUsed;

    uint256 private _locked = 1;

    modifier liveChain() {
        _requireLiveChain();
        _;
    }

    modifier nonReentrant() {
        _lock();
        _;
        _unlock();
    }

    function _requireLiveChain() private view {
        if (block.chainid != uint256(chainId)) revert InvalidChainId();
    }

    function _lock() private {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
    }

    function _unlock() private {
        _locked = 1;
    }

    constructor(
        uint64 chainId_,
        uint32 protocolVersion_,
        bytes32 charterHash_,
        bytes32 techSpecHash_,
        address ledger_,
        address coordinator_,
        bytes32 intentHash_
    ) {
        if (block.chainid > type(uint64).max) revert InvalidChainId();
        if (block.chainid != uint256(chainId_)) revert InvalidChainId();
        if (
            protocolVersion_ != 2 || charterHash_ == bytes32(0) || techSpecHash_ == bytes32(0)
                || intentHash_ == bytes32(0)
        ) {
            revert InvalidTerms();
        }
        if (ledger_ == address(0) || coordinator_ == address(0)) {
            revert ZeroAddress();
        }
        if (ledger_.code.length == 0 || coordinator_.code.length == 0) {
            revert InvalidTerms();
        }
        if (ledger_ == coordinator_ || ledger_ == address(this) || coordinator_ == address(this)) {
            revert InvalidTerms();
        }
        chainId = chainId_;
        protocolVersion = protocolVersion_;
        charterHash = charterHash_;
        techSpecHash = techSpecHash_;
        ledger = ICreditLedger(ledger_);
        coordinator = ICoordinator(coordinator_);
        intentHash = intentHash_;
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(_TYPE_HASH, _NAME_HASH, _VERSION_HASH, uint256(chainId_), address(this))
        );
    }

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
    ) external liveChain nonReentrant returns (bytes32 dealId, uint8 reconciliationStatus) {
        if (block.timestamp >= terms.createExpiry) revert Expired();

        // ── Core-only validation ────────────────────────────────────────────────
        if (terms.profileFlags != 0) revert ProfileNotSelected();
        if (
            (terms.packageSelectionHash | terms.packageContestTermsHash | terms.poolAuthorityHash
                        | terms.arbitrationTermsHash | terms.reservationsHash | terms.modulesHash
                        | terms.extensionsHash) != bytes32(0)
        ) {
            revert ProfileNotSelected();
        }

        // ── Basic field validation ──────────────────────────────────────────────
        if (terms.holder == address(0) || terms.provider == address(0)) revert ZeroAddress();
        if (terms.token == address(0)) revert ZeroAddress();
        if (terms.principal == 0) revert InvalidTerms();
        if (terms.disputeTimeoutProviderBps > 10_000) revert InvalidBps();
        if (terms.fiatDuration == 0 || terms.releaseDuration == 0 || terms.disputeDuration == 0) {
            revert InvalidTerms();
        }
        if (terms.holder == terms.provider) revert InvalidTerms();
        if (terms.completionFee > terms.principal) revert InvalidTerms();
        if (terms.completionFee > 0 && terms.completionFeeRecipient == address(0)) {
            revert ZeroAddress();
        }
        if (terms.activationFee > 0 && terms.activationFeeRecipient == address(0)) {
            revert ZeroAddress();
        }

        _validateActivationReceivers(terms);

        if (
            terms.custodyBoundaryId
                != DealHashing.custodyBoundaryId(
                    chainId, protocolVersion, address(ledger), terms.token
                )
        ) revert InvalidTerms();

        uint64 fiatDeadline = _validateActivationDeadlines(terms);

        _validateActivationFunding(terms, principalFunding, activationFeeFunding);

        // ── Compute dealId and check non-existence ──────────────────────────────
        (bytes32 termsHash, bytes32 computedDealId) = _computeDealIdentity(terms);
        dealId = computedDealId;
        if (_dealExists[dealId]) revert DealExists();

        // ── Verify party signatures on terms ────────────────────────────────────
        _verifyActivationSignatures(terms.holder, terms.provider, termsHash, holderSig, providerSig);

        // ── Verify holder nonce ─────────────────────────────────────────────────
        if (_holderNonceUsed[terms.holder][terms.nonce]) revert NonceUsed();

        // ── Reconcile before any stateful funding or optional module call ────────
        reconciliationStatus = _preflightToken(terms.token);
        if (reconciliationStatus == ReconciliationStatus.DeficitCheckpointed) {
            return (bytes32(0), reconciliationStatus);
        }

        // ── Fund via Ledger (pulls tokens, creates positions) ────────────────────
        reconciliationStatus = ledger.fundDealAndReservations(
            termsHash,
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
        if (reconciliationStatus == ReconciliationStatus.DeficitCheckpointed) {
            return (bytes32(0), reconciliationStatus);
        }

        // ── Mark nonce used ─────────────────────────────────────────────────────
        _holderNonceUsed[terms.holder][terms.nonce] = true;

        // ── Snapshot deal ──────────────────────────────────────────────────────
        _storeDeal(dealId, terms, termsHash, fiatDeadline);
        _dealExists[dealId] = true;

        emit DealActivated(dealId, terms.holder, terms.provider, terms.token, terms.principal);
    }

    // ── Core transitions ─────────────────────────────────────────────────────────

    /// @notice CASE-CORE-002: Provider marks fiat sent.
    function markFiatSent(bytes32 dealId) external nonReentrant {
        Deal storage d = _dealInState(dealId, DealState.Funded);
        if (msg.sender != d.provider) revert Unauthorized();

        if (block.timestamp > type(uint64).max) revert InvalidTiming();
        uint64 releaseDeadline =
            SettlementMath.checkedAdd64(uint64(block.timestamp), d.releaseDuration);
        SettlementMath.checkedAdd64(releaseDeadline, d.disputeDuration);

        d.state = DealState.FiatSent;
        d.releaseDeadline = releaseDeadline;

        emit FiatSent(dealId);
    }

    /// @notice CASE-CORE-004: Provider cancels before fiat is marked.
    function providerCancel(bytes32 dealId)
        external
        nonReentrant
        returns (uint8 reconciliationStatus)
    {
        Deal storage d = _dealInState(dealId, DealState.Funded);
        if (msg.sender != d.provider) revert Unauthorized();

        return _settle(d, dealId, DealState.Cancelled, Outcome.ProviderCancel, 0, bytes32(0));
    }

    /// @notice CASE-CORE-005: Anyone executes fiat timeout.
    function fiatTimeoutCancel(bytes32 dealId)
        external
        nonReentrant
        returns (uint8 reconciliationStatus)
    {
        Deal storage d = _dealInState(dealId, DealState.Funded);
        if (block.timestamp < d.fiatDeadline) revert InvalidTiming();

        return _settle(d, dealId, DealState.Cancelled, Outcome.FiatTimeoutCancel, 0, bytes32(0));
    }

    /// @notice CASE-CORE-007: Holder releases to provider.
    function holderRelease(bytes32 dealId)
        external
        nonReentrant
        returns (uint8 reconciliationStatus)
    {
        Deal storage d = _dealInState(dealId, DealState.FiatSent);
        if (msg.sender != d.holder) revert Unauthorized();

        return _settle(d, dealId, DealState.Released, Outcome.VoluntaryRelease, 10_000, bytes32(0));
    }

    /// @notice CASE-CORE-009: Permissionless claim after release deadline.
    function claim(bytes32 dealId) external nonReentrant returns (uint8 reconciliationStatus) {
        Deal storage d = _dealInState(dealId, DealState.FiatSent);
        if (block.timestamp < d.releaseDeadline) revert InvalidTiming();

        return _settle(d, dealId, DealState.Released, Outcome.TimeoutClaim, 10_000, bytes32(0));
    }

    /// @notice CASE-CORE-021: Holder opens Core dispute.
    function openDispute(bytes32 dealId, bytes calldata) external nonReentrant {
        Deal storage d = _dealInState(dealId, DealState.FiatSent);
        if (msg.sender != d.holder) revert Unauthorized();
        if (block.timestamp >= d.releaseDeadline) revert InvalidTiming();

        d.state = DealState.Disputed;
        d.disputeDeadline = SettlementMath.checkedAdd64(uint64(block.timestamp), d.disputeDuration);

        emit DisputeOpened(dealId, msg.sender);
    }

    /// @notice CASE-CORE-025: Permissionless dispute timeout residual.
    function disputeTimeout(bytes32 dealId)
        external
        nonReentrant
        returns (uint8 reconciliationStatus)
    {
        Deal storage d = _dealInState(dealId, DealState.Disputed);
        if (block.timestamp < d.disputeDeadline) revert InvalidTiming();

        return _settle(
            d,
            dealId,
            DealState.ResolvedByDisputeTimeout,
            Outcome.DisputeTimeout,
            d.disputeTimeoutProviderBps,
            bytes32(0)
        );
    }

    /// @notice CASE-CORE-006/011/022, 026, 012/024: Dual-signed resolution.
    function mutualResolve(
        bytes32 dealId,
        ResolutionAuth calldata auth,
        bytes calldata holderSig,
        bytes calldata providerSig
    ) external liveChain nonReentrant returns (uint8 reconciliationStatus) {
        Deal storage d = _deals[dealId];
        if (!_dealExists[dealId]) revert InvalidState();
        if (isTerminal(d.state)) revert TerminalDeal();

        // ── Validate auth ──────────────────────────────────────────────────────
        if (auth.dealId != dealId) revert InvalidTerms();
        if (auth.extensionsHash != bytes32(0)) revert InvalidTerms();
        if (
            auth.operatorFaultCode != 0 || auth.operatorFaultEvidenceHash != bytes32(0)
                || auth.reservationDispositionsHash != bytes32(0)
        ) revert InvalidTerms();
        if (auth.providerShareBps > 10_000) revert InvalidBps();
        if (block.timestamp >= auth.expiry) revert Expired();
        if (_resolutionNonceUsed[dealId][auth.action][auth.resolutionNonce]) revert NonceUsed();

        // ── Validate action vs state ─────────────────────────────────────────────
        uint8 action = auth.action;
        uint8 terminalState = DealState.None;
        uint8 outcome = Outcome.Invalid;
        if (action == uint8(ResolutionAction.MutualCancel)) {
            if (auth.providerShareBps != 0) revert InvalidBps();
            terminalState = DealState.Cancelled;
            outcome = Outcome.MutualCancel;
            // Valid from FUNDED, FIAT_SENT, DISPUTED
        } else if (action == uint8(ResolutionAction.CosignedRelease)) {
            if (auth.providerShareBps != 10_000) revert InvalidBps();
            if (d.state == DealState.Funded) revert InvalidState();
            terminalState = DealState.Released;
            outcome = Outcome.CosignedRelease;
            // Valid from FIAT_SENT, DISPUTED
        } else if (action == uint8(ResolutionAction.Split)) {
            if (d.state == DealState.Funded) revert InvalidState();
            terminalState = DealState.ResolvedSplit;
            outcome = Outcome.MutualSplit;
            // Valid from FIAT_SENT, DISPUTED
        } else {
            revert InvalidTerms();
        }

        // ── Verify dual signatures ──────────────────────────────────────────────
        bytes32 resolutionHash = DealHashing.hashResolution(auth);
        bytes32 resDigest = DealHashing.digest(DOMAIN_SEPARATOR, resolutionHash);
        _verifySigner(d.holder, resDigest, holderSig);
        _verifySigner(d.provider, resDigest, providerSig);

        // ── Settle ──────────────────────────────────────────────────────────────
        uint8 status =
            _settle(d, dealId, terminalState, outcome, auth.providerShareBps, resolutionHash);

        if (status != ReconciliationStatus.DeficitCheckpointed) {
            _resolutionNonceUsed[dealId][action][auth.resolutionNonce] = true;
        }
        return status;
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

    function _dealInState(bytes32 dealId, uint8 expectedState)
        private
        view
        returns (Deal storage d)
    {
        d = _deals[dealId];
        if (d.state != expectedState) revert InvalidState();
    }

    /// @dev Settle a deal with the given provider bps. Coordinator statically plans; Core
    ///      stores the terminal record; Ledger only commits custody (no reverse callback).
    function _settle(
        Deal storage d,
        bytes32 dealId,
        uint8 terminalState,
        uint8 outcome,
        uint16 providerBps,
        bytes32 evidenceHash
    ) internal returns (uint8 reconciliationStatus) {
        uint64 terminatedAt = SettlementMath.checkedUint64(block.timestamp);
        (
            TerminalRecord memory terminalRecord,
            bytes32 terminalHash,
            TerminalAllocation[] memory allocations
        ) = coordinator.planDealTerminal(
            chainId,
            protocolVersion,
            address(this),
            address(ledger),
            dealId,
            d.token,
            d.principal,
            d.completionFee,
            d.holderReceiver,
            d.providerReceiver,
            d.completionFeeRecipient,
            d.termsHash,
            d.modulesHash,
            d.custodyBoundaryId,
            terminalState,
            outcome,
            providerBps,
            evidenceHash,
            terminatedAt
        );

        reconciliationStatus =
            ledger.settleDealAndReservations(dealId, d.token, terminalHash, allocations);
        if (reconciliationStatus == ReconciliationStatus.DeficitCheckpointed) {
            return reconciliationStatus;
        }

        d.state = terminalState;
        d.outcome = outcome;
        d.terminalHash = terminalHash;
        _terminalRecords[dealId] = terminalRecord;

        emit DealClosed(dealId, terminalState, outcome, terminalHash);
    }

    // ── Internal: signature verification ─────────────────────────────────────────

    function _verifySigner(address expected, bytes32 digest_, bytes calldata signature)
        internal
        view
    {
        if (!SignatureValidation.isValid(expected, digest_, signature)) {
            revert InvalidSignature();
        }
    }

    function _validateActivationReceivers(DealTerms calldata terms) internal view {
        if (terms.holderReceiver == address(0) || terms.providerReceiver == address(0)) {
            revert ZeroAddress();
        }
        if (
            _isProtocolReceiver(terms.holderReceiver) || _isProtocolReceiver(terms.providerReceiver)
        ) {
            revert InvalidTerms();
        }
        if (
            terms.completionFeeRecipient != address(0)
                && _isProtocolReceiver(terms.completionFeeRecipient)
        ) {
            revert InvalidTerms();
        }
        if (
            terms.activationFeeRecipient != address(0)
                && _isProtocolReceiver(terms.activationFeeRecipient)
        ) {
            revert InvalidTerms();
        }
    }

    function _validateActivationDeadlines(DealTerms calldata terms)
        internal
        view
        returns (uint64 fiatDeadline)
    {
        if (block.timestamp > type(uint64).max) revert InvalidTiming();
        uint64 activatedAt = uint64(block.timestamp);
        fiatDeadline = SettlementMath.checkedAdd64(activatedAt, terms.fiatDuration);
        uint64 immediateReleaseDeadline =
            SettlementMath.checkedAdd64(activatedAt, terms.releaseDuration);
        SettlementMath.checkedAdd64(immediateReleaseDeadline, terms.disputeDuration);
    }

    function _validateActivationFunding(
        DealTerms calldata terms,
        FundingSpec calldata principalFunding,
        FundingSpec calldata activationFeeFunding
    ) internal pure {
        if (principalFunding.authority != terms.holder || principalFunding.source != terms.holder) {
            revert InvalidTerms();
        }
        if (terms.principalFundingHash != DealHashing.hashFundingSpec(principalFunding)) {
            revert InvalidTerms();
        }
        if (terms.activationFee > 0) {
            if (
                activationFeeFunding.authority != terms.holder
                    || activationFeeFunding.source != terms.holder
                    || terms.activationFeeFundingHash
                        != DealHashing.hashFundingSpec(activationFeeFunding)
            ) {
                revert InvalidTerms();
            }
        } else if (terms.activationFeeFundingHash != bytes32(0)) {
            revert InvalidTerms();
        }
    }

    function _computeDealIdentity(DealTerms calldata terms)
        internal
        view
        returns (bytes32 termsHash, bytes32 dealId)
    {
        termsHash = DealHashing.hashDealTerms(terms);
        dealId = DealHashing.hashDealId(
            chainId,
            protocolVersion,
            address(this),
            termsHash,
            terms.holder,
            terms.provider,
            terms.nonce
        );
    }

    function _verifyActivationSignatures(
        address holder,
        address provider,
        bytes32 termsHash,
        bytes calldata holderSig,
        bytes calldata providerSig
    ) internal view {
        bytes32 digest_ = DealHashing.digest(DOMAIN_SEPARATOR, termsHash);
        _verifySigner(holder, digest_, holderSig);
        _verifySigner(provider, digest_, providerSig);
    }

    function _preflightToken(address token) internal returns (uint8 status) {
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        uint8[] memory statuses = ledger.preflightValueAction(tokens);
        return statuses[0];
    }

    function _storeDeal(
        bytes32 dealId,
        DealTerms calldata terms,
        bytes32 termsHash,
        uint64 fiatDeadline
    ) internal {
        uint64 now_ = uint64(block.timestamp);
        _deals[dealId] = Deal({
            state: DealState.Funded,
            outcome: Outcome.Invalid,
            holder: terms.holder,
            provider: terms.provider,
            holderReceiver: terms.holderReceiver,
            providerReceiver: terms.providerReceiver,
            token: terms.token,
            principal: terms.principal,
            activationFee: terms.activationFee,
            activationFeeRecipient: terms.activationFeeRecipient,
            completionFee: terms.completionFee,
            completionFeeRecipient: terms.completionFeeRecipient,
            disputeTimeoutProviderBps: terms.disputeTimeoutProviderBps,
            activatedAt: now_,
            fiatDeadline: fiatDeadline,
            releaseDuration: terms.releaseDuration,
            releaseDeadline: 0,
            disputeDuration: terms.disputeDuration,
            disputeDeadline: 0,
            profileFlags: terms.profileFlags,
            termsHash: termsHash,
            custodyBoundaryId: terms.custodyBoundaryId,
            modulesHash: terms.modulesHash,
            terminalHash: bytes32(0)
        });
    }

    function _isProtocolReceiver(address receiver) internal view returns (bool) {
        return receiver == address(ledger) || receiver == address(this)
            || receiver == address(coordinator);
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
        bytes32 indexed dealId,
        address indexed holder,
        address indexed provider,
        address token,
        uint256 principal
    );
    event FiatSent(bytes32 indexed dealId);
    event DisputeOpened(bytes32 indexed dealId, address indexed opener);
    event DealClosed(
        bytes32 indexed dealId, uint8 terminalState, uint8 outcome, bytes32 terminalHash
    );
}
