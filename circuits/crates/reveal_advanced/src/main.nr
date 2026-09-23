// The profile reveal of the disclosure layer (PLURISWAP.md §3.15.7, F4 as-built).
// attest_base shows the listing its bounds; this shows the requester its CHOSEN FIELDS
// exactly: `out = mask * field` — bit0 volume, bit1 penalty — so "campos elegidos" is
// arithmetic, not control flow (the whole-consumption mask pattern of withdraw). A
// hidden field's output is zero; a shown field's output is the leaf's own value.
//
// `requester` is the §3.15.7 optional bind: the pubkey hash of the one requester this
// profile was minted for — zero when the reveal is public under the handle. It rides
// the public-input binding (the same wire withdraw's `dest` uses): a proof minted for
// requester A cannot be repurposed as B's, and the tamper test of the verify lib pins
// that empirically.
//
// Off-chain like attest_base: the requester verifies with bb, the handle is the
// capability (no handle, no query), and the freshness anchor is the root's liveness at
// delivery — §3.15.7 gives reveal_advanced no `expiry` by design; the requester's
// receipt is the timestamp.
//
// The bounds below are bounds FOR THE MASK (the leaf_rep hashes any Field, but the
// mask multiplies — the outputs must stay canonical u128s the consumer reads).
use pluri_commitments::commitments::{account_commitment, handle_commit as handle_commit_of, leaf_rep, leaf_salt};
use pluri_commitments::merkle::is_member;
use pluri_commitments::vectors as v;

fn main(
    handle_commit: pub Field,
    fields_mask: pub Field,
    out_volume: pub Field,
    out_penalty: pub Field,
    requester: pub Field,
    token: pub Field,
    rep_root: pub Field,
    // The account's secret and the handle's salt — the same pair attest_base binds.
    sk_id: Field,
    handle_salt: Field,
    // The leaf's private fields (§3.15.3 leafRep order).
    count: Field,
    volume: Field,
    penalty: Field,
    in_flight: Field,
    leaf_token: Field,
    version: Field,
    // Depth-32 account-tree membership witness for the CURRENT leaf.
    siblings: [Field; 32],
    indices: [u8; 32],
) {
    // The mask: bit0 volume, bit1 penalty — anything else names a field this profile
    // does not know how to reveal.
    let m: u8 = fields_mask as u8;
    assert(m as Field == fields_mask, "mask too big");
    assert(m < 4, "unknown fields");
    let mv: Field = (m & 1) as Field;
    let mp: Field = ((m >> 1) & 1) as Field;

    // The pseudonym + the live leaf, exactly as attest_base: same account, same tree,
    // same token binding — the profile is the listing's account, seen closer.
    assert(handle_commit_of(sk_id, handle_salt) == handle_commit, "handle mismatch");
    assert(token != 0, "zero token");
    assert(leaf_token == token, "leaf token mismatch");
    let s = account_commitment(sk_id);
    let leaf = leaf_rep(s, count, volume, penalty, in_flight, leaf_token, leaf_salt(sk_id, version), version);
    assert(is_member::<32>(leaf, siblings, indices, rep_root), "not a live account leaf");

    // Bounds for the masked arithmetic.
    let vol: u128 = volume as u128;
    assert(vol as Field == volume, "volume too big");
    let pen: u128 = penalty as u128;
    assert(pen as Field == penalty, "penalty too big");

    // The exact reveal: the selector computes the output — the field when chosen, zero
    // when hidden. No branch: the shape stays inside what the pinned bb pipeline accepts.
    assert(out_volume == mv * volume, "volume mask mismatch");
    assert(out_penalty == mp * penalty, "penalty mask mismatch");
}

// ---------------------------------------------------------------- parity tests (vectors.nr)

