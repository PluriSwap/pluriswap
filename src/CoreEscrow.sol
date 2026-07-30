// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICoreEscrow} from "./interfaces/ICoreEscrow.sol";
import {ICreditLedger} from "./interfaces/ICreditLedger.sol";
import {ICoordinator} from "./interfaces/ICoordinator.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IERC1271} from "./interfaces/IERC1271.sol";
import {ExactERC20} from "./libraries/ExactERC20.sol";
import {DealHashing} from "./libraries/DealHashing.sol";
import {SettlementMath} from "./libraries/SettlementMath.sol";
import {
    CrowdfundGated,
    DealExists,
    Expired,
    InvalidBps,
    InvalidSignature,
    InvalidState,
    InvalidTerms,
    InvalidTiming,
    NonceUsed,
    ProfileDisabled,
    SelfReceiver,
    TerminalDeal,
    Unauthorized,
    ZeroAddress
} from "./libraries/CoreErrors.sol";
import {
    Deal,
    DealState,
    DealTerms,
    ModuleIdentity,
    ModuleRole,
    Outcome,
    ProfileFlags,
    ResolutionAction,
    ResolutionAuth,
    isTerminal
} from "./libraries/DealTypes.sol";

contract CoreEscrow is ICoreEscrow {
    using ExactERC20 for IERC20;

    bytes32 private constant _DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    uint64 public immutable chainId;
    uint32 public immutable protocolVersion;
    bytes32 public immutable override charterHash;
    bytes32 public immutable override techSpecHash;
    ICreditLedger public immutable ledger;
    ICoordinator public immutable coordinator;
    bytes32 public immutable override DOMAIN_SEPARATOR;

    mapping(bytes32 => Deal) internal _deals;
    mapping(address => mapping(uint256 => bool)) internal _holderNonceUsed;
    mapping(bytes32 => mapping(uint8 => mapping(uint256 => bool))) internal _resolutionNonceUsed;
    mapping(address => uint256) internal _activePrincipal;

    uint256 private _locked = 1;

    event DealActivated(
        bytes32 indexed dealId,
        address indexed holder,
        address indexed provider,
        address token,
        uint256 principal,
        uint64 fiatDeadline,
        bytes32 termsHash,
        uint32 profileFlags,
        bytes32 packageId
    );
    event FiatMarked(bytes32 indexed dealId, uint64 releaseDeadline);
    event DisputeOpened(bytes32 indexed dealId, uint64 disputeDeadline);
    event DealTerminated(
        bytes32 indexed dealId,
        uint8 state,
        uint8 outcome,
        uint256 holderGross,
        uint256 providerGross,
        uint256 completionCollected,
        bytes32 terminalHash
    );

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
        address coordinator_
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
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                _DOMAIN_TYPEHASH,
                keccak256(bytes("PluriSwap")),
                keccak256(bytes("2")),
                uint256(chainId_),
                address(this)
            )
        );
    }

    receive() external payable {
        revert();
    }

    fallback() external payable {
        revert();
    }

    function activate(
        DealTerms calldata terms,
        bytes calldata holderSignature,
        bytes calldata providerSignature,
        bytes calldata activationData
    ) external nonReentrant returns (bytes32 dealId) {
        if (block.chainid != chainId) revert InvalidTerms();
        if (uint64(block.timestamp) >= terms.createExpiry) revert Expired();
        if (terms.principal == 0) revert InvalidTerms();
        if (terms.holder == address(0) || terms.provider == address(0)) revert ZeroAddress();
        if (terms.holder == terms.provider) revert InvalidTerms();
        if (terms.holderReceiver == address(0) || terms.providerReceiver == address(0)) {
            revert ZeroAddress();
        }
        if (terms.token == address(0)) revert ZeroAddress();
        _rejectSelfReceiver(terms.holderReceiver);
        _rejectSelfReceiver(terms.providerReceiver);
        if (
            terms.fiatDuration == 0 || terms.releaseDuration == 0 || terms.disputeDuration == 0
        ) {
            revert InvalidTiming();
        }
        if (terms.disputeTimeoutProviderBps > 10_000) revert InvalidBps();
        if (terms.activationFee > terms.principal || terms.completionFee > terms.principal) {
            revert InvalidTerms();
        }
        _validateFeeRecipient(terms.activationFee, terms.activationFeeRecipient);
        _validateFeeRecipient(terms.completionFee, terms.completionFeeRecipient);
        if (terms.profileFlags & ProfileFlags.CROWDFUNDED_POOL != 0) revert CrowdfundGated();
        // Milestone: Core-only activation (profiles OUT_OF_SCOPE until their tech specs).
        if (terms.profileFlags != 0) revert InvalidTerms();
        if (terms.modules.length != 0 || terms.extensions.length != 0) revert InvalidTerms();
        if (activationData.length != 0) revert InvalidTerms();
        if (_holderNonceUsed[terms.holder][terms.nonce]) revert NonceUsed();

        bytes32 termsHash = DealHashing.hashDealTerms(terms);
        bytes32 digest_ = DealHashing.digest(DOMAIN_SEPARATOR, termsHash);
        _verifySigner(terms.holder, digest_, holderSignature);
        _verifySigner(terms.provider, digest_, providerSignature);

        dealId = keccak256(
            abi.encode(address(this), termsHash, terms.holder, terms.provider, terms.nonce)
        );
        if (_deals[dealId].state != DealState.None) revert DealExists();

        IERC20(terms.token).pullExact(terms.holder, terms.principal);

        if (terms.activationFee > 0) {
            IERC20(terms.token).pullExact(terms.holder, terms.activationFee);
            // Move fee tokens to ledger then credit (ledger holds assets for credits).
            IERC20(terms.token).pushExact(address(ledger), terms.activationFee);
            ledger.credit(
                dealId, terms.token, terms.activationFeeRecipient, terms.activationFee
            );
        }

        uint64 activatedAt = uint64(block.timestamp);
        uint64 fiatDeadline = activatedAt + terms.fiatDuration;
        if (fiatDeadline < activatedAt) revert InvalidTiming();

        Deal storage d = _deals[dealId];
        d.state = DealState.Funded;
        d.outcome = Outcome.None;
        d.holder = terms.holder;
        d.provider = terms.provider;
        d.holderReceiver = terms.holderReceiver;
        d.providerReceiver = terms.providerReceiver;
        d.token = terms.token;
        d.principal = terms.principal;
        d.activationFee = terms.activationFee;
        d.activationFeeRecipient = terms.activationFeeRecipient;
        d.completionFee = terms.completionFee;
        d.completionFeeRecipient = terms.completionFeeRecipient;
        d.disputeTimeoutProviderBps = terms.disputeTimeoutProviderBps;
        d.activatedAt = activatedAt;
        d.fiatDeadline = fiatDeadline;
        d.releaseDuration = terms.releaseDuration;
        d.disputeDuration = terms.disputeDuration;
        d.profileFlags = terms.profileFlags;
        d.packageId = terms.packageId;
        d.packageHash = terms.packageHash;
        d.termsHash = termsHash;
        d.custodyBoundaryId = terms.custodyBoundaryId;
        d.tokenRiskHash = terms.tokenRiskHash;
        d.extensionsHash = DealHashing.extensionsHash(terms.extensions);

        _activePrincipal[terms.token] += terms.principal;
        _holderNonceUsed[terms.holder][terms.nonce] = true;

        emit DealActivated(
            dealId,
            terms.holder,
            terms.provider,
            terms.token,
            terms.principal,
            fiatDeadline,
            termsHash,
            terms.profileFlags,
            terms.packageId
        );
    }

    function markFiatSent(bytes32 dealId) external nonReentrant {
        Deal storage d = _requireActive(dealId);
        if (d.state != DealState.Funded) revert InvalidState();
        if (msg.sender != d.provider) revert Unauthorized();
        uint64 releaseDeadline = uint64(block.timestamp) + d.releaseDuration;
        if (releaseDeadline < uint64(block.timestamp)) revert InvalidTiming();
        d.state = DealState.FiatSent;
        d.releaseDeadline = releaseDeadline;
        emit FiatMarked(dealId, releaseDeadline);
    }

    function providerCancel(bytes32 dealId) external nonReentrant {
        Deal storage d = _requireActive(dealId);
        if (d.state != DealState.Funded) revert InvalidState();
        if (msg.sender != d.provider) revert Unauthorized();
        _settle(dealId, d, 0, Outcome.ProviderCancel, DealState.Cancelled);
    }

    function fiatTimeoutCancel(bytes32 dealId) external nonReentrant {
        Deal storage d = _requireActive(dealId);
        if (d.state != DealState.Funded) revert InvalidState();
        if (uint64(block.timestamp) < d.fiatDeadline) revert InvalidTiming();
        _settle(dealId, d, 0, Outcome.FiatTimeoutCancel, DealState.Cancelled);
    }

    function holderRelease(bytes32 dealId) external nonReentrant {
        Deal storage d = _requireActive(dealId);
        if (d.state != DealState.FiatSent) revert InvalidState();
        if (msg.sender != d.holder) revert Unauthorized();
        _settle(dealId, d, 10_000, Outcome.VoluntaryRelease, DealState.Released);
    }

    function claim(bytes32 dealId) external nonReentrant {
        Deal storage d = _requireActive(dealId);
        if (d.state != DealState.FiatSent) revert InvalidState();
        if (uint64(block.timestamp) < d.releaseDeadline) revert InvalidTiming();
        _settle(dealId, d, 10_000, Outcome.TimeoutClaim, DealState.Released);
    }

    function openDispute(bytes32 dealId, bytes calldata openData) external nonReentrant {
        Deal storage d = _requireActive(dealId);
        if (d.state != DealState.FiatSent) revert InvalidState();
        if (msg.sender != d.holder) revert Unauthorized();
        if (uint64(block.timestamp) >= d.releaseDeadline) revert InvalidTiming();
        if (openData.length != 0) revert InvalidTerms(); // package contest fee OUT_OF_SCOPE
        uint64 disputeDeadline = uint64(block.timestamp) + d.disputeDuration;
        if (disputeDeadline < uint64(block.timestamp)) revert InvalidTiming();
        d.state = DealState.Disputed;
        d.disputeDeadline = disputeDeadline;
        emit DisputeOpened(dealId, disputeDeadline);
    }

    function disputeTimeout(bytes32 dealId) external nonReentrant {
        Deal storage d = _requireActive(dealId);
        if (d.state != DealState.Disputed) revert InvalidState();
        if (uint64(block.timestamp) < d.disputeDeadline) revert InvalidTiming();
        _settle(
            dealId,
            d,
            d.disputeTimeoutProviderBps,
            Outcome.DisputeTimeout,
            DealState.ResolvedByDisputeTimeout
        );
    }

    function mutualResolve(
        bytes32 dealId,
        ResolutionAuth calldata auth,
        bytes calldata holderSignature,
        bytes calldata providerSignature
    ) external nonReentrant {
        Deal storage d = _requireActive(dealId);
        if (auth.dealId != dealId) revert InvalidTerms();
        if (uint64(block.timestamp) >= auth.expiry) revert Expired();
        if (_resolutionNonceUsed[dealId][uint8(auth.action)][auth.resolutionNonce]) {
            revert NonceUsed();
        }

        bytes32 digest_ = DealHashing.digest(DOMAIN_SEPARATOR, DealHashing.hashResolution(auth));
        _verifySigner(d.holder, digest_, holderSignature);
        _verifySigner(d.provider, digest_, providerSignature);
        _resolutionNonceUsed[dealId][uint8(auth.action)][auth.resolutionNonce] = true;

        if (auth.action == ResolutionAction.MutualCancel) {
            if (auth.providerShareBps != 0) revert InvalidBps();
            if (
                d.state != DealState.Funded && d.state != DealState.FiatSent
                    && d.state != DealState.Disputed
            ) {
                revert InvalidState();
            }
            _settle(dealId, d, 0, Outcome.MutualCancel, DealState.Cancelled);
        } else if (auth.action == ResolutionAction.CosignedRelease) {
            if (auth.providerShareBps != 0) revert InvalidBps();
            if (d.state != DealState.FiatSent && d.state != DealState.Disputed) revert InvalidState();
            _settle(dealId, d, 10_000, Outcome.CosignedRelease, DealState.Released);
        } else if (auth.action == ResolutionAction.Split) {
            if (auth.providerShareBps > 10_000) revert InvalidBps();
            if (d.state != DealState.FiatSent && d.state != DealState.Disputed) revert InvalidState();
            _settle(dealId, d, auth.providerShareBps, Outcome.MutualSplit, DealState.ResolvedSplit);
        } else {
            revert InvalidTerms();
        }
    }

    function submitPaymentProof(bytes32, bytes calldata) external pure {
        revert ProfileDisabled();
    }

    function openArbitration(bytes32, bytes calldata) external payable {
        revert ProfileDisabled();
    }

    function submitArbitrationRuling(bytes32, bytes calldata) external pure {
        revert ProfileDisabled();
    }

    function arbitrationTimeout(bytes32) external pure {
        revert ProfileDisabled();
    }

    function getDeal(bytes32 dealId) external view returns (Deal memory) {
        return _deals[dealId];
    }

    function dealState(bytes32 dealId) external view returns (DealState) {
        return _deals[dealId].state;
    }

    function termsHashOf(bytes32 dealId) external view returns (bytes32) {
        return _deals[dealId].termsHash;
    }

    function moduleOf(bytes32 dealId, ModuleRole role)
        external
        view
        returns (ModuleIdentity memory)
    {
        return _deals[dealId].modules[uint8(role)];
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

    function _settle(
        bytes32 dealId,
        Deal storage d,
        uint16 providerBps,
        Outcome outcome,
        DealState newState
    ) internal {
        (uint256 holderGross, uint256 providerGross) = SettlementMath.split(d.principal, providerBps);
        uint256 completionCollected =
            SettlementMath.completionCollected(d.completionFee, providerGross);
        uint256 providerNet = providerGross - completionCollected;

        address token = d.token;
        address holderReceiver = d.holderReceiver;
        address providerReceiver = d.providerReceiver;
        address completionFeeRecipient = d.completionFeeRecipient;
        bytes32 termsHash = d.termsHash;
        uint256 principal = d.principal;

        _activePrincipal[token] -= principal;
        d.state = newState;
        d.outcome = outcome;

        // Move principal assets to ledger, then mint credits.
        IERC20(token).pushExact(address(ledger), principal);

        if (ledger.inDeficit(token)) {
            // Deficit reallocation path reserved; Core-only happy path uses credits.
            revert InvalidState();
        }
        if (holderGross > 0) {
            ledger.credit(dealId, token, holderReceiver, holderGross);
        }
        if (providerNet > 0) {
            ledger.credit(dealId, token, providerReceiver, providerNet);
        }
        if (completionCollected > 0) {
            ledger.credit(dealId, token, completionFeeRecipient, completionCollected);
        }

        bytes32 terminalHash = keccak256(
            abi.encode(
                address(this),
                dealId,
                uint8(newState),
                uint8(outcome),
                token,
                principal,
                holderGross,
                providerGross,
                completionCollected,
                holderReceiver,
                providerReceiver,
                completionFeeRecipient,
                termsHash,
                uint64(block.timestamp)
            )
        );

        emit DealTerminated(
            dealId,
            uint8(newState),
            uint8(outcome),
            holderGross,
            providerGross,
            completionCollected,
            terminalHash
        );
    }

    function _requireActive(bytes32 dealId) internal view returns (Deal storage d) {
        d = _deals[dealId];
        if (d.state == DealState.None) revert InvalidState();
        if (isTerminal(d.state)) revert TerminalDeal();
    }

    function _rejectSelfReceiver(address receiver) internal view {
        if (receiver == address(this) || receiver == address(ledger)) revert SelfReceiver();
    }

    function _validateFeeRecipient(uint256 fee, address recipient) internal view {
        if (fee == 0) return;
        if (recipient == address(0)) revert ZeroAddress();
        _rejectSelfReceiver(recipient);
    }

    function _verifySigner(address expected, bytes32 digest_, bytes calldata signature)
        internal
        view
    {
        if (expected.code.length > 0) {
            bytes4 magic = IERC1271(expected).isValidSignature(digest_, signature);
            if (magic != 0x1626ba7e) revert InvalidSignature();
            return;
        }
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
        if (signer == address(0) || signer != expected) revert InvalidSignature();
    }
}
