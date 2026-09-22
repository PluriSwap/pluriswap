// The chain-consistency reference lib of the disclosure layer (PLURISWAP.md §3.15.7, F4
// as-built). A consumer asking "how has this account behaved over time" receives a
// SEQUENCE of attestations — a disclosure the account owner chose to give, each element
// a true statement about a real state of the account tree. This lib certifies the
// consistency of WHAT WAS DELIVERED:
//
//   * every element verifies (proof + its own semantic checks, via verify.ts);
//   * ONE handleCommit across the whole series — one account's disclosure, not a
//     splice of several (the handle is the only continuity the chain has: the §3.15.7
//     model is states, not events, so nothing else binds the series together);
//   * the RAW counters are component-wise monotone NON-DECREASING in the order given:
//     count (attest_base elements) and volume/penalty where revealed (reveal_advanced
//     elements with the mask bit set). §3.15.5's deltas only ever ADD — a decreasing
//     element is a fabricated sequence, and this is the check that catches it.
//
// What this lib deliberately does NOT do:
//   * the TIER is not monotone — a Stalemate (+5) can drop a T2 account to T1 mid-chain,
//     and an honest chain shows exactly that; checking tiers for decrease would reject
//     the honest case the design wants visible;
//   * the GAPS are not priced here — the user's selection freedom (which elements to
//     hand over) is bounded only by the consumer's own receipts: verifyAttestationChain
//     certifies what arrived, the cadence policy (and the price of a missing month) is
//     the consumer's, per §3.15.7's "el listado muestra attestations frescas".
//
// Pure logic over verify.ts — no bb, no chain reads the consumer did not inject.

import {
  AttestBasePubs,
  AttestationEnvelope,
  RevealAdvancedPubs,
  VerifyOpts,
  VerifyResult,
  verifyAttestationBase,
  verifyAttestationReveal,
} from "./verify.ts";

export type ChainElement =
  | ({ kind: "base" } & AttestationEnvelope<AttestBasePubs>)
  | ({ kind: "reveal" } & AttestationEnvelope<RevealAdvancedPubs>);

/** Verify a delivered attestation series: per-element verification + the one-handle and
 *  raw-monotonicity consistency checks. `opts` is verify.ts's (clock, decimals, root
 *  liveness, proof verifier) — inject the chain reads; the lib adds no reads of its own. */
export async function verifyAttestationChain(
  chain: ChainElement[],
  opts: VerifyOpts,
): Promise<VerifyResult> {
  const errors: string[] = [];
  const checks: string[] = [];

  if (chain.length === 0) {
    errors.push("empty chain — nothing was disclosed");
    return { ok: false, errors, checks: [] };
  }

  // One handle across the series (checked first: a spliced chain fails before anything
  // else does, with the clearest message).
  const handle = chain[0].pubs.handle_commit;
  let oneHandle = true;
  chain.forEach((el, i) => {
    if (el.pubs.handle_commit !== handle) {
      errors.push(`element ${i}: handle_commit differs from element 0 — two accounts spliced?`);
      oneHandle = false;
    }
  });
  if (oneHandle) checks.push(`one handle across ${chain.length} elements`);

  // Per-element verification (the consumer's injected checks ride along).
  for (const [i, el] of chain.entries()) {
    const r = el.kind === "base" ? await verifyAttestationBase(el, opts) : await verifyAttestationReveal(el, opts);
    for (const e of r.errors) errors.push(`element ${i}: ${e}`);
    checks.push(`element ${i}: ${r.checks.join("; ")}`);
  }

  // Raw monotonicity, in the order delivered (the consumer orders by its receipts).
  let lastCount: bigint | undefined;
  let lastVolume: bigint | undefined;
  let lastPenalty: bigint | undefined;
  chain.forEach((el, i) => {
    if (el.kind === "base") {
      const count = BigInt(el.pubs.count);
      if (lastCount !== undefined && count < lastCount) {
        errors.push(`element ${i}: count ${count} decreased from ${lastCount} — count never decreases (§3.15.5)`);
      }
      lastCount = count;
    } else {
      const mask = Number(BigInt(el.pubs.fields_mask));
      if (mask & 1) {
        const volume = BigInt(el.pubs.out_volume);
        if (lastVolume !== undefined && volume < lastVolume) {
          errors.push(`element ${i}: volume ${volume} decreased from ${lastVolume} — volume never decreases (§3.15.5)`);
        }
        lastVolume = volume;
      }
      if (mask & 2) {
        const penalty = BigInt(el.pubs.out_penalty);
        if (lastPenalty !== undefined && penalty < lastPenalty) {
          errors.push(`element ${i}: penalty ${penalty} decreased from ${lastPenalty} — penalty never decreases (§3.15.5)`);
        }
        lastPenalty = penalty;
      }
    }
  });

  return { ok: errors.length === 0, errors, checks };
}
