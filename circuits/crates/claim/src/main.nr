// The terminal delta (PLURISWAP.md §3.15.5, V3 as-built). The proof says, in one: "I know
// the account behind `dealSubject = Poseidon(sk_id, dealId)`; its CURRENT leaf sits in a
// live tree under `repRoot`; `newLeaf` is that leaf with the pending record's terminal
// delta applied — count/volume/penalty/inFlight moved together or not at all, the version
// bumped, the salt re-derived — and `nullRep(v)` is the CURRENT version's nullifier".
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
use pluri_commitments::commitments::{
    CP_DEPTH, account_commitment, cp_path, deal_subject, leaf_rep, leaf_salt, null_rep,
    pair_tag as pair_tag_of,
};
use pluri_commitments::merkle::{compute_root, is_member};
use pluri_commitments::vectors as v;

/// How many credited deals fit in one rate window (§3.14.7). Sixteen new counterparties in an epoch
/// is far past any honest retail trader and only bites automated bursts.
global CREDITS_PER_EPOCH: u64 = 16;

fn main(
    deal_id: pub Field,
    subject: pub Field,
    new_leaf: pub Field,
    nullifier: pub Field,
    kind: pub Field,
    token: pub Field,
    principal: pub Field,
    rep_root: pub Field,
    // The §3.14.7 anti-farming inputs, both read from what the chain already holds: the pair tag the
    // two sides agreed on when they activated (stored per deal by the module), and the epoch the
    // adapter derives from `block.timestamp`. The circuit has no clock of its own, exactly like
    // `attest_base` has none — a public input is how a clock gets in.
    pair_tag: pub Field,
    epoch: pub Field,
    // The account's secret and the current leaf's private fields (§3.15.3 leafRep order).
    sk_id: Field,
    count: Field,
    volume: Field,
    penalty: Field,
    in_flight: Field,
    leaf_token: Field,
    version: Field,
    // The anti-farming state of the leaf: who has already been credited to this account, and how
    // much of the current rate window is spent.
    cp_root: Field,
    leaf_epoch: Field,
    leaf_credits: Field,
    // The counterparty of THIS deal, and the slot it occupies in the tree above. `slot` is what the
    // tree currently holds there: zero when free, the counterparty's own `S` when it was already
    // credited, somebody else's on a (astronomically unlikely) collision — which reads as taken, the
    // safe direction.
    s_other: Field,
    slot: Field,
    cp_siblings: [Field; CP_DEPTH],
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
    let leaf = leaf_rep(
        s,
        count,
        volume,
        penalty,
        in_flight,
        leaf_token,
        leaf_salt(sk_id, version),
        version,
        cp_root,
        leaf_epoch,
        leaf_credits,
    );
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

    // ---------------------------------------------------------------- who is on the other side
    // The pair, as both sides named it at activation: this proof binds MY commitment and the
    // counterparty's as a witness, and the tag only comes out right if each used the other's real
    // `S` (the multiset {S_a, X} = {S_b, Y} has no other solution when S_a != S_b). So the claim
    // cannot invent a fresh counterparty to be credited by — which is the whole farm, priced.
    assert(pair_tag_of(s, s_other, deal_id) == pair_tag, "pair tag mismatch");

    // The slot that counterparty occupies in MY counterparty tree, at a path derived from its own
    // commitment: a claim cannot aim this proof at whatever empty corner it likes.
    let cp_indices = cp_path(s_other);
    assert(is_member::<CP_DEPTH>(slot, cp_siblings, cp_indices, cp_root), "counterparty slot mismatch");
    // Free slot = nobody has been credited from this account yet. Anything else reads as taken:
    // their own `S` because they already credited me, or (at 2^-32 per pair) a stranger's on a
    // collision — which denies a credit rather than granting one, the direction to fail in.
    let is_fresh = (slot == 0) as Field;

    // ---------------------------------------------------------------- the rate window
    // The window resets when the epoch moves; within one, at most CREDITS_PER_EPOCH credits. It
    // cannot stop a patient farmer and is not meant to: it turns a weekend into a year, during
    // which the account is exposed to every penalty everyone else is.
    let same_epoch = (epoch == leaf_epoch) as Field;
    let credits_so_far = same_epoch * leaf_credits;
    let c_so_far: u64 = credits_so_far as u64;
    assert(c_so_far as Field == credits_so_far, "credit counter too big");
    let has_room = (c_so_far < CREDITS_PER_EPOCH) as Field;

    // §3.15.5's table as arithmetic: kind's selectors pick the completed-deal reward and
    // the penalties; every kind releases the principal from flight.
    //
    // The 2026-09-23 amendment is the `credits` factor on the REWARD and nothing else: a completed
    // deal counts when the counterparty is new to this account and the window has room. What went
    // wrong is never deduplicated — a stalemate with somebody you have already traded with costs
    // exactly what a stalemate costs. Good things are earned per person; bad things are just true.
    let is_peaceful = (k == 0) as Field;
    let is_stalemate = (k == 2) as Field;
    let is_arbloss = (k == 4) as Field;
    let credits = is_peaceful * is_fresh * has_room;
    let new_count = count + credits;
    let new_volume = volume + credits * principal;
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

    // The counterparty tree moves exactly when the credit does: the slot is taken by the account
    // that just earned it. Taking it on every terminal instead would let a stranger burn your credit
    // slot with a cheap Silent deal; taking it only here keeps the invariant readable — the tree
    // holds the accounts that have credited you, and nobody else.
    let taken_root = compute_root::<CP_DEPTH>(s_other, cp_siblings, cp_indices);
    let new_cp_root = credits * taken_root + (1 - credits) * cp_root;
    // The window: rolled to this epoch, spent by this credit.
    let new_credits = credits_so_far + credits;

    // The delta leaf (§3.15.5): stats moved together, version bumped, salt re-derived.
    assert(
        leaf_rep(
            s,
            new_count,
            new_volume,
            new_penalty,
            new_in_flight,
            token,
            leaf_salt(sk_id, version + 1),
            version + 1,
            new_cp_root,
            epoch,
            new_credits,
        ) == new_leaf,
        "delta leaf mismatch",
    );
}

