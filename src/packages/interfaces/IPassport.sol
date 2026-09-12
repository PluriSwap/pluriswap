// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev Kernel verb `identify`. Answers "is this wallet human under the adapter's policy?": returns the
///      subject that reputation, `inFlight` and bonds are keyed by, or reverts `NoPassport`. The official
///      adapter (`HumanPassport`) maps a passing wallet to itself; it does not identify the human behind it.
interface IPassport {
    error NoPassport();

    function identify(address wallet) external view returns (bytes32 subject);
    function packageId() external view returns (bytes32);
}
