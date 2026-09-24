// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IPaymentVerifier
/// @notice The rail's side of `PAYMENT_PROOF` (PLURISWAP.md §3.12.1): one statement every rail proves,
///         whatever technology carries the evidence — zkEmail, zkTLS, a signed Open Finance response.
///
/// @dev The statement is small on purpose, and it is the whole of what the kernel's side knows:
///
///        a payment happened, at or after `notBefore`, that opens `fiatCommit` —
///        same rail, same currency, at least the amount, to the same payee (§3.13) —
///        and this proof is about `dealId`.
///
///      The module builds the claim from the escrow (the signed terms and the activation clock), never
///      from the caller, and asks the adapter whether the proof names exactly that claim. Everything
///      rail-specific lives behind this interface: the circuit, its public-input layout, the mod-p
///      reduction of `dealId` at the boundary, and the TRUST ANCHORS — the DKIM key, the notary key, the
///      bank's signing key. How those anchors rotate is a policy decision of each rail's adapter, and
///      this interface is shaped so it can be made there without touching the module or the kernel.
///
///      `paymentNullifier` is the circuit's public output: derived from the rail's own transaction id,
///      so two pieces of evidence about ONE payment (two notification mails, a mail and a statement)
///      name the same nullifier and settle at most one deal.
///
///      Fail-closed, like every adapter of this protocol: a malformed blob, a mismatch, a failed deploy
///      or any revert inside the generated verifier returns `ok == false` — never a revert-shaped pass.
interface IPaymentVerifier {
    struct PaymentClaim {
        bytes32 dealId; // raw kernel id; the adapter compares it reduced mod p
        bytes32 fiatCommit; // from the signed terms; the module has checked it is a field element
        uint64 notBefore; // the deal's activation time: a payment before the escrow existed is not for it
    }

    function verify(PaymentClaim calldata claim, bytes calldata proof)
        external
        view
        returns (bool ok, bytes32 paymentNullifier);
}