// ---------------------------------------------------------------- parity tests (vectors.nr)

/// The witness a claim of the pinned sample carries, in one place: the sample is a FRESH counterparty
/// against an empty tree and a cold window, so it credits.
fn sample_main(kind: Field, new_leaf: Field, slot: Field, epoch: Field, leaf_epoch: Field, leaf_credits: Field) {
    main(
        v::CLAIM_DEAL_ID,
        v::CLAIM_DEAL_SUBJECT,
        new_leaf,
        v::CLAIM_NULL_REP,
        kind,
        v::CLAIM_TOKEN,
        v::CLAIM_PRINCIPAL,
        v::CLAIM_ROOT,
        v::CLAIM_PAIR_TAG,
        epoch,
        v::CLAIM_SK_ID,
        v::CLAIM_COUNT,
        v::CLAIM_VOLUME,
        v::CLAIM_PENALTY,
        v::CLAIM_IN_FLIGHT,
        v::CLAIM_LEAF_TOKEN,
        v::CLAIM_VERSION,
        v::CLAIM_CP_ROOT,
        leaf_epoch,
        leaf_credits,
        v::CLAIM_CP_S,
        slot,
        v::CLAIM_CP_SIBLINGS,
        v::CLAIM_SIBLINGS,
        v::CLAIM_INDICES,
    );
}

/// The delta leaf of the sample for a given kind, with the counterparty state it should end in.
fn sample_leaf(count: Field, volume: Field, penalty: Field, cp_root: Field, epoch: Field, credits: Field) -> Field {
    leaf_rep(
        account_commitment(v::CLAIM_SK_ID),
        count,
        volume,
        penalty,
        v::CLAIM_IN_FLIGHT - v::CLAIM_PRINCIPAL,
        v::CLAIM_TOKEN,
        leaf_salt(v::CLAIM_SK_ID, v::CLAIM_VERSION + 1),
        v::CLAIM_VERSION + 1,
        cp_root,
        epoch,
        credits,
    )
}

#[test]
fn claim_sample_verifies() {
    // The pinned sample (vectors.json `claim`): the prepare deal ends Peaceful — the current leaf is
    // the prepare's new leaf (version 1, the 100_000_000 principal in flight), and the delta completes
    // the deal: count 1, volume +principal, the flight released, the counterparty written into the
    // tree and one credit spent in the window.
    assert(v::CLAIM_DEPTH == 32, "account tree depth");
    sample_main(v::CLAIM_KIND, v::CLAIM_NEW_LEAF, 0, v::CLAIM_EPOCH, v::CLAIM_EPOCH_IN, v::CLAIM_EPOCH_CREDITS);
}

