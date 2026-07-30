// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    FundingSpec,
    FundingAuth,
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
    ) external;

    /// @notice Settle a deal: consume deal position, create coalesced terminal positions.
    /// @dev Escrow-only. No token transfer; reassigns existing positions.
    function settleDealAndReservations(
        bytes32 dealId,
        address token,
        bytes32 terminalHash,
        TerminalAllocation[] calldata allocations
    ) external;

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

    /// @notice Persist DEFICIT if token assets are below liabilities.
    function checkpointBoundary(address token) external;

    /// @notice Deposit attributable recovery into a deficit boundary.
    /// @dev Reverts DeficitNotImplemented until O(1) encoding is proven (Wave 6).
    function depositRecovery(address token, address from, uint256 amount) external;

    /// @notice Claim recovery from a deficit position (pro-rata).
    /// @dev Reverts DeficitNotImplemented until O(1) encoding is proven (Wave 6).
    function claimRecovery(bytes32 positionId, uint256 maxAmount)
        external
        returns (PositionPayoutResult memory);

    /// @notice Signed recovery claim to an alternate receiver.
    /// @dev Reverts DeficitNotImplemented until O(1) encoding is proven (Wave 6).
    function claimRecoveryTo(PositionPayoutAuth calldata auth, bytes calldata signature)
        external
        returns (PositionPayoutResult memory);

    // ── Views ──────────────────────────────────────────────────────────────────

    function escrow() external view returns (address);
    function chainId() external view returns (uint64);
    function DOMAIN_SEPARATOR() external view returns (bytes32);

    function boundaryMode(address token) external view returns (uint8);
    function accountedAssets(address token) external view returns (uint256);
    function nominalOutstanding(address token) external view returns (uint256);
    function quarantinedSurplus(address token) external view returns (uint256);
    function inDeficit(address token) external view returns (bool);

    function positionExists(bytes32 positionId) external view returns (bool);
    function positionNominal(bytes32 positionId) external view returns (uint256);
    function positionBeneficiary(bytes32 positionId) external view returns (address);
    function positionKind(bytes32 positionId) external view returns (uint8);
    function positionConsumed(bytes32 positionId) external view returns (bool);

    // ── Events ──────────────────────────────────────────────────────────────────

    event BoundaryReconciled(
        address indexed token,
        uint8 status,
        uint256 expectedRawBefore,
        uint256 actualRaw,
        uint256 accountedAssetsBefore,
        uint256 accountedAssetsAfter,
        uint256 quarantinedSurplusBefore,
        uint256 quarantinedSurplusAfter
    );
    event DealFunded(bytes32 indexed dealId, address indexed token, uint256 principal, uint256 activationFee);
    event DealSettled(bytes32 indexed dealId, address indexed token, bytes32 terminalHash);
    event PositionCreated(bytes32 indexed positionId, uint8 kind, address indexed beneficiary, uint256 nominal);
    event PositionConsumed(bytes32 indexed positionId);
    event PositionWithdrawn(bytes32 indexed positionId, address to, uint256 amount);
    event DeficitEntered(address indexed token, uint256 nominalUnits, uint256 assets);
    event RecoveryDeposited(address indexed token, uint256 amount);
    event RecoveryClaimed(bytes32 indexed positionId, address to, uint256 amount);
}
