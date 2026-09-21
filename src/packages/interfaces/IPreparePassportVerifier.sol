// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev Verifier of the `prepare_passport` circuit (PLURISWAP.md §3.15.9: public inputs
///      `dealSubject`, `repRoot`). The proof says: "I know `sk_id` whose account leaf sits in a
///      live tree, and `dealSubject = Poseidon(sk_id, dealId)`". Behind it: the real proof, or a
///      mock for integration — a passing mock is not privacy.
interface IPreparePassportVerifier {
    /// @notice MUST fail closed: a malformed proof reads as `false`, never as a revert-shaped pass.
    function verifyPassport(bytes32 dealSubject, bytes32 repRoot, bytes calldata proof) external view returns (bool);
}
