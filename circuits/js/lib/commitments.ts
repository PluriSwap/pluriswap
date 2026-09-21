// The canonical commitments of the private layer (PLURISWAP.md §3.15.3, amended by the
// canonical-encoding decision of the verifier work): one builder per commitment the
// circuits prove about, implemented identically in Noir (vendored circomlib Poseidon),
// in JS (this twin) and in Solidity (`src/packages/libraries/PrivacyCommitments.sol`).
//
// Multi-field commitments chain PoseidonT3 in a pinned left fold over the field order of
// §3.15.3 (h0 = f0, hi = Poseidon2(h(i-1), fi)) — poseidon-solidity has no wide units
// beyond T6, and the tree only ever hashes pairs, so the two-input permutation is the
// single primitive of the whole protocol.
//
// Nullifier tags are pinned field constants (not string hashes): they live inside the
// Poseidon domain of this protocol only, which the canonical library owns end to end.

import { chain, poseidon1, poseidon2 } from "./poseidon.ts";

export const TAG_REP = 1n;
export const TAG_BOND = 2n;
export const TAG_HANDLE = 3n;

/** `S = Poseidon(sk_id)` — the account; never on-chain in the clear (lives inside leafRep). */
export async function accountCommitment(skId: bigint): Promise<bigint> {
  return poseidon1(skId);
}

/** `hn = Poseidon(anchor, registryId)` — the humanity nullifier; anchor = Passport-live address. */
export async function hn(anchor: bigint, registryId: bigint): Promise<bigint> {
  return poseidon2(anchor, registryId);
}

/** `dealSubject = Poseidon(sk_id, dealId)` — the per-deal pseudonym; all the kernel ever sees. */
export async function dealSubject(skId: bigint, dealId: bigint): Promise<bigint> {
  return poseidon2(skId, dealId);
}

/** `nullRep = Poseidon(sk_id, "rep", version)` — one use per account version. */
export async function nullRep(skId: bigint, version: bigint): Promise<bigint> {
  return chain([skId, TAG_REP, version]);
}

/** `nullBond = Poseidon(sk_id, "bond", noteSalt)` — one use per spent note. */
export async function nullBond(skId: bigint, noteSalt: bigint): Promise<bigint> {
  return chain([skId, TAG_BOND, noteSalt]);
}

/** `handleCommit = Poseidon(sk_id, "handle", handleSalt)` — the rotable market pseudonym. */
export async function handleCommit(skId: bigint, handleSalt: bigint): Promise<bigint> {
  return chain([skId, TAG_HANDLE, handleSalt]);
}

/** `noteBond = Poseidon(sk_id, token, amount, salt)` — token-specific note of the vault (F3). */
export async function noteBond(skId: bigint, token: bigint, amount: bigint, salt: bigint): Promise<bigint> {
  return chain([skId, token, amount, salt]);
}

/** `lockCommit = Poseidon(sk_id, dealId, lockAmount, salt)` — the earmark a reserve proves openable.
 *  The fold's first step is exactly `dealSubject`: the lock is bound to the deal pseudonym. */
export async function lockCommit(skId: bigint, dealId: bigint, lockAmount: bigint, salt: bigint): Promise<bigint> {
  return chain([skId, dealId, lockAmount, salt]);
}

/** `leafRep = Poseidon(S, count, volume, penalty, inFlight, token, salt, version)` — the account leaf. */
export async function leafRep(
  s: bigint,
  count: bigint,
  volume: bigint,
  penalty: bigint,
  inFlight: bigint,
  token: bigint,
  salt: bigint,
  version: bigint,
): Promise<bigint> {
  return chain([s, count, volume, penalty, inFlight, token, salt, version]);
}
