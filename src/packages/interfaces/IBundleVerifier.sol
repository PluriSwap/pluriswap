// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IBundleVerifier
/// @notice One side of an activation bundle, proven once and read by all three modules
///         (PLURISWAP.md §3.15.4, as-built 2026-09-23).
///
/// @dev The three per-module proofs of one side were always describing one deal, and overlapping
///      while they did it. `prepare_side` merges them; this is the surface the modules see.
///
///      The shape is deliberately two calls rather than one. A verifier that took the proof from
///      every module and cached the result would keep each module's code identical — but the proof
///      would ride in the calldata three times, and the calldata is the whole point (53,824 bytes
///      down to 19,200 for a two-sided activation). So the proof is submitted ONCE, and what the
///      modules pass around afterwards is the inputs, which they each need anyway.
///
///      What keeps the trust model intact: the ticket is keyed by the HASH OF THE INPUTS, so a
///      module can only be satisfied by a proof of exactly the values it is about to act on. Each
///      module then enforces its own statement out of those inputs — the passport that the subject
///      is the one it identifies, the reputation that the leaf, nullifier and cap are the ones it
///      will write, the vault that the lock and change note are the ones it will store. No module
///      trusts another; all three trust a verifier the parties named in their `packageId`.
///
///      Said plainly, because it is the cost of this design: the trust surface does not change in
///      kind — every module already trusts its own adapter — but it concentrates. One contract can
///      forge a bundle where before it took three. In exchange there is one contract to audit
///      instead of three, and the ticket lives in transient storage, so nothing survives the
///      transaction that created it.
interface IBundleVerifier {
    /// @notice The public inputs of `prepare_side`, in the circuit's declared order.
    /// @dev `decimals` is not here on purpose: it is a public input of the circuit, but the adapter
    ///      reads it from the served ERC-20 and requires the proof to have used that value — the
    ///      same amplification `PrepareAdmitVerifier` performs, and for the same reason (the tier
    ///      scale is `UNIT = 250 * 10^decimals`, so a proof scaled for another token's decimals
    ///      must not admit this deal).
    struct BundleInputs {
        bytes32 dealSubject;
        bytes32 dealId;
        address token;
        uint256 principal;
        bytes32 repRoot;
        bytes32 newLeaf;
        bytes32 nullRep;
        bytes32 pairTag;
        /// @dev Zero means a deal without bonds: the circuit masks its whole note half, and the
        ///      four fields below are zero with it.
        bytes32 lockCommit;
        uint256 lockAmount;
        bytes32 changeNote;
        bytes32 nullBond;
        bytes32 bondRoot;
    }

    /// @notice Verifies one side's proof and leaves a ticket for this transaction.
    /// @dev MUST fail closed: a malformed proof, a failed deploy or any revert inside the generated
    ///      verifier reads as `false`, never as a revert-shaped pass. Idempotent within a
    ///      transaction: a second call with the same inputs is a cheap `true`.
    function verify(BundleInputs calldata inputs, bytes calldata proof) external returns (bool);

    /// @notice Was exactly this side proven in THIS transaction?
    /// @dev What the modules call. The ticket is transient: it never answers `true` in a later
    ///      transaction, so a bundle cannot be assembled across blocks out of stale permission.
    function wasProven(BundleInputs calldata inputs) external view returns (bool);
}
