// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICreditLedger} from "./interfaces/ICreditLedger.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IERC1271} from "./interfaces/IERC1271.sol";
import {ExactERC20} from "./libraries/ExactERC20.sol";
import {DealHashing} from "./libraries/DealHashing.sol";
import {
    FundingSpec,
    FundingAuth,
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
    DeficitNotImplemented,
    ExactTransferFailed,
    Expired,
    FundingAuthInvalid,
    FundingSpecMismatch,
    InvalidFundingMode,
    NonceUsed,
    PositionAlreadyExists,
    PositionAlreadyConsumed,
    PositionNotFound,
    ReconciliationFailed,
    SelfReceiver,
    Unauthorized,
    ZeroAddress
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
        "PositionPayoutAuth(bytes32 positionId,address beneficiary,address to,uint256 maxAmount,uint256 nonce,uint64 expiry)"
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

    mapping(address => mapping(uint256 => bool)) internal _fundingNonceUsed;
    mapping(address => mapping(uint256 => bool)) internal _payoutNonceUsed;

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
        escrow = escrow_;
        chainId = chainId_;
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(_TYPE_HASH, _NAME_HASH, _VERSION_HASH, uint256(chainId_), address(this))
        );
    }

    receive() external payable { revert(); }
    fallback() external payable { revert(); }

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
                token, ReconciliationStatus.SurplusQuarantined, expectedRaw, actualRaw,
                b.accountedAssets, b.accountedAssets, b.quarantinedSurplus - (actualRaw - expectedRaw),
                b.quarantinedSurplus
            );
            return ReconciliationStatus.SurplusQuarantined;
        }

        if (actualRaw == expectedRaw) {
            return ReconciliationStatus.Unchanged;
        }

        // actualRaw < expectedRaw: negative delta
        uint256 negativeDelta = expectedRaw - actualRaw;
        uint256 absorbed = negativeDelta < b.quarantinedSurplus
            ? negativeDelta
            : b.quarantinedSurplus;
        uint256 quarantinedBefore = b.quarantinedSurplus;
        b.quarantinedSurplus -= absorbed;
        uint256 residualLoss = negativeDelta - absorbed;

        if (residualLoss == 0) {
            // Fully absorbed by quarantine
            emit BoundaryReconciled(
                token, ReconciliationStatus.QuarantineLossAbsorbed, expectedRaw, actualRaw,
                b.accountedAssets, b.accountedAssets, quarantinedBefore, b.quarantinedSurplus
            );
            return ReconciliationStatus.QuarantineLossAbsorbed;
        }

        // Deficit checkpointed
        b.accountedAssets -= residualLoss;
        b.mode = BoundaryMode.Deficit;
        b.deficitNominalUnits = b.nominalOutstanding;
        emit BoundaryReconciled(
            token, ReconciliationStatus.DeficitCheckpointed, expectedRaw, actualRaw,
            b.accountedAssets + residualLoss, b.accountedAssets, quarantinedBefore, b.quarantinedSurplus
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
            statuses[i] = _reconcile(tokens[i]);
        }
    }

    // ── Escrow-only: funding ─────────────────────────────────────────────────────

    function fundDealAndReservations(
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
    ) external nonReentrant onlyEscrow {
        Boundary storage b = _boundaries[token];
        uint8 status = _reconcile(token);
        if (status == ReconciliationStatus.DeficitCheckpointed) {
            revert ReconciliationFailed(status);
        }

        // Validate and execute principal funding
        _validateAndFund(
            token, dealId, principalFunding, principalFundingAuth, principalFundingSig,
            FundingPurpose.Principal, principal, b
        );

        // Validate and execute activation fee funding (if nonzero)
        if (activationFee > 0) {
            if (activationFeeRecipient == address(0)) revert ZeroAddress();
            if (activationFeeRecipient == address(this) || activationFeeRecipient == escrow) {
                revert SelfReceiver();
            }
            _validateAndFund(
                token, dealId, activationFeeFunding, activationFeeFundingAuth,
                activationFeeFundingSig, FundingPurpose.ActivationFee, activationFee, b
            );
            // Create ACTIVATION_FEE position
            bytes32 feePosId = DealHashing.positionId(
                DealHashing.custodyBoundaryId(chainId, 2, address(this), token),
                PositionKind.ActivationFee, dealId, bytes32(0), activationFeeRecipient
            );
            _createPosition(feePosId, PositionKind.ActivationFee, dealId, bytes32(0),
                activationFeeRecipient, token, activationFee);
        }

        // Create DEAL position
        bytes32 dealPosId = DealHashing.positionId(
            DealHashing.custodyBoundaryId(chainId, 2, address(this), token),
            PositionKind.Deal, dealId, bytes32(0), address(0)
        );
        _createPosition(dealPosId, PositionKind.Deal, dealId, bytes32(0), address(0), token, principal);

        emit DealFunded(dealId, token, principal, activationFee);
    }

    function _validateAndFund(
        address token,
        bytes32 dealId,
        FundingSpec calldata spec,
        FundingAuth calldata auth,
        bytes calldata sig,
        uint8 expectedPurpose,
        uint256 expectedAmount,
        Boundary storage b
    ) internal {
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
        if (auth.fundingSpecHash != specHash) revert FundingSpecMismatch();
        if (auth.purpose != expectedPurpose) revert FundingSpecMismatch();
        if (auth.authority != spec.authority) revert FundingAuthInvalid();
        if (block.timestamp >= auth.expiry) revert Expired();
        if (_fundingNonceUsed[auth.authority][auth.nonce]) revert NonceUsed();

        bytes32 authDigest = DealHashing.digest(DOMAIN_SEPARATOR, DealHashing.hashFundingAuth(auth));
        _verifySigner(auth.authority, authDigest, sig);

        // Execute funding
        if (spec.sourceMode == FundingSourceMode.WalletPull) {
            IERC20(token).pullExact(spec.source, expectedAmount);
        } else {
            // LEDGER_POSITION: debit from existing matured position
            Position storage sourcePos = _positions[spec.sourcePositionId];
            if (!sourcePos.exists) revert PositionNotFound();
            if (sourcePos.consumed) revert PositionAlreadyConsumed();
            if (sourcePos.beneficiary != spec.authority) revert Unauthorized();
            if (sourcePos.nominal < expectedAmount) revert PositionNotFound();
            sourcePos.nominal -= expectedAmount;
            if (sourcePos.nominal == 0) sourcePos.consumed = true;
        }

        // Consume funding nonce
        _fundingNonceUsed[auth.authority][auth.nonce] = true;

        // Update accounting
        b.accountedAssets += expectedAmount;
        b.nominalOutstanding += expectedAmount;
    }

    // ── Escrow-only: settlement ──────────────────────────────────────────────────

    function settleDealAndReservations(
        bytes32 dealId,
        address token,
        bytes32 terminalHash,
        TerminalAllocation[] calldata allocations
    ) external nonReentrant onlyEscrow {
        uint8 status = _reconcile(token);
        if (status == ReconciliationStatus.DeficitCheckpointed) {
            revert ReconciliationFailed(status);
        }

        Boundary storage b = _boundaries[token];
        bytes32 boundaryId = DealHashing.custodyBoundaryId(chainId, 2, address(this), token);

        // Find and consume DEAL position
        bytes32 dealPosId = DealHashing.positionId(
            boundaryId, PositionKind.Deal, dealId, bytes32(0), address(0)
        );
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
                    termPosId, PositionKind.DealTerminal, dealId, terminalHash,
                    alloc.beneficiary, token, alloc.amount
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
    }

    // ── Permissionless withdrawals ─────────────────────────────────────────────

    function withdrawPosition(bytes32 positionId, uint256 maxAmount)
        external
        nonReentrant
        returns (PositionPayoutResult memory)
    {
        Position storage pos = _positions[positionId];
        if (!pos.exists) revert PositionNotFound();
        if (pos.consumed) revert PositionAlreadyConsumed();
        if (pos.kind == PositionKind.Deal || pos.kind == PositionKind.Reservation) {
            revert PositionAlreadyConsumed(); // active positions not withdrawable
        }

        uint256 available = pos.nominal;
        uint256 pay = maxAmount == type(uint256).max ? available : maxAmount;
        if (pay > available) pay = available;
        if (pay == 0) {
            return PositionPayoutResult({
                resultCode: PayoutResultCode.ZeroPayable,
                amountPaid: 0,
                remainingNominal: pos.nominal,
                consumed: false
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
        if (pos.consumed) revert PositionAlreadyConsumed();
        if (pos.kind == PositionKind.Deal || pos.kind == PositionKind.Reservation) {
            revert PositionAlreadyConsumed();
        }
        if (auth.beneficiary != pos.beneficiary) revert Unauthorized();
        if (auth.to == address(0)) revert ZeroAddress();
        if (auth.to == address(this) || auth.to == escrow) revert SelfReceiver();
        if (block.timestamp >= auth.expiry) revert Expired();
        if (_payoutNonceUsed[auth.beneficiary][auth.nonce]) revert NonceUsed();

        // Verify signature (Ledger domain)
        bytes32 structHash = keccak256(
            abi.encode(
                _PAYOUT_AUTH_TYPEHASH, auth.positionId, auth.beneficiary, auth.to,
                auth.maxAmount, auth.nonce, auth.expiry
            )
        );
        bytes32 digest_ = DealHashing.digest(DOMAIN_SEPARATOR, structHash);
        _verifySigner(auth.beneficiary, digest_, signature);

        _payoutNonceUsed[auth.beneficiary][auth.nonce] = true;

        uint256 available = pos.nominal;
        uint256 pay = auth.maxAmount == type(uint256).max ? available : auth.maxAmount;
        if (pay > available) pay = available;
        if (pay == 0) {
            return PositionPayoutResult({
                resultCode: PayoutResultCode.ZeroPayable,
                amountPaid: 0,
                remainingNominal: pos.nominal,
                consumed: false
            });
        }

        return _executeWithdraw(auth.positionId, pos, auth.to, pay);
    }

    function _executeWithdraw(
        bytes32 positionId,
        Position storage pos,
        address to,
        uint256 pay
    ) internal returns (PositionPayoutResult memory) {
        address token = _tokenOf(positionId);
        if (token == address(0)) revert PositionNotFound();

        uint8 status = _reconcile(token);
        if (status == ReconciliationStatus.DeficitCheckpointed) {
            revert DeficitNotImplemented();
        }

        Boundary storage b = _boundaries[token];
        pos.nominal -= pay;
        if (pos.nominal == 0) pos.consumed = true;
        b.nominalOutstanding -= pay;
        b.accountedAssets -= pay;

        IERC20(token).pushExact(to, pay);

        emit PositionWithdrawn(positionId, to, pay);

        return PositionPayoutResult({
            resultCode: pos.consumed ? PayoutResultCode.HealthyFull : PayoutResultCode.HealthyPartial,
            amountPaid: pay,
            remainingNominal: pos.nominal,
            consumed: pos.consumed
        });
    }

    // ── Permissionless boundary checkpoint ──────────────────────────────────────

    function checkpointBoundary(address token) external nonReentrant {
        uint8 status = _reconcile(token);
        if (status != ReconciliationStatus.DeficitCheckpointed) {
            revert ReconciliationFailed(status);
        }
    }

    // ── Deficit stubs (Wave 6) ──────────────────────────────────────────────────

    function depositRecovery(address, address, uint256) external pure {
        revert DeficitNotImplemented();
    }

    function claimRecovery(bytes32, uint256)
        external
        pure
        returns (PositionPayoutResult memory)
    {
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
        if (expected.code.length > 0) {
            bytes4 magic = IERC1271(expected).isValidSignature(digest_, signature);
            if (magic != 0x1626ba7e) revert FundingAuthInvalid();
            return;
        }
        if (signature.length != 65) revert FundingAuthInvalid();
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        address signer = ecrecover(digest_, v, r, s);
        if (signer == address(0) || signer != expected) revert FundingAuthInvalid();
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
