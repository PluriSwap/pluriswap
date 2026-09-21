// The terminal delta (PLURISWAP.md §3.15.5, V3 as-built). The proof says, in one: "I know
// the account behind `dealSubject = Poseidon(sk_id, dealId)`; its CURRENT leaf sits in a
// live tree under `repRoot`; `newLeaf` is that leaf with the pending record's terminal
// delta applied — count/volume/penalty/inFlight moved together or not at all, the version
// bumped, the salt rotated — and `nullRep(v)` is the CURRENT version's nullifier".
//
// The delta values (`kind`, `token`, `principal`) are public inputs the contract reads
// from `pending`: the adapter binds the proof to exactly the record the kernel wrote.
// The delta arithmetic — including "no negative inFlight" — is proven IN-CIRCUIT; the
// contract only trusts the verifier's word.
//
// §3.15.5's table, as ARITHMETIC (kind never branches control flow — the negated-guard
// codegen bug of circuits/README.md is a class, and selectors keep the proof's shape
// inside what bb's optimized EVM verifier accepts):
//     Peaceful   count+1, volume+principal
//     Silent     —
//     Stalemate  penalty+5
//     ArbWin     —
//     ArbLoss    penalty+15
//     every kind inFlight−principal
use pluri_commitments::commitments::{account_commitment, deal_subject, leaf_rep, null_rep};
use pluri_commitments::merkle::is_member;
use pluri_commitments::vectors as v;

fn main(
    deal_id: pub Field,
    subject: pub Field,
    new_leaf: pub Field,
    nullifier: pub Field,
    kind: pub Field,
    token: pub Field,
    principal: pub Field,
    rep_root: pub Field,
    // The account's secret and the current leaf's private fields (§3.15.3 leafRep order).
    sk_id: Field,
    count: Field,
    volume: Field,
    penalty: Field,
    in_flight: Field,
    leaf_token: Field,
    salt: Field,
    version: Field,
    // The delta leaf's fresh salt (rotation).
    new_salt: Field,
    // Depth-32 account-tree membership witness for the CURRENT leaf.
    siblings: [Field; 32],
    indices: [u8; 32],
) {
    assert(token != 0, "zero token");
    // `kind` is a Close enum (0..4) — the adapter passes `pending.kind`; anything else
    // cannot name a delta (checked here too, so a proof with a foreign kind cannot exist).
    let k: u8 = kind as u8;
    assert(k as Field == kind, "kind too big");
    assert(k <= 4, "unknown close kind");

    // The per-deal binding: the same pseudonym the activation bundle prepared.
    assert(deal_subject(sk_id, deal_id) == subject, "deal subject mismatch");
    let s = account_commitment(sk_id);

    // The current leaf: a live member. Its token IS the delta's token — the principal and
    // the inFlight it moves are denominated in it (the prepare put them there together).
    assert(leaf_token == token, "leaf token mismatch");
    let leaf = leaf_rep(s, count, volume, penalty, in_flight, leaf_token, salt, version);
    assert(is_member::<32>(leaf, siblings, indices, rep_root), "not a live account leaf");
    // The current version's nullifier (§3.15.3): the claim burns it — one delta per version.
    assert(null_rep(sk_id, version) == nullifier, "version nullifier mismatch");

    // Bounds (this nargo forbids relational ops on Field): every stat cast-checked, the
    // release exact — §3.15.5's "no negative inFlight" is this comparison, proven here.
    let cnt: u128 = count as u128;
    assert(cnt as Field == count, "count too big");
    let vol: u128 = volume as u128;
    assert(vol as Field == volume, "volume too big");
    let pen: u128 = penalty as u128;
    assert(pen as Field == penalty, "penalty too big");
    let inf: u128 = in_flight as u128;
    assert(inf as Field == in_flight, "inFlight too big");
    let prin: u128 = principal as u128;
    assert(prin as Field == principal, "principal too big");
    assert(inf >= prin, "inFlight under the principal");

    // §3.15.5's table as arithmetic: kind's selectors pick the completed-deal reward and
    // the penalties; every kind releases the principal from flight.
    let is_peaceful = (k == 0) as Field;
    let is_stalemate = (k == 2) as Field;
    let is_arbloss = (k == 4) as Field;
    let new_count = count + is_peaceful;
    let new_volume = volume + is_peaceful * principal;
    let new_penalty = penalty + is_stalemate * 5 + is_arbloss * 15;
    let new_in_flight = in_flight - principal;
    // The moved stats stay canonical (a delta cannot push a stat past the u128 domain the
    // account's later proofs read it in).
    let nc: u128 = new_count as u128;
    assert(nc as Field == new_count, "count overflow");
    let nv: u128 = new_volume as u128;
    assert(nv as Field == new_volume, "volume overflow");
    let np: u128 = new_penalty as u128;
    assert(np as Field == new_penalty, "penalty overflow");

    // The delta leaf (§3.15.5): stats moved together, version bumped, salt rotated.
    assert(
        leaf_rep(s, new_count, new_volume, new_penalty, new_in_flight, token, new_salt, version + 1)
            == new_leaf,
        "delta leaf mismatch",
    );
}

