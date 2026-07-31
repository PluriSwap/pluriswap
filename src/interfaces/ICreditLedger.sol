// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    FundingSpec,
    FundingAuth,
    PositionView,
    PositionPayoutAuth,
    PositionPayoutResult,
    TerminalAllocation
} from "../libraries/DealTypes.sol";

interface ICreditLedger {
    // ── Escrow-only custody commands ───────────────────────────────────────────

    /// @notice Reconcile a sorted/unique set of token boundaries before any stateful action.
    /// @return statuses Per-token reconciliation status (0/1/3 continue, 4 = deficit).
    function preflightValueAction(address[] calldata tokens)
        external
        returns (uint8[] memory statuses);

    /// @notice Fund a deal: validate funding specs/auths, exact-pull or debit, create positions.
    /// @dev Escrow-only. Atomic: all-or-nothing rollback on any failure.
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
    ) external returns (uint8 reconciliationStatus);

    /// @notice Settle a deal: consume deal position, create coalesced terminal positions.
    /// @dev Escrow-only. At most three unique/final allocations; over-count rejects before
    ///      reconciliation, while duplicate or existing targets reject atomically.
    ///      No token transfer; reassigns existing positions and freezes the source components.
    function settleDealAndReservations(
        bytes32 dealId,
        address token,
        bytes32 terminalHash,
        TerminalAllocation[] calldata allocations
    ) external returns (uint8 reconciliationStatus);

    // ── Permissionless withdrawals ─────────────────────────────────────────────

    /// @notice Withdraw from a matured beneficiary position (finite or sentinel cap).
    function withdrawPosition(bytes32 positionId, uint256 maxAmount)
        external
        returns (PositionPayoutResult memory);

    /// @notice Signed withdrawal to an alternate receiver.
    function withdrawPositionTo(PositionPayoutAuth calldata auth, bytes calldata signature)
        external
        returns (PositionPayoutResult memory);

    // ── Permissionless boundary / deficit ──────────────────────────────────────

    /// @notice Persist the current valid reconciliation result for a token boundary.
    /// @return reconciliationStatus One of the closed valid statuses 0/1/3/4.
    function checkpointBoundary(address token) external returns (uint8 reconciliationStatus);

    /// @notice Deposit caller-funded attributable recovery into a deficit boundary.
    /// @dev Exact-pulls only from msg.sender, never above the remaining nominal gap.
    function depositRecovery(address token, uint256 amount)
        external
        returns (uint8 reconciliationStatus);

    /// @notice Claim recovery from a deficit position (pro-rata).
    /// @dev Claims use conservative fixed-point entitlement and may leave bounded dust.
    function claimRecovery(bytes32 positionId, uint256 maxAmount)
        external
        returns (PositionPayoutResult memory);

    /// @notice Signed recovery claim to an alternate receiver.
    /// @dev Action 2 uses the same payout nonce namespace as other signed payouts.
    function claimRecoveryTo(PositionPayoutAuth calldata auth, bytes calldata signature)
        external
        returns (PositionPayoutResult memory);

    // ── Views ──────────────────────────────────────────────────────────────────

    function escrow() external view returns (address);
    function coordinator() external view returns (address);
    function chainId() external view returns (uint64);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function MAX_BOUNDARY_NOMINAL() external view returns (uint256);

    function boundaryMode(address token) external view returns (uint8);
    function boundaryCheckpointId(address token) external view returns (bytes32);
    function accountedAssets(address token) external view returns (uint256);
    function nominalOutstanding(address token) external view returns (uint256);
    function quarantinedSurplus(address token) external view returns (uint256);
    function inDeficit(address token) external view returns (bool);
    function deficitPaidAssets(address token) external view returns (uint256);
    function deficitNominalUnits(address token) external view returns (uint256);
    function deficitGapCoefficient(address token) external view returns (uint256);
    function deficitHistoryScale(address token) external view returns (uint256);
    function deficitHistoryTotal(address token) external view returns (uint256);
    function deficitGeneration(address token) external view returns (uint256);
    function deficitRoundingDust(address token) external view returns (uint256);
    function deficitPrecisionFloor(address token) external view returns (bool);

    /// @notice Return the canonical O(1) position view.
    /// @dev A missing query echoes `positionId`; every other field is canonical zero/false.
    ///      A replaced source returns immutable child-sum components and direct
    ///      `replacementRoundingDust`; add dust to funded and subtract it from gap to reconstruct
    ///      the production pre-split materialization.
    function getPosition(bytes32 positionId) external view returns (PositionView memory);

    function positionExists(bytes32 positionId) external view returns (bool);

    /// @notice Return stored nominal units, fixed through claims after deficit entry.
    function positionNominal(bytes32 positionId) external view returns (uint256);

    /// @notice Return currently unpaid nominal units.
    /// @dev For a replaced source tombstone this is its replacement-time remaining nominal,
    ///      retained for provenance; it is not currently claimable.
    function positionNominalRemaining(bytes32 positionId) external view returns (uint256);

    function positionBeneficiary(bytes32 positionId) external view returns (address);
    function positionKind(bytes32 positionId) external view returns (uint8);
    function positionConsumed(bytes32 positionId) external view returns (bool);
    function positionTerminalHash(bytes32 positionId) external view returns (bytes32);

    // ── Events ──────────────────────────────────────────────────────────────────

    event BoundaryReconciled(
        address indexed token,
        uint8 status,
        uint256 expectedRawBefore,
        uint256 actualRaw,
        uint256 accountedAssetsBefore,
        uint256 accountedAssetsAfter,
        uint256 quarantinedSurplusBefore,
        uint256 quarantinedSurplusAfter,
        bytes32 checkpointId
    );
    event DealFunded(
        bytes32 indexed dealId, address indexed token, uint256 principal, uint256 activationFee
    );
    event DealSettled(bytes32 indexed dealId, address indexed token, bytes32 terminalHash);
    event PositionCreated(
        bytes32 indexed positionId, uint8 kind, address indexed beneficiary, uint256 nominal
    );
    event PositionConsumed(bytes32 indexed positionId);
    event PositionWithdrawn(bytes32 indexed positionId, address to, uint256 amount);
    event DeficitEntered(address indexed token, uint256 nominalUnits, uint256 assets);
    event LossCheckpointed(
        address indexed token,
        bytes32 indexed checkpointId,
        uint256 accountedAssets,
        uint256 nominalOutstanding,
        uint256 deficitNominalUnits,
        uint256 deficitPaidAssets,
        uint256 deficitGapCoefficient,
        uint256 deficitHistoryScale,
        uint256 deficitHistoryTotal,
        uint256 deficitGeneration,
        uint256 deficitRoundingDust,
        bool deficitPrecisionFloor
    );
    event RecoveryDeposited(address indexed token, uint256 amount);
    event RecoveryClaimed(bytes32 indexed positionId, address to, uint256 amount);
}
