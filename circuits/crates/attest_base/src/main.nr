// The listing attestation of the disclosure layer (PLURISWAP.md §3.15.7, F4 as-built).
// The proof says, in one: "I know `sk_id` behind `handleCommit = Poseidon(sk_id, "handle",
// handleSalt)` — the rotable market pseudonym of §3.15.7; the account owns a live leaf
// under `repRoot`, denominated in exactly the public `token`; and the leaf's own stats
// are at least (tier, count) — the claimed LOWER bounds".
//
// Off-chain by design (§3.15.9): the consumer verifies with bb (or bb.js later), checks
// `repRoot` against the account tree's live roots (`isKnownRoot` is a public read), and
// cross-checks `decimals` against the served ERC-20. No adapter, no contract: nothing of
// this circuit ever touches the kernel or the trees as a writer.
//
// The claimed bounds are COTAS — understating passes, overstating cannot:
//   * the tier is computed IN-CIRCUIT from the leaf's own stats (§3.14.7 via
//     `tiers::score`/`tier_of`), so a penalty already paid can never hide behind a tier
//     it dropped — 12 deals with a +5 penalty is score 10, T2, never the T3 the raw
//     count alone would suggest;
//   * `decimals` is a public input for exactly the reason `prepare_admit` made it one:
//     `UNIT = 250 * 10^decimals` — a private decimals would let a 6-dec leaf claim a
//     2-dec scale and inflate its score by 10^4.
//
// `expiry` is a promise, not a clock: the circuit has no notion of now (that is §3.15.7's
// model — the LISTING shows fresh attestations because the consumer's policy prices stale
// ones), so the field is bound into the statement (a public input rides the Honk public
// input binding, exactly like withdraw's `dest`) and the consumer checks it against its
// own clock.
use pluri_commitments::commitments::{account_commitment, handle_commit as handle_commit_of, leaf_rep};
use pluri_commitments::merkle::is_member;
use pluri_commitments::tiers;
use pluri_commitments::vectors as v;

fn main(
    handle_commit: pub Field,
    tier: pub Field,
    count: pub Field,
    expiry: pub Field,
    token: pub Field,
    decimals: pub Field,
    rep_root: pub Field,
    // The account's secret and the handle's salt (§3.15.3: `handleCommit` derives from
    // the same sk_id the leaf does — the pseudonym and the stats are one account).
    sk_id: Field,
    handle_salt: Field,
    // The leaf's private fields (§3.15.3 leafRep order).
    count_actual: Field,
    volume: Field,
    penalty: Field,
    in_flight: Field,
    leaf_token: Field,
    salt: Field,
    version: Field,
    // Depth-32 account-tree membership witness for the CURRENT leaf.
    siblings: [Field; 32],
    indices: [u8; 32],
) {
    // The pseudonym (§3.15.7): the listing's handle, rotatable by salt — this proof is
    // the only bridge between the handle and the account behind it.
    assert(handle_commit_of(sk_id, handle_salt) == handle_commit, "handle mismatch");

    // The account behind it: a live leaf of the account tree, of exactly the attested
    // token — the stats are per subject AND token (§3.14.7), so a USDC-tier proof can
    // never ride on a PEPE leaf.
    assert(token != 0, "zero token");
    assert(leaf_token == token, "leaf token mismatch");
    let s = account_commitment(sk_id);
    let leaf = leaf_rep(s, count_actual, volume, penalty, in_flight, leaf_token, salt, version);
    assert(is_member::<32>(leaf, siblings, indices, rep_root), "not a live account leaf");

    // The tier bound, IN-CIRCUIT: `score` range-checks count/penalty (u64) and volume
    // (u128) itself; the claimed tier must be an ordinal the account's real tier covers.
    let sc = tiers::score(count_actual, volume, penalty, decimals);
    let t_actual: u8 = tiers::tier_of(sc);
    let t_claimed: u8 = tier as u8;
    assert(t_claimed as Field == tier, "tier not an ordinal");
    assert(t_claimed >= 1, "tier zero");
    assert(t_claimed <= 5, "tier too big");
    assert(t_actual >= t_claimed, "claimed tier over the account's");

    // The count bound: the same cotas semantics over the raw completed-deal counter.
    let c_claimed: u128 = count as u128;
    assert(c_claimed as Field == count, "count claim too big");
    let c_actual: u64 = count_actual as u64; // score() already bound it under 2^64
    assert((c_actual as u128) >= c_claimed, "claimed count over the account's");

    // The promise's shape: a u64 the consumer can read against its clock. Nothing else —
    // the freshness model of §3.15.7 is the consumer's, not the circuit's.
    let e: u64 = expiry as u64;
    assert(e as Field == expiry, "expiry too big");
}

