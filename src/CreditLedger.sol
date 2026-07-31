// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICreditLedger} from "./interfaces/ICreditLedger.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {ExactERC20} from "./libraries/ExactERC20.sol";
import {DealHashing} from "./libraries/DealHashing.sol";
import {SignatureValidation} from "./libraries/SignatureValidation.sol";
import {DeficitMath} from "./libraries/DeficitMath.sol";
import {
    FundingSpec,
    FundingAuth,
    DeficitComponents,
    PositionView,
    PositionPayoutAuth,
    PositionPayoutResult,
    TerminalAllocation,
    FundingPurpose,
    FundingSourceMode,
    PositionKind,
    BoundaryMode,
    ReconciliationStatus,
    PayoutResultCode
} from "./libraries/DealTypes.sol";
import {
    BoundaryInDeficit,
    Expired,
    FundingAuthInvalid,
    FundingSpecMismatch,
    InvalidFundingMode,
    NonceUsed,
    PositionAlreadyExists,
    PositionAlreadyConsumed,
    PositionNotFound,
    PositionNotClaimable,
    PositionNotSplittable,
    InvalidPositionKind,
    SelfReceiver,
    Unauthorized,
    ZeroAddress,
    InvalidTokenList,
    InvalidPayoutAction,
    InvalidAmount,
    InvalidChainId,
    InvalidRecoveryAmount,
    RecoveryExceedsGap,
    Reentrancy,
    DeficitNotActive,
    PositionIdCollision,
    BoundaryNominalLimitExceeded
} from "./libraries/CoreErrors.sol";