// ---------------------------------------------------------------- parity tests (vectors.nr)

#[test]
fn claim_sample_verifies() {
    // The pinned sample (vectors.json `claim`): the prepare deal ends Peaceful — the
    // current leaf is the prepare's new leaf (version 1, the 100_000_000 principal in
    // flight), and the delta completes the deal: count 1, volume +principal, the flight
    // released. Membership against the root the prepare's own insert produced.
    assert(v::CLAIM_DEPTH == 32, "account tree depth");
    main(
        v::CLAIM_DEAL_ID,
        v::CLAIM_DEAL_SUBJECT,
        v::CLAIM_NEW_LEAF,
        v::CLAIM_NULL_REP,
        v::CLAIM_KIND,
        v::CLAIM_TOKEN,
        v::CLAIM_PRINCIPAL,
        v::CLAIM_ROOT,
        v::CLAIM_SK_ID,
        v::CLAIM_COUNT,
        v::CLAIM_VOLUME,
        v::CLAIM_PENALTY,
        v::CLAIM_IN_FLIGHT,
        v::CLAIM_LEAF_TOKEN,
        v::CLAIM_SALT,
        v::CLAIM_VERSION,
        v::CLAIM_NEW_SALT,
        v::CLAIM_SIBLINGS,
        v::CLAIM_INDICES,
    );
}

#[test]
fn every_close_kind_matches_the_table() {
    // §3.15.5's table, all five rows: the same current leaf (the prepare's), each kind's
    // delta leaf computed straight from the builders and compared to the generated row.
    // Silent, ArbWin release only the flight; Stalemate/ArbLoss punish; Peaceful completes.
    assert(v::DELTA_COUNT == 5, "five close kinds");
    for i in 0..5 {
        let kind = v::DELTA_KINDS[i];
        let s = account_commitment(v::CLAIM_SK_ID);
        let expected = leaf_rep(
            s,
            v::DELTA_NEW_COUNTS[i],
            v::DELTA_NEW_VOLUMES[i],
            v::DELTA_NEW_PENALTIES[i],
            v::DELTA_NEW_IN_FLIGHTS[i],
            v::CLAIM_TOKEN,
            v::CLAIM_NEW_SALT,
            v::CLAIM_VERSION + 1,
        );
        // The proof's own arithmetic: selectors against the row's expected stats.
        let is_peaceful = (kind == 0) as Field;
        let is_stalemate = (kind == 2) as Field;
        let is_arbloss = (kind == 4) as Field;
        let new_count = v::CLAIM_COUNT + is_peaceful;
        let new_volume = v::CLAIM_VOLUME + is_peaceful * v::CLAIM_PRINCIPAL;
        let new_penalty = v::CLAIM_PENALTY + is_stalemate * 5 + is_arbloss * 15;
        let new_in_flight = v::CLAIM_IN_FLIGHT - v::CLAIM_PRINCIPAL;
        assert(new_count == v::DELTA_NEW_COUNTS[i], "row count");
        assert(new_volume == v::DELTA_NEW_VOLUMES[i], "row volume");
        assert(new_penalty == v::DELTA_NEW_PENALTIES[i], "row penalty");
        assert(new_in_flight == v::DELTA_NEW_IN_FLIGHTS[i], "row inFlight");
        // And the full main verifies for every kind's delta leaf over the same membership.
        main(
            v::CLAIM_DEAL_ID,
            v::CLAIM_DEAL_SUBJECT,
            expected,
            v::CLAIM_NULL_REP,
            kind,
            v::CLAIM_TOKEN,
            v::CLAIM_PRINCIPAL,
            v::CLAIM_ROOT,
            v::CLAIM_SK_ID,
            v::CLAIM_COUNT,
            v::CLAIM_VOLUME,
            v::CLAIM_PENALTY,
            v::CLAIM_IN_FLIGHT,
            v::CLAIM_LEAF_TOKEN,
            v::CLAIM_SALT,
            v::CLAIM_VERSION,
            v::CLAIM_NEW_SALT,
            v::CLAIM_SIBLINGS,
            v::CLAIM_INDICES,
        );
    }
}
