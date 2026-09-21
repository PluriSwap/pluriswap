// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev Verifier of the `register` account circuit (PLURISWAP.md §3.15.9: public inputs `hn`, `leaf0`).
///      Behind it: the real proof, or a mock for integration — a passing mock is not privacy.
interface IAccountVerifier {
    /// @notice MUST fail closed: a malformed proof reads as `false`, never as a revert-shaped pass.
    function verifyAccount(bytes calldata proof, bytes32 hn, bytes32 leaf0) external view returns (bool);
}
