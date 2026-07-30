// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICreditLedger} from "./interfaces/ICreditLedger.sol";
import {ICoreEscrow} from "./interfaces/ICoreEscrow.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {ExactERC20} from "./libraries/ExactERC20.sol";
import {DealHashing} from "./libraries/DealHashing.sol";
import {SignatureValidation} from "./libraries/SignatureValidation.sol";
import {
    FundingSpec,
    FundingAuth,
    PositionPayoutAuth,
    PositionPayoutResult,
    TerminalAllocation,
    TerminalRecord,
    Deal,
    FundingPurpose,
    FundingSourceMode,
    PositionKind,
    BoundaryMode,
    ReconciliationStatus,
    PayoutResultCode
} from "./libraries/DealTypes.sol";
import {SettlementMath} from "./libraries/SettlementMath.sol";
import {
    DeficitNotImplemented,
    BoundaryInDeficit,
    Expired,
    FundingAuthInvalid,
    FundingSpecMismatch,
    InvalidFundingMode,
    NonceUsed,
    PositionAlreadyExists,
    PositionAlreadyConsumed,
    PositionNotFound,
    InvalidPositionKind,
    ReconciliationFailed,
    SelfReceiver,
    Unauthorized,
    ZeroAddress,
    InvalidTokenList,
    InvalidPayoutAction,
    InvalidAmount,
    InvalidChainId
} from "./libraries/CoreErrors.sol";

