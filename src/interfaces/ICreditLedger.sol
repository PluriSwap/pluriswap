// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ICreditLedger {
    function credit(bytes32 dealId, address token, address beneficiary, uint256 amount) external;

    function reallocateRecovery(
        bytes32 dealId,
        address token,
        address fromBeneficiary,
        address toBeneficiary,
        uint256 units
    ) external;

    function withdraw(address token, address beneficiary) external;

    function withdrawTo(
        address token,
        address beneficiary,
        address to,
        uint256 amount,
        uint256 nonce,
        uint64 expiry,
        bytes calldata signature
    ) external;

    function syncDeficit(address token) external;

    function claimRecovery(address token, address beneficiary) external;

    function creditOf(address token, address beneficiary) external view returns (uint256);
    function liabilityOf(address token) external view returns (uint256);
    function assetsOf(address token) external view returns (uint256);
    function inDeficit(address token) external view returns (bool);
    function recoveryUnits(address token, address beneficiary) external view returns (uint256);
    function recoveryClaimed(address token, address beneficiary) external view returns (uint256);

    event Credited(
        bytes32 indexed dealId, address indexed token, address indexed beneficiary, uint256 amount
    );
    event Withdrawn(address indexed token, address indexed beneficiary, address to, uint256 amount);
    event DeficitEntered(address indexed token, uint256 totalUnits, uint256 assets);
    event RecoveryClaimed(address indexed token, address indexed beneficiary, uint256 amount);
    event RecoveryReallocated(
        bytes32 indexed dealId,
        address indexed token,
        address fromBeneficiary,
        address toBeneficiary,
        uint256 units
    );
}
