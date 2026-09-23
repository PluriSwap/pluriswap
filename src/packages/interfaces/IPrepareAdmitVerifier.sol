// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev Verifier of the `prepare_admit` circuit (PLURISWAP.md §3.15.9: public inputs `dealSubject`,
///      `newLeaf`, `nullRep(v)`, `principal`, `token`, `repRoot`, `lockCommit`). The proof says:
///      "I know the account behind `dealSubject`; its current leaf holds `inFlight + principal <= cap`
///      (tier computed in-circuit, PLURISWAP.md §3.14.7), and `newLeaf` is that leaf with the principal
///      taken into flight; `nullRep(v)` is the old version's nullifier". `lockCommit` is zero without
///      bonds (the private vault arrives in F3; the interface is frozen now so it never breaks).
interface IPrepareAdmitVerifier {
    /// @notice MUST fail closed: a malformed proof reads as `false`, never as a revert-shaped pass.
    function verifyAdmit(
        bytes32 dealSubject,
        bytes32 newLeaf,
        bytes32 nullRep,
        address token,
        uint256 principal,
        bytes32 lockCommit,
        bytes32 repRoot,
        /// @dev The §3.14.7 pair tag: both sides of one activation prove it over the same two account
        ///      commitments, and `admit` checks they match.
        bytes32 pairTag,
        bytes calldata proof
    ) external view returns (bool);
}