/// @notice Sole physical vault for all Core positions per MANDATORY_CORE.md §3, §4, §8.2.
/// @dev HEALTHY-only: deficit paths revert DeficitNotImplemented until Wave 6.
contract CreditLedger is ICreditLedger {
    using ExactERC20 for IERC20;

    // ── EIP-712 ────────────────────────────────────────────────────────────────

    bytes32 private constant _TYPE_HASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 private constant _NAME_HASH = keccak256(bytes("PluriSwapCreditLedger"));
    bytes32 private constant _VERSION_HASH = keccak256(bytes("2"));
    bytes32 private constant _PAYOUT_AUTH_TYPEHASH = keccak256(
        "PositionPayoutAuth(uint8 action,address token,bytes32 positionId,address beneficiary,address to,uint256 maxAmount,uint256 nonce,uint64 expiry)"
    );

    // ── Immutables ──────────────────────────────────────────────────────────────

    address public immutable escrow;
    uint64 public immutable chainId;
    bytes32 public immutable DOMAIN_SEPARATOR;

    // ── Boundary state ─────────────────────────────────────────────────────────

    struct Boundary {
        uint8 mode; // 0=HEALTHY, 1=DEFICIT
        uint256 accountedAssets;
        uint256 nominalOutstanding;
        uint256 quarantinedSurplus;
        uint256 deficitNominalUnits;
    }

    mapping(address token => Boundary) internal _boundaries;

    // ── Positions ───────────────────────────────────────────────────────────────

    struct Position {
        uint256 nominal;
        uint8 kind; // PositionKind
        bytes32 sourceId;
        bytes32 terminalHash;
        address beneficiary;
        address token;
        bool exists;
        bool consumed;
    }

    mapping(bytes32 => Position) internal _positions;

    // ── Nonces ─────────────────────────────────────────────────────────────────

    mapping(address => mapping(uint8 => mapping(uint256 => bool))) internal _fundingNonceUsed;
    mapping(address => mapping(uint8 => mapping(uint256 => bool))) internal _payoutNonceUsed;

    // ── Reentrancy ─────────────────────────────────────────────────────────────

    uint256 private _locked = 1;

    modifier nonReentrant() {
        require(_locked == 1, "REENTRANCY");
        _locked = 2;
        _;
        _locked = 1;
    }

    modifier onlyEscrow() {
        if (msg.sender != escrow) revert Unauthorized();
        _;
    }

    constructor(address escrow_, uint64 chainId_) {
        if (escrow_ == address(0)) revert ZeroAddress();
        if (chainId_ != uint64(block.chainid)) revert InvalidChainId();
        escrow = escrow_;
        chainId = chainId_;
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(_TYPE_HASH, _NAME_HASH, _VERSION_HASH, uint256(chainId_), address(this))
        );
    }

    receive() external payable {
        revert();
    }

    fallback() external payable {
        revert();
    }

    // ── Reconciliation ─────────────────────────────────────────────────────────

    /// @dev Per §4.2. Returns status 0/1/3 (continue) or 4 (deficit, stops action).
    function _reconcile(address token) internal returns (uint8 status) {
        Boundary storage b = _boundaries[token];
        if (b.mode == BoundaryMode.Deficit) {
            // In deficit, reconcile but don't change mode (irreversible)
            return ReconciliationStatus.DeficitCheckpointed;
        }

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
                b.quarantinedSurplus
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
                b.quarantinedSurplus
            );
            return ReconciliationStatus.QuarantineLossAbsorbed;
        }

        // Deficit checkpointed
        b.accountedAssets -= residualLoss;
        b.mode = BoundaryMode.Deficit;
        b.deficitNominalUnits = b.nominalOutstanding;
        emit BoundaryReconciled(
            token,
            ReconciliationStatus.DeficitCheckpointed,
            expectedRaw,
            actualRaw,
            b.accountedAssets + residualLoss,
            b.accountedAssets,
            quarantinedBefore,
            b.quarantinedSurplus
        );
        emit DeficitEntered(token, b.deficitNominalUnits, b.accountedAssets);
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
    ) external nonReentrant onlyEscrow returns (uint8 reconciliationStatus) {
        uint8 status = _reconcile(token);
        if (status == ReconciliationStatus.DeficitCheckpointed) {
            return status;
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
            if (activationFeeRecipient == address(0)) revert ZeroAddress();
            if (activationFeeRecipient == address(this) || activationFeeRecipient == escrow) {
                revert SelfReceiver();
            }
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
            PositionKind.Deal,
            dealId,
            bytes32(0),
            address(0)
        );
        _createPosition(
            dealPosId, PositionKind.Deal, dealId, bytes32(0), address(0), token, principal
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
            if (sourcePos.nominal < expectedAmount) revert PositionNotFound();
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

    function planSettlement(
        bytes32 dealId,
        uint8 terminalState,
        uint8 outcome,
        uint16 providerBps,
        uint64 terminatedAt
    )
        external
        view
        onlyEscrow
        returns (
            TerminalRecord memory terminalRecord,
            bytes32 terminalHash,
            TerminalAllocation[] memory allocations
        )
    {
        Deal memory d = ICoreEscrow(escrow).getDeal(dealId);
        (uint256 holderGross, uint256 providerGross) =
            SettlementMath.split(d.principal, providerBps);
        uint256 completionCollected =
            SettlementMath.completionCollected(d.completionFee, providerGross);
        uint256 providerNet;
        unchecked {
            providerNet = providerGross - completionCollected;
        }

        terminalRecord = TerminalRecord({
            chainId: chainId,
            protocolVersion: 2,
            escrow: escrow,
            ledger: address(this),
            dealId: dealId,
            terminalState: terminalState,
            outcome: outcome,
            operatorFaultCode: 0,
            operatorFaultEvidenceHash: bytes32(0),
            token: d.token,
            principal: d.principal,
            holderSideReturn: holderGross,
            providerGross: providerGross,
            providerNet: providerNet,
            completionCollected: completionCollected,
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
            terminatedAt: terminatedAt
        });
        terminalHash = DealHashing.hashTerminalRecord(terminalRecord);
        uint256 count;
        if (holderGross > 0) ++count;
        if (providerNet > 0) ++count;
        if (completionCollected > 0) ++count;
        allocations = new TerminalAllocation[](count);
        uint256 index;
        if (holderGross > 0) {
            allocations[index++] = _terminalAllocation(
                d.custodyBoundaryId, dealId, terminalHash, d.holderReceiver, holderGross
            );
        }
        if (providerNet > 0) {
            allocations[index++] = _terminalAllocation(
                d.custodyBoundaryId, dealId, terminalHash, d.providerReceiver, providerNet
            );
        }
        if (completionCollected > 0) {
            allocations[index] = _terminalAllocation(
                d.custodyBoundaryId,
                dealId,
                terminalHash,
                d.completionFeeRecipient,
                completionCollected
            );
        }
    }

    function _terminalAllocation(
        bytes32 boundaryId,
        bytes32 dealId,
        bytes32 terminalHash,
        address beneficiary,
        uint256 amount
    ) private pure returns (TerminalAllocation memory) {
        return TerminalAllocation({
            beneficiary: beneficiary,
            amount: amount,
            positionId: DealHashing.positionId(
                boundaryId, PositionKind.DealTerminal, dealId, terminalHash, beneficiary
            )
        });
    }

    // ── Escrow-only: settlement ──────────────────────────────────────────────────

    function settleDealAndReservations(
        bytes32 dealId,
        address token,
        bytes32 terminalHash,
        TerminalAllocation[] calldata allocations
    ) external nonReentrant onlyEscrow returns (uint8 reconciliationStatus) {
        uint8 status = _reconcile(token);
        if (status == ReconciliationStatus.DeficitCheckpointed) {
            return status;
        }

        Boundary storage b = _boundaries[token];
        bytes32 boundaryId = DealHashing.custodyBoundaryId(chainId, 2, address(this), token);

        // Find and consume DEAL position
        bytes32 dealPosId =
            DealHashing.positionId(boundaryId, PositionKind.Deal, dealId, bytes32(0), address(0));
        Position storage dealPos = _positions[dealPosId];
        if (!dealPos.exists) revert PositionNotFound();
        if (dealPos.consumed) revert PositionAlreadyConsumed();

        uint256 dealNominal = dealPos.nominal;

        // Consume deal position
        dealPos.consumed = true;
        b.nominalOutstanding -= dealNominal;

        // Create terminal positions (coalesced by beneficiary within this deal)
        uint256 totalAllocated;
        for (uint256 i; i < allocations.length; ++i) {
            TerminalAllocation calldata alloc = allocations[i];
            if (alloc.amount == 0) continue;

            bytes32 termPosId = DealHashing.positionId(
                boundaryId, PositionKind.DealTerminal, dealId, terminalHash, alloc.beneficiary
            );
            Position storage existing = _positions[termPosId];
            if (existing.exists && !existing.consumed) {
                // Coalesce: add to existing terminal position
                existing.nominal += alloc.amount;
            } else if (!existing.exists) {
                _createPosition(
                    termPosId,
                    PositionKind.DealTerminal,
                    dealId,
                    terminalHash,
                    alloc.beneficiary,
                    token,
                    alloc.amount
                );
            } else {
                // Consumed tombstone with same id: collision
                revert PositionAlreadyExists();
            }
            totalAllocated += alloc.amount;
        }

        // Conservation check: total allocated must equal deal nominal
        if (totalAllocated != dealNominal) revert PositionNotFound(); // allocation mismatch

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
        if (pos.kind == PositionKind.Deal || pos.kind == PositionKind.Reservation) {
            revert PositionAlreadyConsumed(); // active positions not withdrawable
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
        if (pos.kind == PositionKind.Deal || pos.kind == PositionKind.Reservation) {
            revert PositionAlreadyConsumed();
        }
        if (auth.action != 1) revert InvalidPayoutAction();
        if (auth.token != pos.token) revert FundingSpecMismatch();
        if (auth.beneficiary != pos.beneficiary) revert Unauthorized();
        if (auth.to == address(0)) revert ZeroAddress();
        if (auth.to == address(this) || auth.to == escrow) revert SelfReceiver();
        if (auth.maxAmount == 0) revert InvalidAmount();
        if (block.timestamp >= auth.expiry) revert Expired();
        if (_payoutNonceUsed[auth.beneficiary][auth.action][auth.nonce]) revert NonceUsed();

        // Verify signature (Ledger domain)
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
        bytes32 digest_ = DealHashing.digest(DOMAIN_SEPARATOR, structHash);
        if (!SignatureValidation.isValid(auth.beneficiary, digest_, signature)) {
            revert FundingAuthInvalid();
        }

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
        address token = _tokenOf(positionId);
        if (token == address(0)) revert PositionNotFound();

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

    function checkpointBoundary(address token) external nonReentrant {
        if (token == address(0)) revert ZeroAddress();
        uint8 status = _reconcile(token);
        if (status != ReconciliationStatus.DeficitCheckpointed) {
            revert ReconciliationFailed(status);
        }
    }

    // ── Deficit stubs (Wave 6) ──────────────────────────────────────────────────

    function depositRecovery(address, address, uint256) external pure {
        revert DeficitNotImplemented();
    }

    function claimRecovery(bytes32, uint256) external pure returns (PositionPayoutResult memory) {
        revert DeficitNotImplemented();
    }

    function claimRecoveryTo(PositionPayoutAuth calldata, bytes calldata)
        external
        pure
        returns (PositionPayoutResult memory)
    {
        revert DeficitNotImplemented();
    }

    // ── Internal helpers ────────────────────────────────────────────────────────

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
            consumed: false
        });
        emit PositionCreated(positionId, kind, beneficiary, nominal);
    }

    /// @dev Get the token for a position (stored in the Position struct).
    function _tokenOf(bytes32 positionId) internal view returns (address) {
        return _positions[positionId].token;
    }

    function _verifySigner(address expected, bytes32 digest_, bytes calldata signature)
        internal
        view
    {
        if (!SignatureValidation.isValid(expected, digest_, signature)) {
            revert FundingAuthInvalid();
        }
    }

    // ── Views ───────────────────────────────────────────────────────────────────

    function boundaryMode(address token) external view returns (uint8) {
        return _boundaries[token].mode;
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

    function positionExists(bytes32 positionId) external view returns (bool) {
        return _positions[positionId].exists;
    }

    function positionNominal(bytes32 positionId) external view returns (uint256) {
        return _positions[positionId].nominal;
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
}
