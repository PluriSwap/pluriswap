// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev Verifier of the `prepare_bond` circuit (PLURISWAP.md §3.15.9: public inputs `dealSubject`,
///      `dealId`, `token`, `lockAmount`, `lockCommit`, `changeNote`, `nullBond`, `bondRoot`). The
///      proof says: "I own the note behind `nullBond` (a leaf of `bondRoot`), a note of `token`
///      worth `noteAmount >= lockAmount`; I split it into
///      `lockCommit = Poseidon(sk_id, dealId, lockAmount, salt)` and
///      `changeNote = Poseidon(sk_id, token, noteAmount - lockAmount, changeSalt)`; and
///      `dealSubject = Poseidon(sk_id, dealId)`".
///      `lockAmount` is a public input because the contract cross-checks it at `reserve` against
///      §3.14.5: with a hidden amount, a split could under-cover its own lock and leave the vault
///      insolvent the day that lock is slashed. Notes are token-specific (§3.15.2): without
///      `token` in the public inputs, a USDC note could pay an ETH lock.
interface IPrepareBondVerifier {
    /// @notice MUST fail closed: a malformed proof reads as `false`, never as a revert-shaped pass.
    function verifyBond(
        bytes32 dealSubject,
        bytes32 dealId,
        address token,
        uint256 lockAmount,
        bytes32 lockCommit,
        bytes32 changeNote,
        bytes32 nullBond,
        bytes32 bondRoot,
        bytes calldata proof
    ) external view returns (bool);
}