#[test]
fn the_pair_is_named_by_both_or_by_neither() {
    // The soundness of the whole anti-farming rule, stated as arithmetic: the tag is commutative over
    // the two account commitments, so the value this claim proves is the same one the COUNTERPARTY's
    // own proof produced at activation. Neither side can move it alone.
    let s = account_commitment(v::CLAIM_SK_ID);
    assert(pair_tag_of(s, v::CLAIM_CP_S, v::CLAIM_DEAL_ID) == v::CLAIM_PAIR_TAG, "the tag is the pair's");
    assert(
        pair_tag_of(v::CLAIM_CP_S, s, v::CLAIM_DEAL_ID) == v::CLAIM_PAIR_TAG,
        "and it does not care who computes it",
    );
}

#[test(should_fail_with = "pair tag mismatch")]
fn a_counterparty_of_your_own_invention_has_no_proof() {
    // The farm, refused at its root. A claim that wants a SECOND credit from the same partner cannot
    // simply name somebody else: the tag was fixed when the deal activated, by both sides at once.
    main(
        v::CLAIM_DEAL_ID,
        v::CLAIM_DEAL_SUBJECT,
        v::CLAIM_NEW_LEAF,
        v::CLAIM_NULL_REP,
        v::CLAIM_KIND,
        v::CLAIM_TOKEN,
        v::CLAIM_PRINCIPAL,
        v::CLAIM_ROOT,
        v::CLAIM_PAIR_TAG,
        v::CLAIM_EPOCH,
        v::CLAIM_SK_ID,
        v::CLAIM_COUNT,
        v::CLAIM_VOLUME,
        v::CLAIM_PENALTY,
        v::CLAIM_IN_FLIGHT,
        v::CLAIM_LEAF_TOKEN,
        v::CLAIM_VERSION,
        v::CLAIM_CP_ROOT,
        v::CLAIM_EPOCH_IN,
        v::CLAIM_EPOCH_CREDITS,
        v::CLAIM_CP_S + 1, // somebody who was never on the other side of this deal
        0,
        v::CLAIM_CP_SIBLINGS,
        v::CLAIM_SIBLINGS,
        v::CLAIM_INDICES,
    );
}

#[test]
fn the_second_deal_with_the_same_account_earns_nothing() {
    // The rule itself, end to end against its own pinned leaf (vectors `claim_repeat`): the account
    // has already been credited by this counterparty, so its slot holds their `S`. A Peaceful
    // terminal releases the flight and moves NOTHING else — no count, no volume, the tree untouched.
    // Five more of these are still one credit, which is exactly what a closed cluster is worth.
    main(
        v::CLAIM_DEAL_ID,
        v::CLAIM_DEAL_SUBJECT,
        v::CLAIM_REPEAT_NEW_LEAF,
        v::CLAIM_REPEAT_NULL_REP,
        0, // Peaceful
        v::CLAIM_TOKEN,
        v::CLAIM_PRINCIPAL,
        v::CLAIM_REPEAT_ROOT,
        v::CLAIM_PAIR_TAG,
        v::CLAIM_REPEAT_EPOCH,
        v::CLAIM_SK_ID,
        1, // the count the first claim left
        v::CLAIM_PRINCIPAL,
        0,
        v::CLAIM_PRINCIPAL,
        v::CLAIM_TOKEN,
        v::CLAIM_REPEAT_VERSION,
        v::CLAIM_REPEAT_CP_ROOT,
        v::CLAIM_REPEAT_EPOCH,
        v::CLAIM_REPEAT_CREDITS,
        v::CLAIM_CP_S,
        v::CLAIM_REPEAT_SLOT,
        v::CLAIM_REPEAT_CP_SIBLINGS,
        v::CLAIM_REPEAT_SIBLINGS,
        v::CLAIM_REPEAT_INDICES,
    );
}