/// @notice Sole physical vault for all Core positions per MANDATORY_CORE.md §3, §4, §8.2.
/// @dev Uses conservative Q128.128 deficit indices. Gap rounding may delay dust but cannot
///      overpay a position or make claim order economically favorable.
contract CreditLedger is ICreditLedger {
    using ExactERC20 for IERC20;

    uint256 public constant MAX_BOUNDARY_NOMINAL = type(uint128).max;

    uint256 internal constant MAX_DEAL_TERMINAL_CHILDREN = 3;

    // ── EIP-712 ────────────────────────────────────────────────────────────────

    bytes32 private constant _TYPE_HASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 private constant _NAME_HASH = keccak256(bytes("PluriSwapCreditLedger"));
    bytes32 private constant _VERSION_HASH = keccak256(bytes("2"));
    bytes32 private constant _PAYOUT_AUTH_TYPEHASH = keccak256(
        "PositionPayoutAuth(uint8 action,address token,bytes32 positionId,address beneficiary,address to,uint256 maxAmount,uint256 nonce,uint64 expiry)"
    );
    bytes32 internal constant BOUNDARY_CHECKPOINT_V1_TYPEHASH = keccak256(
        "BoundaryCheckpointV1(uint64 chainId,address ledger,address token,uint256 accountedAssets,uint256 nominalOutstanding,uint256 deficitNominalUnits,uint256 deficitPaidAssets,uint256 deficitGapCoefficient,uint256 deficitHistoryScale,uint256 deficitHistoryTotal,uint256 deficitGeneration,uint256 deficitRoundingDust,bool deficitPrecisionFloor)"
    );

    // ── Immutables ──────────────────────────────────────────────────────────────

    address public immutable escrow;
    address public immutable coordinator;
    uint64 public immutable chainId;
    bytes32 public immutable DOMAIN_SEPARATOR;

    // ── Boundary state ─────────────────────────────────────────────────────────

    struct Boundary {
        // Packed flags: mode (0=HEALTHY, 1=DEFICIT) and precision policy share one slot.
        uint8 mode;
        bool deficitPrecisionFloor;
        uint256 accountedAssets;
        uint256 nominalOutstanding;
        uint256 quarantinedSurplus;
        uint256 deficitNominalUnits;
        uint256 deficitPaidAssets;
        uint256 deficitGapCoefficient;
        uint256 deficitHistoryScale;
        uint256 deficitHistoryTotal;
        uint256 deficitGeneration;
        uint256 deficitRoundingDust;
    }

    mapping(address token => Boundary) internal _boundaries;

    // ── Positions ───────────────────────────────────────────────────────────────

    struct Position {
        uint256 nominal;
        bytes32 sourceId;
        bytes32 terminalHash;
        address beneficiary;
        // Packed identity/lifecycle slot: token, kind, flags, and bounded replacement dust.
        address token;
        uint8 kind; // PositionKind
        bool exists;
        bool consumed;
        bool replaced;
        uint8 replacementRoundingDust;
        uint256 deficitPaidAssets;
        uint256 deficitHistory;
        uint256 deficitGeneration;
        uint256 replacementGap;
    }

    struct SplitTotals {
        uint256 gap;
        uint256 childCount;
    }

    mapping(bytes32 => Position) internal _positions;

    // ── Nonces ─────────────────────────────────────────────────────────────────

    mapping(address => mapping(uint8 => mapping(uint256 => bool))) internal _fundingNonceUsed;
    mapping(address => mapping(uint8 => mapping(uint256 => bool))) internal _payoutNonceUsed;

    // ── Reentrancy ─────────────────────────────────────────────────────────────

    uint256 private _locked = 1;

    modifier liveChain() {
        _requireLiveChain();
        _;
    }

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    modifier onlyEscrow() {
        if (msg.sender != escrow) revert Unauthorized();
        _;
    }

    function _requireLiveChain() private view {
        if (block.chainid != uint256(chainId)) revert InvalidChainId();
    }

    constructor(address escrow_, address coordinator_, uint64 chainId_) {
        if (block.chainid > type(uint64).max) revert InvalidChainId();
        if (block.chainid != uint256(chainId_)) revert InvalidChainId();
        if (escrow_ == address(0) || coordinator_ == address(0)) revert ZeroAddress();
        escrow = escrow_;
        coordinator = coordinator_;
        chainId = chainId_;
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(_TYPE_HASH, _NAME_HASH, _VERSION_HASH, uint256(chainId_), address(this))
        );
    }

    function _validatePayoutReceiver(address receiver) private view {
        if (receiver == address(0)) revert ZeroAddress();
        if (receiver == address(this) || receiver == escrow || receiver == coordinator) {
            revert SelfReceiver();
        }
    }

    // ── Reconciliation ─────────────────────────────────────────────────────────

    /// @dev Per §4.2. Returns status 0/1/3 (continue) or 4 (deficit, stops action).
    function _reconcile(address token) internal returns (uint8 status) {
        Boundary storage b = _boundaries[token];
        uint256 expectedRaw = b.accountedAssets + b.quarantinedSurplus;
        uint256 actualRaw = IERC20(token).balanceOf(address(this));

        if (actualRaw > expectedRaw) {
            // Surplus quarantined
            b.quarantinedSurplus += (actualRaw - expectedRaw);
            emit BoundaryReconciled(
                token,
                ReconciliationStatus.SurplusQuarantined,
                expectedRaw,
                actualRaw,
                b.accountedAssets,
                b.accountedAssets,
                b.quarantinedSurplus - (actualRaw - expectedRaw),
                b.quarantinedSurplus,
                _boundaryCheckpointId(token, b)
            );
            return ReconciliationStatus.SurplusQuarantined;
        }

        if (actualRaw == expectedRaw) {
            return ReconciliationStatus.Unchanged;
        }

        // actualRaw < expectedRaw: negative delta
        uint256 negativeDelta = expectedRaw - actualRaw;
        uint256 absorbed =
            negativeDelta < b.quarantinedSurplus ? negativeDelta : b.quarantinedSurplus;
        uint256 quarantinedBefore = b.quarantinedSurplus;
        b.quarantinedSurplus -= absorbed;
        uint256 residualLoss = negativeDelta - absorbed;

        if (residualLoss == 0) {
            // Fully absorbed by quarantine
            emit BoundaryReconciled(
                token,
                ReconciliationStatus.QuarantineLossAbsorbed,
                expectedRaw,
                actualRaw,
                b.accountedAssets,
                b.accountedAssets,
                quarantinedBefore,
                b.quarantinedSurplus,
                _boundaryCheckpointId(token, b)
            );
            return ReconciliationStatus.QuarantineLossAbsorbed;
        }

        // Deficit checkpointed. In an existing deficit this appends a conservative loss
        // checkpoint; the irreversible mode is never cleared.
        uint256 accountedBefore = b.accountedAssets;
        b.accountedAssets = accountedBefore - residualLoss;
        bool enteredDeficit = b.mode != BoundaryMode.Deficit;
        if (!enteredDeficit) {
            _applyLossCheckpoint(b, accountedBefore, b.accountedAssets);
        } else {
            b.mode = BoundaryMode.Deficit;
            b.deficitNominalUnits = b.nominalOutstanding;
            b.deficitPaidAssets = 0;
            b.deficitGeneration = 1;
            b.deficitGapCoefficient =
                DeficitMath.ratioUp(b.nominalOutstanding - b.accountedAssets, b.nominalOutstanding);
            b.deficitHistoryScale = DeficitMath.SCALE;
            b.deficitHistoryTotal = 0;
            b.deficitPrecisionFloor = false;
            _refreshRoundingDust(b);
        }
        bytes32 checkpointId = _boundaryCheckpointId(token, b);
        emit BoundaryReconciled(
            token,
            ReconciliationStatus.DeficitCheckpointed,
            expectedRaw,
            actualRaw,
            accountedBefore,
            b.accountedAssets,
            quarantinedBefore,
            b.quarantinedSurplus,
            checkpointId
        );
        if (enteredDeficit) {
            emit DeficitEntered(token, b.deficitNominalUnits, b.accountedAssets);
        } else {
            emit LossCheckpointed(
                token,
                checkpointId,
                b.accountedAssets,
                b.nominalOutstanding,
                b.deficitNominalUnits,
                b.deficitPaidAssets,
                b.deficitGapCoefficient,
                b.deficitHistoryScale,
                b.deficitHistoryTotal,
                b.deficitGeneration,
                b.deficitRoundingDust,
                b.deficitPrecisionFloor
            );
        }
        return ReconciliationStatus.DeficitCheckpointed;
    }

    // ── Escrow-only: preflight ──────────────────────────────────────────────────

    function preflightValueAction(address[] calldata tokens)
        external
        nonReentrant
        returns (uint8[] memory statuses)
    {
        if (msg.sender != escrow) revert Unauthorized();
        statuses = new uint8[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i] == address(0) || (i > 0 && tokens[i - 1] >= tokens[i])) {
                revert InvalidTokenList();
            }
            statuses[i] = _reconcile(tokens[i]);
            if (_boundaries[tokens[i]].mode == BoundaryMode.Deficit) {
                statuses[i] = ReconciliationStatus.DeficitCheckpointed;
            }
        }
    }

    // ── Escrow-only: funding ─────────────────────────────────────────────────────

    function fundDealAndReservations(
        bytes32 termsHash,
        bytes32 dealId,
        address token,
        uint256 principal,
        uint256 activationFee,
        address activationFeeRecipient,
        FundingSpec calldata principalFunding,
        FundingSpec calldata activationFeeFunding,
        FundingAuth calldata principalFundingAuth,
        FundingAuth calldata activationFeeFundingAuth,
        bytes calldata principalFundingSig,
        bytes calldata activationFeeFundingSig
    ) external liveChain nonReentrant onlyEscrow returns (uint8 reconciliationStatus) {
        uint8 status = _reconcile(token);
        if (
            status == ReconciliationStatus.DeficitCheckpointed
                || _boundaries[token].mode == BoundaryMode.Deficit
        ) {
            return _boundaries[token].mode == BoundaryMode.Deficit
                ? ReconciliationStatus.DeficitCheckpointed
                : status;
        }

        // Validate every funding request before any token call, position debit, or nonce use.
        _validateFundingRequest(
            termsHash,
            token,
            principalFunding,
            principalFundingAuth,
            principalFundingSig,
            FundingPurpose.Principal,
            principal
        );

        if (activationFee > 0) {
            _validatePayoutReceiver(activationFeeRecipient);
            _validateFundingRequest(
                termsHash,
                token,
                activationFeeFunding,
                activationFeeFundingAuth,
                activationFeeFundingSig,
                FundingPurpose.ActivationFee,
                activationFee
            );
        }

        _enforceBoundaryNominalLimit(
            token, principalFunding, principal, activationFeeFunding, activationFee
        );

        // Execute only after all request/auth/source checks have passed.
        _executeFunding(
            token, principalFunding, principalFundingAuth, FundingPurpose.Principal, principal
        );

        if (activationFee > 0) {
            _executeFunding(
                token,
                activationFeeFunding,
                activationFeeFundingAuth,
                FundingPurpose.ActivationFee,
                activationFee
            );
            // Create ACTIVATION_FEE position
            bytes32 feePosId = DealHashing.positionId(
                DealHashing.custodyBoundaryId(chainId, 2, address(this), token),
                PositionKind.ActivationFee,
                dealId,
                bytes32(0),
                activationFeeRecipient
            );
            _createPosition(
                feePosId,
                PositionKind.ActivationFee,
                dealId,
                bytes32(0),
                activationFeeRecipient,
                token,
                activationFee
            );
        }

        // Create DEAL position
        bytes32 dealPosId = DealHashing.positionId(
            DealHashing.custodyBoundaryId(chainId, 2, address(this), token),
            PositionKind.ActiveDeal,
            dealId,
            bytes32(0),
            address(0)
        );
        _createPosition(
            dealPosId, PositionKind.ActiveDeal, dealId, bytes32(0), address(0), token, principal
        );

        emit DealFunded(dealId, token, principal, activationFee);
        return status;
    }

    function _validateFundingRequest(
        bytes32 termsHash,
        address token,
        FundingSpec calldata spec,
        FundingAuth calldata auth,
        bytes calldata sig,
        uint8 expectedPurpose,
        uint256 expectedAmount
    ) internal view {
        if (spec.purpose != expectedPurpose) revert FundingSpecMismatch();
        if (spec.token != token) revert FundingSpecMismatch();
        if (spec.amount != expectedAmount) revert FundingSpecMismatch();
        if (spec.sourceMode == FundingSourceMode.WalletPull) {
            if (spec.sourcePositionId != bytes32(0)) revert InvalidFundingMode();
            if (spec.source != spec.authority) revert InvalidFundingMode();
        } else if (spec.sourceMode == FundingSourceMode.LedgerPosition) {
            if (spec.sourcePositionId == bytes32(0)) revert InvalidFundingMode();
        } else {
            revert InvalidFundingMode();
        }

        // Verify FundingAuth signature (Ledger domain)
        bytes32 specHash = DealHashing.hashFundingSpec(spec);
        if (auth.termsHash != termsHash) revert FundingAuthInvalid();
        if (auth.fundingSpecHash != specHash) revert FundingSpecMismatch();
        if (auth.purpose != expectedPurpose) revert FundingSpecMismatch();
        if (auth.authority != spec.authority) revert FundingAuthInvalid();
        if (block.timestamp >= auth.expiry) revert Expired();
        if (_fundingNonceUsed[auth.authority][expectedPurpose][auth.nonce]) revert NonceUsed();

        bytes32 authDigest = DealHashing.digest(DOMAIN_SEPARATOR, DealHashing.hashFundingAuth(auth));
        if (!SignatureValidation.isValid(auth.authority, authDigest, sig)) {
            revert FundingAuthInvalid();
        }

        if (spec.source != spec.authority) revert InvalidFundingMode();
        if (spec.sourceMode == FundingSourceMode.LedgerPosition) {
            Position storage sourcePos = _positions[spec.sourcePositionId];
            if (!sourcePos.exists) revert PositionNotFound();
            if (sourcePos.consumed) revert PositionAlreadyConsumed();
            if (
                sourcePos.kind != PositionKind.ActivationFee
                    && sourcePos.kind != PositionKind.DealTerminal
                    && sourcePos.kind != PositionKind.ReservationTerminal
            ) revert InvalidPositionKind();
            if (sourcePos.token != token) revert FundingSpecMismatch();
            if (_boundaries[token].mode == BoundaryMode.Deficit) revert BoundaryInDeficit();
            if (sourcePos.beneficiary != spec.authority) revert Unauthorized();
            if (sourcePos.nominal < expectedAmount) revert InvalidAmount();
        }
    }

    function _enforceBoundaryNominalLimit(
        address token,
        FundingSpec calldata principalFunding,
        uint256 principal,
        FundingSpec calldata activationFeeFunding,
        uint256 activationFee
    ) private view {
        uint256 addedUnits = 0;
        if (principalFunding.sourceMode == FundingSourceMode.WalletPull) {
            addedUnits = principal;
        }
        if (activationFee > 0 && activationFeeFunding.sourceMode == FundingSourceMode.WalletPull) {
            if (addedUnits > type(uint256).max - activationFee) {
                addedUnits = type(uint256).max;
            } else {
                addedUnits += activationFee;
            }
        }

        uint256 currentNominal = _boundaries[token].nominalOutstanding;
        if (
            currentNominal > MAX_BOUNDARY_NOMINAL
                || addedUnits > MAX_BOUNDARY_NOMINAL - currentNominal
        ) {
            revert BoundaryNominalLimitExceeded(currentNominal, addedUnits, MAX_BOUNDARY_NOMINAL);
        }
    }

    function _executeFunding(
        address token,
        FundingSpec calldata spec,
        FundingAuth calldata auth,
        uint8 purpose,
        uint256 expectedAmount
    ) internal {
        if (spec.sourceMode == FundingSourceMode.WalletPull) {
            IERC20(token).pullExact(spec.source, expectedAmount);
            Boundary storage b = _boundaries[token];
            b.accountedAssets += expectedAmount;
            b.nominalOutstanding += expectedAmount;
        } else {
            Position storage sourcePos = _positions[spec.sourcePositionId];
            sourcePos.nominal -= expectedAmount;
            if (sourcePos.nominal == 0) sourcePos.consumed = true;
            // Same-vault movement preserves both boundary totals exactly.
        }

        _fundingNonceUsed[auth.authority][purpose][auth.nonce] = true;
    }

    // ── Escrow-only: settlement ──────────────────────────────────────────────────

    function settleDealAndReservations(
        bytes32 dealId,
        address token,
        bytes32 terminalHash,
        TerminalAllocation[] calldata allocations
    ) external nonReentrant onlyEscrow returns (uint8 reconciliationStatus) {
        // The planner returns only final nonzero allocations, bounded by the three deal outputs.
        // Reject malformed over-count input before reconciliation or replacement can mutate state.
        if (allocations.length > MAX_DEAL_TERMINAL_CHILDREN) revert PositionNotSplittable();

        uint8 status = _reconcile(token);
        if (status == ReconciliationStatus.DeficitCheckpointed) {
            return status;
        }

        Boundary storage b = _boundaries[token];
        bytes32 boundaryId = DealHashing.custodyBoundaryId(chainId, 2, address(this), token);

        // Find and consume DEAL position
        bytes32 dealPosId = DealHashing.positionId(
            boundaryId, PositionKind.ActiveDeal, dealId, bytes32(0), address(0)
        );
        Position storage dealPos = _positions[dealPosId];
        if (!dealPos.exists) revert PositionNotFound();
        if (dealPos.consumed) revert PositionAlreadyConsumed();

        uint256 dealNominal = dealPos.nominal;
        if (dealPos.deficitPaidAssets != 0 || dealPos.deficitHistory != 0) {
            revert PositionNotSplittable();
        }
        uint256 preSplitGap = DeficitMath.factorUp(b.deficitGapCoefficient, dealNominal);
        SplitTotals memory childTotals = SplitTotals({gap: 0, childCount: 0});

        // Consume deal position
        dealPos.consumed = true;
        dealPos.replaced = true;
        dealPos.terminalHash = terminalHash;
        b.nominalOutstanding -= dealNominal;
        emit PositionConsumed(dealPosId);

        // Create terminal positions (coalesced by beneficiary within this deal)
        uint256 totalAllocated = 0;
        for (uint256 i; i < allocations.length; ++i) {
            TerminalAllocation calldata alloc = allocations[i];
            if (alloc.amount == 0) continue;
            _validatePayoutReceiver(alloc.beneficiary);

            bytes32 termPosId = DealHashing.positionId(
                boundaryId, PositionKind.DealTerminal, dealId, terminalHash, alloc.beneficiary
            );
            if (alloc.positionId != termPosId) revert PositionIdCollision();
            _createPosition(
                termPosId,
                PositionKind.DealTerminal,
                dealId,
                terminalHash,
                alloc.beneficiary,
                token,
                alloc.amount
            );
            // Active sources are nonclaimable, so children start at the current global
            // coefficient with zero paid assets and zero position-local history.
            childTotals.gap += DeficitMath.factorUp(b.deficitGapCoefficient, alloc.amount);
            ++childTotals.childCount;
            totalAllocated += alloc.amount;
        }

        // Conservation check: total allocated must equal deal nominal
        if (totalAllocated != dealNominal) revert PositionNotSplittable();
        if (childTotals.gap < preSplitGap) revert PositionNotSplittable();
        uint256 replacementRoundingDust = childTotals.gap - preSplitGap;
        uint256 replacementRoundingDustBound = 0;
        if (childTotals.childCount > 0) {
            replacementRoundingDustBound = childTotals.childCount - 1;
        }
        if (replacementRoundingDust > replacementRoundingDustBound) {
            revert PositionNotSplittable();
        }
        dealPos.replacementGap = childTotals.gap;
        // childCount <= 3 makes the proved childCount - 1 bound at most 2.
        // forge-lint: disable-next-line(unsafe-typecast)
        dealPos.replacementRoundingDust = uint8(replacementRoundingDust);

        // Terminal positions are matured: add to nominal outstanding
        b.nominalOutstanding += totalAllocated;

        emit DealSettled(dealId, token, terminalHash);
        return status;
    }

    // ── Permissionless withdrawals ─────────────────────────────────────────────

    function withdrawPosition(bytes32 positionId, uint256 maxAmount)
        external
        nonReentrant
        returns (PositionPayoutResult memory)
    {
        Position storage pos = _positions[positionId];
        if (!pos.exists) revert PositionNotFound();
        if (pos.consumed) {
            return PositionPayoutResult({
                code: PayoutResultCode.ZeroPayable,
                reconciliationStatus: ReconciliationStatus.Unchanged,
                positionId: positionId,
                receiver: pos.beneficiary,
                paidAmount: 0,
                nominalRemaining: 0
            });
        }
        if (pos.kind == PositionKind.ActiveDeal || pos.kind == PositionKind.Reservation) {
            revert PositionNotClaimable();
        }

        uint256 available = pos.nominal;
        uint256 pay = maxAmount == type(uint256).max ? available : maxAmount;
        if (pay > available) pay = available;
        if (pay == 0) {
            return PositionPayoutResult({
                code: PayoutResultCode.ZeroPayable,
                reconciliationStatus: ReconciliationStatus.Unchanged,
                positionId: positionId,
                receiver: pos.beneficiary,
                paidAmount: 0,
                nominalRemaining: pos.nominal
            });
        }

        return _executeWithdraw(positionId, pos, pos.beneficiary, pay);
    }

    function withdrawPositionTo(PositionPayoutAuth calldata auth, bytes calldata signature)
        external
        liveChain
        nonReentrant
        returns (PositionPayoutResult memory)
    {
        Position storage pos = _positions[auth.positionId];
        if (!pos.exists) revert PositionNotFound();
        if (pos.consumed) {
            return PositionPayoutResult({
                code: PayoutResultCode.ZeroPayable,
                reconciliationStatus: ReconciliationStatus.Unchanged,
                positionId: auth.positionId,
                receiver: auth.to,
                paidAmount: 0,
                nominalRemaining: 0
            });
        }
        if (pos.kind == PositionKind.ActiveDeal || pos.kind == PositionKind.Reservation) {
            revert PositionNotClaimable();
        }
        if (auth.action != 1) revert InvalidPayoutAction();
        if (auth.token != pos.token) revert FundingSpecMismatch();
        if (auth.beneficiary != pos.beneficiary) revert Unauthorized();
        _validatePayoutReceiver(auth.to);
        if (auth.maxAmount == 0) revert InvalidAmount();
        if (block.timestamp >= auth.expiry) revert Expired();
        if (_payoutNonceUsed[auth.beneficiary][auth.action][auth.nonce]) revert NonceUsed();

        if (!_verifyPayoutSignature(auth, signature)) revert FundingAuthInvalid();

        uint256 available = pos.nominal;
        uint256 pay = auth.maxAmount == type(uint256).max ? available : auth.maxAmount;
        if (pay > available) pay = available;
        if (pay == 0) {
            return PositionPayoutResult({
                code: PayoutResultCode.ZeroPayable,
                reconciliationStatus: ReconciliationStatus.Unchanged,
                positionId: auth.positionId,
                receiver: auth.to,
                paidAmount: 0,
                nominalRemaining: pos.nominal
            });
        }

        PositionPayoutResult memory result = _executeWithdraw(auth.positionId, pos, auth.to, pay);
        if (
            result.code == PayoutResultCode.HealthyPartial
                || result.code == PayoutResultCode.HealthyFull
        ) {
            _payoutNonceUsed[auth.beneficiary][auth.action][auth.nonce] = true;
        }
        return result;
    }

    function _executeWithdraw(bytes32 positionId, Position storage pos, address to, uint256 pay)
        internal
        returns (PositionPayoutResult memory)
    {
        address token = pos.token;

        uint8 status = _reconcile(token);
        if (status == ReconciliationStatus.DeficitCheckpointed) {
            return PositionPayoutResult({
                code: PayoutResultCode.ReconciliationOnly,
                reconciliationStatus: status,
                positionId: positionId,
                receiver: to,
                paidAmount: 0,
                nominalRemaining: pos.nominal
            });
        }
        if (_boundaries[token].mode == BoundaryMode.Deficit) {
            return PositionPayoutResult({
                code: PayoutResultCode.DeficitClaimRequired,
                reconciliationStatus: ReconciliationStatus.DeficitCheckpointed,
                positionId: positionId,
                receiver: to,
                paidAmount: 0,
                nominalRemaining: pos.nominal
            });
        }

        Boundary storage b = _boundaries[token];
        pos.nominal -= pay;
        if (pos.nominal == 0) pos.consumed = true;
        b.nominalOutstanding -= pay;
        b.accountedAssets -= pay;

        IERC20(token).pushExact(to, pay);

        emit PositionWithdrawn(positionId, to, pay);

        return PositionPayoutResult({
            code: pos.consumed ? PayoutResultCode.HealthyFull : PayoutResultCode.HealthyPartial,
            reconciliationStatus: status,
            positionId: positionId,
            receiver: to,
            paidAmount: pay,
            nominalRemaining: pos.nominal
        });
    }

    // ── Permissionless boundary checkpoint ──────────────────────────────────────

    function checkpointBoundary(address token)
        external
        nonReentrant
        returns (uint8 reconciliationStatus)
    {
        if (token == address(0)) revert ZeroAddress();
        reconciliationStatus = _reconcile(token);
    }

    // ── Deficit recovery ────────────────────────────────────────────────────────

    function depositRecovery(address token, uint256 amount)
        external
        nonReentrant
        returns (uint8 reconciliationStatus)
    {
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidRecoveryAmount();

        uint8 status = _reconcile(token);
        if (status == ReconciliationStatus.DeficitCheckpointed) return status;
        Boundary storage b = _boundaries[token];
        if (b.mode != BoundaryMode.Deficit) revert DeficitNotActive();

        uint256 gapBefore = _deficitGap(b);
        if (amount > gapBefore) revert RecoveryExceedsGap();

        IERC20(token).pullExact(msg.sender, amount);
        b.accountedAssets += amount;
        _applyRecoveryCheckpoint(b, gapBefore, amount);
        emit RecoveryDeposited(token, amount);
        return status;
    }

    function claimRecovery(bytes32 positionId, uint256 maxAmount)
        external
        nonReentrant
        returns (PositionPayoutResult memory)
    {
        Position storage pos = _positions[positionId];
        if (!pos.exists) revert PositionNotFound();
        if (pos.consumed) return _zeroPayout(positionId, pos.beneficiary);
        if (pos.kind == PositionKind.ActiveDeal || pos.kind == PositionKind.Reservation) {
            revert PositionNotClaimable();
        }
        if (maxAmount == 0) revert InvalidAmount();

        uint8 status = _reconcile(pos.token);
        if (status == ReconciliationStatus.DeficitCheckpointed) {
            return _reconciliationPayout(
                positionId, pos.beneficiary, status, _deficitNominalRemaining(pos)
            );
        }
        if (_boundaries[pos.token].mode != BoundaryMode.Deficit) revert DeficitNotActive();

        uint256 payableAmount = _deficitPayable(pos, maxAmount);
        if (payableAmount == 0) {
            return PositionPayoutResult({
                code: PayoutResultCode.ZeroPayable,
                reconciliationStatus: status,
                positionId: positionId,
                receiver: pos.beneficiary,
                paidAmount: 0,
                nominalRemaining: _deficitNominalRemaining(pos)
            });
        }

        return _executeDeficitClaim(positionId, pos, pos.beneficiary, payableAmount, status);
    }

    function claimRecoveryTo(PositionPayoutAuth calldata auth, bytes calldata signature)
        external
        liveChain
        nonReentrant
        returns (PositionPayoutResult memory)
    {
        Position storage pos = _positions[auth.positionId];
        if (!pos.exists) revert PositionNotFound();
        if (pos.consumed) return _zeroPayout(auth.positionId, auth.to);
        if (pos.kind == PositionKind.ActiveDeal || pos.kind == PositionKind.Reservation) {
            revert PositionNotClaimable();
        }
        if (auth.action != 2) revert InvalidPayoutAction();
        if (auth.token != pos.token) revert FundingSpecMismatch();
        if (auth.beneficiary != pos.beneficiary) revert Unauthorized();
        _validatePayoutReceiver(auth.to);
        if (auth.maxAmount == 0) revert InvalidAmount();
        if (block.timestamp >= auth.expiry) revert Expired();
        if (_payoutNonceUsed[auth.beneficiary][auth.action][auth.nonce]) revert NonceUsed();

        if (!_verifyPayoutSignature(auth, signature)) revert FundingAuthInvalid();

        uint8 status = _reconcile(pos.token);
        if (status == ReconciliationStatus.DeficitCheckpointed) {
            return
                _reconciliationPayout(
                    auth.positionId, auth.to, status, _deficitNominalRemaining(pos)
                );
        }
        if (_boundaries[pos.token].mode != BoundaryMode.Deficit) revert DeficitNotActive();

        uint256 payableAmount = _deficitPayable(pos, auth.maxAmount);
        if (payableAmount == 0) {
            return PositionPayoutResult({
                code: PayoutResultCode.ZeroPayable,
                reconciliationStatus: status,
                positionId: auth.positionId,
                receiver: auth.to,
                paidAmount: 0,
                nominalRemaining: _deficitNominalRemaining(pos)
            });
        }

        PositionPayoutResult memory result =
            _executeDeficitClaim(auth.positionId, pos, auth.to, payableAmount, status);
        _payoutNonceUsed[auth.beneficiary][auth.action][auth.nonce] = true;
        return result;
    }

    // ── Internal helpers ────────────────────────────────────────────────────────

    function _verifyPayoutSignature(PositionPayoutAuth calldata auth, bytes calldata signature)
        internal
        view
        returns (bool)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                _PAYOUT_AUTH_TYPEHASH,
                auth.action,
                auth.token,
                auth.positionId,
                auth.beneficiary,
                auth.to,
                auth.maxAmount,
                auth.nonce,
                auth.expiry
            )
        );
        return SignatureValidation.isValid(
            auth.beneficiary, DealHashing.digest(DOMAIN_SEPARATOR, structHash), signature
        );
    }

    function _zeroPayout(bytes32 positionId, address receiver)
        internal
        pure
        returns (PositionPayoutResult memory)
    {
        return PositionPayoutResult({
            code: PayoutResultCode.ZeroPayable,
            reconciliationStatus: ReconciliationStatus.Unchanged,
            positionId: positionId,
            receiver: receiver,
            paidAmount: 0,
            nominalRemaining: 0
        });
    }

    function _reconciliationPayout(
        bytes32 positionId,
        address receiver,
        uint8 status,
        uint256 nominalRemaining
    ) internal pure returns (PositionPayoutResult memory) {
        return PositionPayoutResult({
            code: PayoutResultCode.ReconciliationOnly,
            reconciliationStatus: status,
            positionId: positionId,
            receiver: receiver,
            paidAmount: 0,
            nominalRemaining: nominalRemaining
        });
    }

    function _deficitNominalRemaining(Position storage pos) internal view returns (uint256) {
        if (pos.deficitPaidAssets >= pos.nominal) return 0;
        return pos.nominal - pos.deficitPaidAssets;
    }

    function _positionComponents(Position storage pos, Boundary storage b)
        internal
        view
        returns (DeficitComponents memory components)
    {
        components.nominalUnits = pos.nominal;
        if (pos.replaced) {
            components.nominalRemaining = pos.nominal;
            components.unfundedGap = pos.replacementGap;
            components.fundedEntitlement =
                DeficitMath.funded(components.unfundedGap, components.nominalRemaining);
            return components;
        }

        if (b.mode != BoundaryMode.Deficit) {
            components.nominalRemaining = pos.nominal;
            components.fundedEntitlement = pos.nominal;
            return components;
        }

        components.nominalRemaining = _deficitNominalRemaining(pos);
        components.paidAssets = pos.deficitPaidAssets;
        uint256 history = pos.deficitGeneration == b.deficitGeneration ? pos.deficitHistory : 0;
        components.unfundedGap = DeficitMath.gap(
            b.deficitGapCoefficient, b.deficitHistoryScale, history, components.nominalRemaining
        );
        components.fundedEntitlement =
            DeficitMath.funded(components.unfundedGap, components.nominalRemaining);
    }

    function _deficitPayable(Position storage pos, uint256 maxAmount)
        internal
        view
        returns (uint256)
    {
        Boundary storage b = _boundaries[pos.token];
        uint256 nominalRemaining = _deficitNominalRemaining(pos);
        uint256 history = pos.deficitGeneration == b.deficitGeneration ? pos.deficitHistory : 0;
        uint256 gapAmount = DeficitMath.gap(
            b.deficitGapCoefficient, b.deficitHistoryScale, history, nominalRemaining
        );
        uint256 fundedAmount = DeficitMath.funded(gapAmount, nominalRemaining);
        if (fundedAmount > b.accountedAssets) fundedAmount = b.accountedAssets;
        if (maxAmount == type(uint256).max || maxAmount > fundedAmount) return fundedAmount;
        return maxAmount;
    }

    function _executeDeficitClaim(
        bytes32 positionId,
        Position storage pos,
        address receiver,
        uint256 amount,
        uint8 status
    ) internal returns (PositionPayoutResult memory) {
        Boundary storage b = _boundaries[pos.token];
        uint256 history = pos.deficitGeneration == b.deficitGeneration ? pos.deficitHistory : 0;
        (uint256 historyDelta, bool saturated) =
            DeficitMath.mulDivUpSaturated(b.deficitGapCoefficient, amount, b.deficitHistoryScale);
        if (saturated || history > type(uint256).max - historyDelta) {
            pos.deficitHistory = type(uint256).max;
            b.deficitPrecisionFloor = true;
        } else {
            pos.deficitHistory = history + historyDelta;
        }
        if (b.deficitHistoryTotal > type(uint256).max - historyDelta) {
            b.deficitHistoryTotal = type(uint256).max;
            b.deficitPrecisionFloor = true;
        } else {
            b.deficitHistoryTotal += historyDelta;
        }
        pos.deficitGeneration = b.deficitGeneration;
        pos.deficitPaidAssets += amount;
        b.deficitPaidAssets += amount;
        b.accountedAssets -= amount;
        b.nominalOutstanding -= amount;
        _refreshRoundingDust(b);

        if (_deficitNominalRemaining(pos) == 0) pos.consumed = true;

        IERC20(pos.token).pushExact(receiver, amount);
        emit RecoveryClaimed(positionId, receiver, amount);
        return PositionPayoutResult({
            code: PayoutResultCode.DeficitPaid,
            reconciliationStatus: status,
            positionId: positionId,
            receiver: receiver,
            paidAmount: amount,
            nominalRemaining: _deficitNominalRemaining(pos)
        });
    }

    function _deficitGap(Boundary storage b) internal view returns (uint256) {
        if (b.deficitPaidAssets > type(uint256).max - b.accountedAssets) return 0;
        uint256 paidAndAssets = b.deficitPaidAssets + b.accountedAssets;
        if (paidAndAssets >= b.deficitNominalUnits) return 0;
        return b.deficitNominalUnits - paidAndAssets;
    }

    function _applyLossCheckpoint(Boundary storage b, uint256 fundedBefore, uint256 assetsAfter)
        internal
    {
        if (assetsAfter == 0) {
            b.deficitGeneration += 1;
            b.deficitGapCoefficient = DeficitMath.SCALE;
            b.deficitHistoryScale = DeficitMath.SCALE;
            b.deficitHistoryTotal = 0;
            b.deficitRoundingDust = 0;
            b.deficitPrecisionFloor = false;
            return;
        }

        uint256 retainedRatioDown = DeficitMath.ratioDown(assetsAfter, fundedBefore);
        uint256 fundedCoefficient =
            DeficitMath.factorDown(retainedRatioDown, DeficitMath.SCALE - b.deficitGapCoefficient);
        b.deficitGapCoefficient = DeficitMath.SCALE - fundedCoefficient;
        uint256 retainedRatioUp = DeficitMath.ratioUp(assetsAfter, fundedBefore);
        uint256 nextScale = DeficitMath.factorUp(retainedRatioUp, b.deficitHistoryScale);
        if (nextScale > DeficitMath.SCALE) nextScale = DeficitMath.SCALE;
        b.deficitHistoryScale = nextScale;
        if (nextScale <= 1) b.deficitPrecisionFloor = true;
        _refreshRoundingDust(b);
    }

    function _applyRecoveryCheckpoint(Boundary storage b, uint256 gapBefore, uint256 amount)
        internal
    {
        uint256 gapAfter = gapBefore - amount;
        if (gapAfter == 0) {
            b.deficitGeneration += 1;
            b.deficitGapCoefficient = 0;
            b.deficitHistoryScale = DeficitMath.SCALE;
            b.deficitHistoryTotal = 0;
            b.deficitRoundingDust = 0;
            b.deficitPrecisionFloor = false;
            return;
        }

        uint256 retainedGapRatio = DeficitMath.ratioUp(gapAfter, gapBefore);
        uint256 nextCoefficient = DeficitMath.factorUp(retainedGapRatio, b.deficitGapCoefficient);
        uint256 nextScale = DeficitMath.factorUp(retainedGapRatio, b.deficitHistoryScale);
        if (nextCoefficient > DeficitMath.SCALE) nextCoefficient = DeficitMath.SCALE;
        if (nextScale > DeficitMath.SCALE) nextScale = DeficitMath.SCALE;
        b.deficitGapCoefficient = nextCoefficient;
        b.deficitHistoryScale = nextScale;
        if (nextScale <= 1) b.deficitPrecisionFloor = true;
        _refreshRoundingDust(b);
    }

    function _refreshRoundingDust(Boundary storage b) internal {
        uint256 aggregateGap = DeficitMath.gap(
            b.deficitGapCoefficient,
            b.deficitHistoryScale,
            b.deficitHistoryTotal,
            b.nominalOutstanding
        );
        uint256 aggregateFunded = DeficitMath.funded(aggregateGap, b.nominalOutstanding);
        b.deficitRoundingDust =
            b.accountedAssets > aggregateFunded ? b.accountedAssets - aggregateFunded : 0;
    }

    function _createPosition(
        bytes32 positionId,
        uint8 kind,
        bytes32 sourceId,
        bytes32 terminalHash_,
        address beneficiary,
        address token,
        uint256 nominal
    ) internal {
        if (_positions[positionId].exists) revert PositionAlreadyExists();
        _positions[positionId] = Position({
            nominal: nominal,
            kind: kind,
            sourceId: sourceId,
            terminalHash: terminalHash_,
            beneficiary: beneficiary,
            token: token,
            exists: true,
            consumed: false,
            replaced: false,
            deficitPaidAssets: 0,
            deficitHistory: 0,
            deficitGeneration: 0,
            replacementGap: 0,
            replacementRoundingDust: 0
        });
        emit PositionCreated(positionId, kind, beneficiary, nominal);
    }

    function _boundaryCheckpointId(address token, Boundary storage b)
        internal
        view
        returns (bytes32)
    {
        if (b.mode != BoundaryMode.Deficit) return bytes32(0);
        return keccak256(
            abi.encode(
                BOUNDARY_CHECKPOINT_V1_TYPEHASH,
                chainId,
                address(this),
                token,
                b.accountedAssets,
                b.nominalOutstanding,
                b.deficitNominalUnits,
                b.deficitPaidAssets,
                b.deficitGapCoefficient,
                b.deficitHistoryScale,
                b.deficitHistoryTotal,
                b.deficitGeneration,
                b.deficitRoundingDust,
                b.deficitPrecisionFloor
            )
        );
    }

    // ── Views ───────────────────────────────────────────────────────────────────

    function boundaryMode(address token) external view returns (uint8) {
        return _boundaries[token].mode;
    }

    function boundaryCheckpointId(address token) external view returns (bytes32) {
        return _boundaryCheckpointId(token, _boundaries[token]);
    }

    function accountedAssets(address token) external view returns (uint256) {
        return _boundaries[token].accountedAssets;
    }

    function nominalOutstanding(address token) external view returns (uint256) {
        return _boundaries[token].nominalOutstanding;
    }

    function quarantinedSurplus(address token) external view returns (uint256) {
        return _boundaries[token].quarantinedSurplus;
    }

    function inDeficit(address token) external view returns (bool) {
        return _boundaries[token].mode == BoundaryMode.Deficit;
    }

    function deficitPaidAssets(address token) external view returns (uint256) {
        return _boundaries[token].deficitPaidAssets;
    }

    function deficitNominalUnits(address token) external view returns (uint256) {
        return _boundaries[token].deficitNominalUnits;
    }

    function deficitGapCoefficient(address token) external view returns (uint256) {
        return _boundaries[token].deficitGapCoefficient;
    }

    function deficitHistoryScale(address token) external view returns (uint256) {
        return _boundaries[token].deficitHistoryScale;
    }

    function deficitHistoryTotal(address token) external view returns (uint256) {
        return _boundaries[token].deficitHistoryTotal;
    }

    function deficitGeneration(address token) external view returns (uint256) {
        return _boundaries[token].deficitGeneration;
    }

    function deficitRoundingDust(address token) external view returns (uint256) {
        return _boundaries[token].deficitRoundingDust;
    }

    function deficitPrecisionFloor(address token) external view returns (bool) {
        return _boundaries[token].deficitPrecisionFloor;
    }

    function getPosition(bytes32 positionId) external view returns (PositionView memory position) {
        position.positionId = positionId;
        Position storage stored = _positions[positionId];
        if (!stored.exists) return position;

        Boundary storage b = _boundaries[stored.token];
        position.exists = true;
        position.consumed = stored.consumed;
        position.replaced = stored.replaced;
        position.replacementRoundingDust = uint256(stored.replacementRoundingDust);
        position.kind = stored.kind;
        position.sourceId = stored.sourceId;
        position.terminalHash = stored.terminalHash;
        position.beneficiary = stored.beneficiary;
        position.token = stored.token;
        position.components = _positionComponents(stored, b);
        position.deficitHistory = stored.deficitHistory;
        position.deficitGeneration = stored.deficitGeneration;
        position.boundaryCheckpointId = _boundaryCheckpointId(stored.token, b);
        position.boundaryMode = b.mode;
    }

    function positionExists(bytes32 positionId) external view returns (bool) {
        return _positions[positionId].exists;
    }

    function positionNominal(bytes32 positionId) external view returns (uint256) {
        return _positions[positionId].nominal;
    }

    function positionNominalRemaining(bytes32 positionId) external view returns (uint256) {
        Position storage pos = _positions[positionId];
        if (!pos.exists) return 0;
        if (pos.replaced) return pos.nominal;
        if (_boundaries[pos.token].mode == BoundaryMode.Deficit) {
            return _deficitNominalRemaining(pos);
        }
        return pos.nominal;
    }

    function positionBeneficiary(bytes32 positionId) external view returns (address) {
        return _positions[positionId].beneficiary;
    }

    function positionKind(bytes32 positionId) external view returns (uint8) {
        return _positions[positionId].kind;
    }

    function positionConsumed(bytes32 positionId) external view returns (bool) {
        return _positions[positionId].consumed;
    }

    function positionTerminalHash(bytes32 positionId) external view returns (bytes32) {
        return _positions[positionId].terminalHash;
    }
}
