// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IReputation} from "./IReputation.sol";

/// @dev Verifier of the `claim` circuit (PLURISWAP.md §3.15.9: public inputs `dealId`, `dealSubject`,
///      `newLeaf`, `nullRep(v)`, `repRoot`, plus the delta values the contract reads from `pending`).
///      The proof says: "I know the account behind `dealSubject = Poseidon(sk_id, dealId)`; its current
///      leaf sits in a live tree; `newLeaf` is that leaf with the terminal delta (`kind`, `principal`,
///      `token`) applied — the atomic delta of PLURISWAP.md §3.15.5 — and `nullRep(v)` is the current
///      version's nullifier". The delta arithmetic (including no negative `inFlight`) is proven
///      in-circuit; the contract only trusts the verifier's word and manages tree, nullifiers and flags.
interface IClaimVerifier {
    /// @notice MUST fail closed: a malformed proof reads as `false`, never as a revert-shaped pass.
    function verifyClaim(
        bytes32 dealId,
        bytes32 dealSubject,
        bytes32 newLeaf,
        bytes32 nullRep,
        IReputation.Close kind,
        address token,
        uint256 principal,
        bytes32 repRoot,
        bytes calldata proof
    ) external view returns (bool);
}