// ---------------------------------------------------------------- parity tests (vectors.nr)

#[test]
fn attest_base_sample_verifies() {
    // The pinned sample (vectors.json `attest`): the account mid-history — 12 deals,
    // 3 lots, a +5 penalty absorbed — score 10, exactly T2. The claim is the honest
    // exact one: tier 2, count 12.
    assert(v::ATTEST_DEPTH == 32, "account tree depth");
    assert(tiers::tier_of(v::ATTEST_SCORE) == v::ATTEST_TIER as u8, "score/tier pin");
    main(
        v::ATTEST_HANDLE_COMMIT,
        v::ATTEST_TIER,
        v::ATTEST_COUNT_CLAIMED,
        v::ATTEST_EXPIRY,
        v::ATTEST_TOKEN,
        v::ATTEST_DECIMALS,
        v::ATTEST_ROOT,
        v::ATTEST_SK_ID,
        v::ATTEST_HANDLE_SALT,
        v::ATTEST_COUNT,
        v::ATTEST_VOLUME,
        v::ATTEST_PENALTY,
        v::ATTEST_IN_FLIGHT,
        v::ATTEST_LEAF_TOKEN,
        v::ATTEST_SALT,
        v::ATTEST_VERSION,
        v::ATTEST_SIBLINGS,
        v::ATTEST_INDICES,
    );
}

#[test]
fn understating_verifies() {
    // The cotas semantics: claiming LESS than the account has is a valid — if weaker —
    // true statement. T1 and count 0 over the same T2/12 account: the listing may show
    // a floor, never a ceiling someone did not earn.
    main(
        v::ATTEST_HANDLE_COMMIT,
        1, // tier T1 — under the account's T2
        0, // count 0 — under the account's 12
        v::ATTEST_EXPIRY,
        v::ATTEST_TOKEN,
        v::ATTEST_DECIMALS,
        v::ATTEST_ROOT,
        v::ATTEST_SK_ID,
        v::ATTEST_HANDLE_SALT,
        v::ATTEST_COUNT,
        v::ATTEST_VOLUME,
        v::ATTEST_PENALTY,
        v::ATTEST_IN_FLIGHT,
        v::ATTEST_LEAF_TOKEN,
        v::ATTEST_SALT,
        v::ATTEST_VERSION,
        v::ATTEST_SIBLINGS,
        v::ATTEST_INDICES,
    );
}

#[test]
fn overstating_has_no_witness() {
    // The bound's own arithmetic, pinned straight: the account's real tier is T2
    // (score 10, the penalty-shaped boundary), so a claimed T3 is over it — the
    // comparison `t_actual >= t_claimed` is exactly the equation no witness satisfies.
    // The same holds for count: 13 claims over 12 completed deals are impossible.
    let t_actual: u8 = tiers::tier_of(v::ATTEST_SCORE);
    assert(t_actual == 2, "sample sits at T2");
    let overstated: u8 = (v::ATTEST_TIER + 1) as u8;
    assert(t_actual < overstated, "T3 claim over the T2 account");
    let c_claimed: u128 = (v::ATTEST_COUNT + 1) as u128;
    let c_actual: u128 = v::ATTEST_COUNT as u128;
    assert(c_actual < c_claimed, "count claim over the account's");
}

#[test]
fn the_tier_prices_the_penalty_in() {
    // The atomicity of §3.15.5 read from the disclosure side: the penalty entered the
    // leaf through the delta, and the tier the listing can show is computed AFTER it —
    // never around it. The sample sits exactly at T2's floor: score 10 = 12 deals +
    // 3 lots − 5 penalty; the penalty-free stats read 15 (T2 with headroom), and one more
    // Stalemate (+5) past the floor drops the account to T1 (score 5).
    let as_is = tiers::score(v::ATTEST_COUNT, v::ATTEST_VOLUME, v::ATTEST_PENALTY, v::ATTEST_DECIMALS);
    let penalty_free = tiers::score(v::ATTEST_COUNT, v::ATTEST_VOLUME, 0, v::ATTEST_DECIMALS);
    let one_more_stalemate =
        tiers::score(v::ATTEST_COUNT, v::ATTEST_VOLUME, v::ATTEST_PENALTY + 5, v::ATTEST_DECIMALS);
    assert(as_is == v::ATTEST_SCORE, "score pin");
    assert(as_is == 10, "the sample sits at T2's floor");
    assert(penalty_free == 15, "penalty-free stats read 15");
    assert(tiers::tier_of(as_is) == 2, "T2 with the penalty priced in");
    assert(tiers::tier_of(penalty_free) == 2, "T2 with headroom without it");
    assert(tiers::tier_of(one_more_stalemate) == 1, "one more stalemate past the floor drops to T1");
}