#[test]
fn reveal_sample_verifies() {
    // The pinned sample (vectors.json `reveal`): the profile of the attest account
    // (§3.15.7's advanced stats, §3.15.3's leaf order) — both fields chosen (mask 0b11),
    // minted for the pinned requester, against the same insert-time root as the listing
    // attestation: one account state, two views.
    assert(v::REVEAL_FIELDS_MASK == 3, "both fields chosen");
    main(
        v::REVEAL_HANDLE_COMMIT,
        v::REVEAL_FIELDS_MASK,
        v::REVEAL_OUT_VOLUME,
        v::REVEAL_OUT_PENALTY,
        v::REVEAL_REQUESTER,
        v::REVEAL_TOKEN,
        v::REVEAL_ROOT,
        v::REVEAL_SK_ID,
        v::REVEAL_HANDLE_SALT,
        v::REVEAL_COUNT,
        v::REVEAL_VOLUME,
        v::REVEAL_PENALTY,
        v::REVEAL_IN_FLIGHT,
        v::REVEAL_LEAF_TOKEN,
        v::REVEAL_VERSION,
        v::REVEAL_SIBLINGS,
        v::REVEAL_INDICES,
    );
}

#[test]
fn hidden_fields_mask_to_zero() {
    // The other branches of "campos elegidos": each field hidden alone and both hidden
    // at once (mask 0 — a reveal that reveals nothing is a true, if empty, statement;
    // the requester prices it, §3.15.7's model). The mask's own arithmetic computes the
    // outputs the circuit would pin.
    let vol: u128 = v::REVEAL_VOLUME as u128;
    let pen: u128 = v::REVEAL_PENALTY as u128;
    // mask 0b01: volume shown, penalty hidden.
    main(
        v::REVEAL_HANDLE_COMMIT,
        1,
        vol as Field,
        0,
        v::REVEAL_REQUESTER,
        v::REVEAL_TOKEN,
        v::REVEAL_ROOT,
        v::REVEAL_SK_ID,
        v::REVEAL_HANDLE_SALT,
        v::REVEAL_COUNT,
        v::REVEAL_VOLUME,
        v::REVEAL_PENALTY,
        v::REVEAL_IN_FLIGHT,
        v::REVEAL_LEAF_TOKEN,
        v::REVEAL_VERSION,
        v::REVEAL_SIBLINGS,
        v::REVEAL_INDICES,
    );
    // mask 0b10: penalty shown, volume hidden.
    main(
        v::REVEAL_HANDLE_COMMIT,
        2,
        0,
        pen as Field,
        v::REVEAL_REQUESTER,
        v::REVEAL_TOKEN,
        v::REVEAL_ROOT,
        v::REVEAL_SK_ID,
        v::REVEAL_HANDLE_SALT,
        v::REVEAL_COUNT,
        v::REVEAL_VOLUME,
        v::REVEAL_PENALTY,
        v::REVEAL_IN_FLIGHT,
        v::REVEAL_LEAF_TOKEN,
        v::REVEAL_VERSION,
        v::REVEAL_SIBLINGS,
        v::REVEAL_INDICES,
    );
    // mask 0b00: nothing shown — every output zero.
    main(
        v::REVEAL_HANDLE_COMMIT,
        0,
        0,
        0,
        v::REVEAL_REQUESTER,
        v::REVEAL_TOKEN,
        v::REVEAL_ROOT,
        v::REVEAL_SK_ID,
        v::REVEAL_HANDLE_SALT,
        v::REVEAL_COUNT,
        v::REVEAL_VOLUME,
        v::REVEAL_PENALTY,
        v::REVEAL_IN_FLIGHT,
        v::REVEAL_LEAF_TOKEN,
        v::REVEAL_VERSION,
        v::REVEAL_SIBLINGS,
        v::REVEAL_INDICES,
    );
}

#[test]
fn the_outputs_are_the_exact_fields() {
    // The mask's own arithmetic, pinned straight against the generated constants: the
    // shown outputs commit to exactly the leaf's volume and penalty — the reveal is
    // exact, never a bound (§3.15.7's difference from attest_base).
    let shown_volume: Field = v::REVEAL_OUT_VOLUME;
    let shown_penalty: Field = v::REVEAL_OUT_PENALTY;
    assert(shown_volume == v::REVEAL_VOLUME, "volume revealed exactly");
    assert(shown_penalty == v::REVEAL_PENALTY, "penalty revealed exactly");
}