#[test]
fn a_full_window_earns_nothing_either() {
    // The rate limit, same shape (vectors `claim_full`): a counterparty this account has never been
    // credited by, but sixteen credits already spent in this epoch. The credit is refused and not
    // deferred — and the slot stays FREE, so the pair can still credit once in a later window. A
    // limit that let the credit come back tomorrow would only be a delay.
    main(
        v::CLAIM_DEAL_ID,
        v::CLAIM_DEAL_SUBJECT,
        v::CLAIM_FULL_NEW_LEAF,
        v::CLAIM_FULL_NULL_REP,
        0, // Peaceful
        v::CLAIM_TOKEN,
        v::CLAIM_PRINCIPAL,
        v::CLAIM_FULL_ROOT,
        v::CLAIM_PAIR_TAG,
        v::CLAIM_FULL_EPOCH,
        v::CLAIM_SK_ID,
        1,
        v::CLAIM_PRINCIPAL,
        0,
        v::CLAIM_PRINCIPAL,
        v::CLAIM_TOKEN,
        v::CLAIM_FULL_VERSION,
        v::CLAIM_FULL_CP_ROOT,
        v::CLAIM_FULL_EPOCH,
        v::CLAIM_FULL_CREDITS,
        v::CLAIM_CP_S,
        v::CLAIM_FULL_SLOT,
        v::CLAIM_FULL_CP_SIBLINGS,
        v::CLAIM_FULL_SIBLINGS,
        v::CLAIM_FULL_INDICES,
    );
}

#[test]
fn a_penalty_is_never_deduplicated() {
    // The asymmetry that makes the rule safe to have. The same counterparty as above — slot taken, no
    // credit possible — but the deal ends in a stalemate, and that costs exactly what a stalemate
    // costs. Good things are earned once per person; bad things are simply true.
    let punished = leaf_rep(
        account_commitment(v::CLAIM_SK_ID),
        1,
        v::CLAIM_PRINCIPAL,
        5, // the penalty landed
        0,
        v::CLAIM_TOKEN,
        leaf_salt(v::CLAIM_SK_ID, v::CLAIM_REPEAT_VERSION + 1),
        v::CLAIM_REPEAT_VERSION + 1,
        v::CLAIM_REPEAT_CP_ROOT,
        v::CLAIM_REPEAT_EPOCH,
        v::CLAIM_REPEAT_CREDITS,
    );
    main(
        v::CLAIM_DEAL_ID,
        v::CLAIM_DEAL_SUBJECT,
        punished,
        v::CLAIM_REPEAT_NULL_REP,
        2, // Stalemate
        v::CLAIM_TOKEN,
        v::CLAIM_PRINCIPAL,
        v::CLAIM_REPEAT_ROOT,
        v::CLAIM_PAIR_TAG,
        v::CLAIM_REPEAT_EPOCH,
        v::CLAIM_SK_ID,
        1,
        v::CLAIM_PRINCIPAL,
        0,
        v::CLAIM_PRINCIPAL,
        v::CLAIM_TOKEN,
        v::CLAIM_REPEAT_VERSION,
        v::CLAIM_REPEAT_CP_ROOT,
        v::CLAIM_REPEAT_EPOCH,
        v::CLAIM_REPEAT_CREDITS,
        v::CLAIM_CP_S,
        v::CLAIM_REPEAT_SLOT,
        v::CLAIM_REPEAT_CP_SIBLINGS,
        v::CLAIM_REPEAT_SIBLINGS,
        v::CLAIM_REPEAT_INDICES,
    );
}

#[test]
fn every_close_kind_matches_the_table() {
    // §3.15.5's table, all five rows, against a FRESH counterparty — the case the table was always
    // describing. Silent and ArbWin release only the flight; Stalemate/ArbLoss punish; Peaceful
    // completes, and only Peaceful takes the counterparty's slot and a credit from the window.
    assert(v::DELTA_COUNT == 5, "five close kinds");
    for i in 0..5 {
        let kind = v::DELTA_KINDS[i];
        let credits = (kind == 0) as Field;
        let expected = sample_leaf(
            v::DELTA_NEW_COUNTS[i],
            v::DELTA_NEW_VOLUMES[i],
            v::DELTA_NEW_PENALTIES[i],
            credits * v::CLAIM_CP_ROOT_AFTER + (1 - credits) * v::CLAIM_CP_ROOT,
            v::CLAIM_EPOCH,
            credits,
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
        sample_main(kind, expected, 0, v::CLAIM_EPOCH, v::CLAIM_EPOCH_IN, v::CLAIM_EPOCH_CREDITS);
    }
}
