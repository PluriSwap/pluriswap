// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev Kernel verb `identify`. Subject is the human, not the wallet.
interface IPassport {
    error NoPassport();

    function identify(address wallet) external view returns (bytes32 subject);
    function packageId() external view returns (bytes32);
}
