// The admission tiers of PLURISWAP.md §3.14.7 — the JS twin. The same table the circuit
// computes in-circuit (`pluri_commitments::tiers`) and the on-chain reputation reads
// (`Reputation.score` / `Reputation._capTokens`); test/fixtures/vectors.json pins the
// three against each other.
//
//   score = satSub(count + volume / UNIT, penalty),   UNIT = 250 * 10^decimals
//
// Integer division (truncated) on the volume, saturating subtraction on the penalty.
// The caps are per-token integers: base and with-bond columns, T5 unbounded.

/** The tier's score, computed exactly as §3.14.7's Solidity view: truncating division and
 *  saturating subtraction, all integer. */
export function score(count: bigint, volume: bigint, penalty: bigint, decimals: bigint): bigint {
  const unit = 250n * 10n ** decimals;
  const raw = count + volume / unit;
  return raw > penalty ? raw - penalty : 0n;
}

/** The cap in whole tokens of the tier a score buys, or null when unbounded (T5).
 *  Mirrors `Reputation._capTokens`'s table — thresholds 0/10/25/50/100, base column
 *  250/500/1000/2000, bond column 400/700/1500/5000. */
export function capUnits(sc: bigint, withBond: boolean): bigint | null {
  if (sc >= 100n) return null;
  if (sc >= 50n) return withBond ? 5000n : 2000n;
  if (sc >= 25n) return withBond ? 1500n : 1000n;
  if (sc >= 10n) return withBond ? 700n : 500n;
  return withBond ? 400n : 250n;
}

/** The cap in raw token units (`capUnits * 10^decimals`), or null when unbounded. */
export function capRaw(sc: bigint, withBond: boolean, decimals: bigint): bigint | null {
  const units = capUnits(sc, withBond);
  return units === null ? null : units * 10n ** decimals;
}

/** The tier ordinal a score buys (1..5) — the disclosure layer's (F4) reading of the same
 *  ladder: `attest_base`'s claimed tier is a LOWER bound of this. `capUnits` returns 0
 *  for T5; here the ordinal is explicit — the attestation's public semantics is the
 *  tier, not the cap. */
export function tierOf(sc: bigint): bigint {
  if (sc >= 100n) return 5n;
  if (sc >= 50n) return 4n;
  if (sc >= 25n) return 3n;
  if (sc >= 10n) return 2n;
  return 1n;
}

/**
 * The penalty BAND of §3.15.7 — the aggregate a public listing carries, where the raw counter
 * belongs to the advanced reveal. A listing is read by everyone, and a raw counter is a
 * fingerprint; a band informs without identifying.
 *
 * The cuts are events, not round numbers: a stalemate or an abandoned dispute is +5, an arbitration
 * loss is +15. So 0 is clean, 1 is one bad clock, 2 is several or one proven loss, 3 is more.
 *
 * It is what makes the tier readable. The tier nets penalty into the score, so a punished T2 falls
 * to T1 and looks exactly like an honest newcomer — the one distinction a counterparty needs most.
 */
export function penaltyBand(penalty: bigint): number {
  if (penalty >= 16n) return 3;
  if (penalty >= 6n) return 2;
  if (penalty >= 1n) return 1;
  return 0;
}
