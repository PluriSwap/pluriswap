// The admission tiers of PLURISWAP.md §3.14.7 — the Noir twin of the table the on-chain
// reputation reads (`Reputation.score` / `Reputation._capTokens`) and the JS twin of the
// generator (`circuits/js/lib/tiers.ts`) computes. The circuit proves the tier IN-CIRCUIT
// (§3.15.4): the cap of `inFlight + principal <= cap` comes from these functions over the
// leaf's own stats, never from a trusted on-chain read.
//
//   score = satSub(count + volume / UNIT, penalty),   UNIT = 250 * 10^decimals
//
// Integer semantics everywhere: the volume's division into lots TRUNCATES (Field `/` is
// multiplicative, so the division happens in u128 after range asserts), the penalty's
// subtraction SATURATES at zero.

use crate::vectors;

/// 10^`d`, computed as a bounded loop over a public input: the scale is derived, never
/// trusted. The bound (32) keeps the honest computation a fixed 32 steps; anything past
/// it has no proof at all.
///
/// This nargo forbids relational operators on Field (equality only), so every range
/// check goes through the cast-round-trip idiom: cast down to an integer, cast back up,
/// assert equality — a truncated cast cannot survive the round trip.
pub fn pow10(d: Field) -> Field {
    let d32: u32 = d as u32;
    assert(d32 as Field == d, "decimals not an integer");
    assert(d32 < 32, "decimals out of range");
    let mut acc: Field = 1;
    for i in 0..32 {
        let level: u32 = i as u32;
        acc = if level < d32 { acc * 10 } else { acc };
    }
    acc
}

/// The §3.14.7 score of an account leaf: `satSub(count + volume/UNIT, penalty)` with
/// `UNIT = 250 * 10^decimals` — one lot is a full-cap T1 deal, so five clean T1 deals
/// buy T2, and no single trade can skip tiers.
///
/// Bounds: count and penalty are success/penalty counters (2^64 is generous beyond
/// argument); volume is raw token units under 2^128 (1.7e38 raw — 1.7e20 full tokens at
/// 18 decimals). Every bound only rejects: a witness too big to vouch for has no proof,
/// which is the fail-closed direction.
pub fn score(count: Field, volume: Field, penalty: Field, decimals: Field) -> Field {
    let c64: u64 = count as u64;
    assert(c64 as Field == count, "count too big");
    let p64: u64 = penalty as u64;
    assert(p64 as Field == penalty, "penalty too big");
    let vol: u128 = volume as u128;
    assert(vol as Field == volume, "volume too big");
    let unit = 250 * pow10(decimals);
    let unit_u: u128 = unit as u128;
    // lots <= vol/250 < 2^121, count < 2^64: the u128 sum cannot overflow.
    let lots: u128 = vol / unit_u;
    let base: u128 = (c64 as u128) + lots;
    let p: u128 = p64 as u128;
    let sc: u128 = if p > base { 0 } else { base - p };
    sc as Field
}

/// T5's "sin límite" as a raw bound: 2^128-1. Any provable `inFlight + principal` (both
/// are cast-checked below 2^64) fits under it, so ONE unconditional comparison serves
/// every tier — no `unbounded` branch in the circuit at all. The on-chain twin encodes
/// the same idea with `type(uint256).max` (`Reputation._capTokens`).
///
/// The shape is deliberate: a negated-guard statement-if around the bound check makes
/// bb's optimized EVM verifier codegen reject its own valid proofs (bisected: the same
/// circuit with an unconditional check verifies on-chain, the guarded one does not — see
/// circuits/README.md). The unconditional shape is the one this protocol uses.
pub global T5_SENTINEL: Field = 340282366920938463463374607431768211455; // 2^128 - 1

/// The cap a score buys, in raw token units of the tier's column: T5 the sentinel, the
/// other tiers their units scaled by the token's decimals.
pub fn cap_raw(sc: Field, with_bond: bool, decimals: Field) -> Field {
    let s: u128 = sc as u128;
    assert(s as Field == sc, "score too big");
    let units = cap_units(s, with_bond);
    if units == 0 {
        T5_SENTINEL
    } else {
        units * pow10(decimals)
    }
}

/// 0 means T5 (unbounded — the sentinel takes over in `cap_raw`); otherwise the tier's
/// cap in whole tokens of the column.
fn cap_units(sc: u128, with_bond: bool) -> Field {
    if sc >= 100 {
        0
    } else if sc >= 50 {
        if with_bond { 5000 } else { 2000 }
    } else if sc >= 25 {
        if with_bond { 1500 } else { 1000 }
    } else if sc >= 10 {
        if with_bond { 700 } else { 500 }
    } else {
        if with_bond { 400 } else { 250 }
    }
}

/// The tier ordinal a score buys (1..5) — the disclosure layer's (F4) reading of the same
/// ladder: `attest_base`'s claimed tier is a LOWER bound of this. `cap_units` encodes T5
/// as 0; here the ordinal is explicit — the attestation's public semantics is the tier,
/// not the cap. Same thresholds, same `u128` ordered comparison (no relational ops on
/// Field in this nargo).
pub fn tier_of(sc: Field) -> u8 {
    let s: u128 = sc as u128;
    assert(s as Field == sc, "score too big");
    if s >= 100 {
        5
    } else if s >= 50 {
        4
    } else if s >= 25 {
        3
    } else if s >= 10 {
        2
    } else {
        1
    }
}

// ---------------------------------------------------------------- parity tests (vectors.nr)

#[test]
fn pow10_matches() {
    assert(pow10(0) == 1, "10^0");
    assert(pow10(1) == 10, "10^1");
    assert(pow10(6) == 1000000, "10^6");
    assert(pow10(18) == 1000000000000000000, "10^18");
}

#[test]
fn tier_ordinals_match_the_ladder() {
    // §3.14.7's ladder as ordinals: the five thresholds, boundary-anchored on both sides.
    assert(tier_of(0) == 1, "T1 floor");
    assert(tier_of(9) == 1, "just under T2");
    assert(tier_of(10) == 2, "T2 boundary");
    assert(tier_of(24) == 2, "just under T3");
    assert(tier_of(25) == 3, "T3 boundary");
    assert(tier_of(49) == 3, "just under T4");
    assert(tier_of(50) == 4, "T4 boundary");
    assert(tier_of(99) == 4, "just under T5");
    assert(tier_of(100) == 5, "T5 boundary");
}

#[test]
fn tiers_match_vectors() {
    for i in 0..vectors::TIER_COUNT {
        let sc = score(
            vectors::TIER_COUNTS[i],
            vectors::TIER_VOLUMES[i],
            vectors::TIER_PENALTIES[i],
            vectors::TIER_DECIMALS[i],
        );
        assert(sc == vectors::TIER_SCORES[i], "score mismatch");
        // The vectors carry T5 as (cap 0, unbounded true); the circuit encodes it as the
        // sentinel. The mapping is asserted, not assumed.
        let base_expected = if vectors::TIER_UNBOUNDED[i] { T5_SENTINEL } else { vectors::TIER_CAPS_BASE[i] };
        let bond_expected = if vectors::TIER_UNBOUNDED[i] { T5_SENTINEL } else { vectors::TIER_CAPS_BOND[i] };
        assert(cap_raw(sc, false, vectors::TIER_DECIMALS[i]) == base_expected, "base cap mismatch");
        assert(cap_raw(sc, true, vectors::TIER_DECIMALS[i]) == bond_expected, "bond cap mismatch");
    }
}
