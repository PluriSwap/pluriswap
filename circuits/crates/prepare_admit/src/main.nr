// The admission side of the activation bundle (PLURISWAP.md §3.15.4, V2 as-built). The
// proof says, in one: "I know the account behind `dealSubject` (the same one the passport
// prepare identified); its current leaf sits in a live tree; the deal's
// `inFlight + principal` fits the cap my score buys (the §3.14.7 tier computed IN-CIRCUIT
// from the leaf's own stats — never read from chain); `newLeaf` is that leaf with the
// principal taken into flight, the version bumped and the salt rotated; and `nullRep(v)`
// is the old version's nullifier". `lockCommit` selects the bond column of the cap table
// when non-zero (§3.15.4) — in V2 no vault exists, so the adapter rejects any non-zero
// `lockCommit` and only the base column is reachable on-chain.
//
// Two leaf branches, both proven against membership:
//   * same-token: the witness leaf's token IS the deal's token — the account's per-token
//     stats guard the cap (§3.14.7's stats are per subject AND token);
//   * genesis: the witness leaf is the registered leaf0 (token zero, all-zero stats) —
//     the first deal of any token grows out of the account's genesis leaf. All-zero is
//     forced, so a veteran token-leaf can never masquerade as genesis.
use pluri_commitments::commitments::{account_commitment, deal_subject, leaf_rep, null_rep};
use pluri_commitments::merkle::is_member;
use pluri_commitments::tiers;
use pluri_commitments::vectors as v;

fn main(
    subject: pub Field,
    new_leaf: pub Field,
    nullifier: pub Field,
    token: pub Field,
    principal: pub Field,
    lock_commit: pub Field,
    rep_root: pub Field,
    decimals: pub Field,
    // The account and the deal pseudonym's secret half.
    sk_id: Field,
    deal_id: Field,
    // The current leaf's private fields (§3.15.3 leafRep order).
    count: Field,
    volume: Field,
    penalty: Field,
    in_flight: Field,
    leaf_token: Field,
    salt: Field,
    version: Field,
    // The new leaf's fresh salt (rotation).
    new_salt: Field,
    // Depth-32 account-tree membership witness for the CURRENT leaf.
    siblings: [Field; 32],
    indices: [u8; 32],
) {
    // A zero token is not a deal token; the adapter cross-checks it against the served
    // ERC-20's decimals, which a zero address cannot answer.
    assert(token != 0, "zero token");
    // The same account the passport prepare identified: the kernel cross-checks both
    // prepares' subjects against each other in `admit` (§3.15.4 "Consumo").
    assert(deal_subject(sk_id, deal_id) == subject, "deal subject mismatch");
    let s = account_commitment(sk_id);

    // The current leaf, in one of its two admissible shapes. The conjunction is
    // parenthesized: `&` binds tighter than `==` in Noir, so bare `a == b & c == d`
    // would parse as a bitwise-and over Fields.
    let same_token = leaf_token == token;
    let genesis = (leaf_token == 0) & (count == 0) & (volume == 0) & (penalty == 0) & (in_flight == 0);
    assert(same_token | genesis, "leaf is neither this token's nor the genesis leaf");
    let leaf = leaf_rep(s, count, volume, penalty, in_flight, leaf_token, salt, version);
    assert(is_member::<32>(leaf, siblings, indices, rep_root), "not a live account leaf");

    // §3.14.7 in-circuit: the score comes from the leaf's own stats, the cap from the
    // tier table, and the deal must fit — T5 as the giant sentinel, so ONE unconditional
    // comparison serves every tier. The bound compares as integers (this nargo forbids
    // relational ops on Field): raw amounts under 2^64 (1.8e19 units — 18 full tokens'
    // worth at 18 decimals), the sentinel under 2^128, all cast-checked so a truncated
    // witness cannot pass.
    //
    // The shape is deliberate: a negated-guard statement-if around this block makes bb's
    // optimized EVM verifier reject its own valid proofs (bisected: the unconditional
    // shape verifies on-chain, the guarded one does not — see circuits/README.md).
    let sc = tiers::score(count, volume, penalty, decimals);
    let using_bond = lock_commit != 0;
    let cap_raw = tiers::cap_raw(sc, using_bond, decimals);
    let inf: u64 = in_flight as u64;
    assert(inf as Field == in_flight, "in_flight too big");
    let prin: u64 = principal as u64;
    assert(prin as Field == principal, "principal too big");
    let cap_v: u128 = cap_raw as u128;
    assert(cap_v as Field == cap_raw, "cap too big");
    assert((inf as u128) + (prin as u128) <= cap_v, "inFlight + principal over the tier cap");

    // The transition (§3.15.4): principal into flight, version bumped, salt rotated; the
    // new leaf's token is the deal's token — both branches move to it.
    assert(
        leaf_rep(s, count, volume, penalty, in_flight + principal, token, new_salt, version + 1)
            == new_leaf,
        "new leaf mismatch",
    );

    // The old version's nullifier (§3.15.3): one use per account version, burned by
    // `PrivateReputation.prepare` — serializing concurrent prepares by version.
    assert(null_rep(sk_id, version) == nullifier, "version nullifier mismatch");
}

// ---------------------------------------------------------------- parity tests (vectors.nr)

#[test]
fn prepare_admit_sample_verifies() {
    // The pinned sample (vectors.json `prepare`): the genesis-branch transition of the
    // registry sample account — 100 units of the 6-dec token into flight from leaf0,
    // under the T1 base cap of 250 units.
    assert(v::PREPARE_DEPTH == 32, "account tree depth");
    assert(v::PREPARE_DECIMALS == 6, "sample decimals");
    main(
        v::PREPARE_DEAL_SUBJECT,
        v::PREPARE_NEW_LEAF,
        v::PREPARE_NULL_REP,
        v::PREPARE_TOKEN,
        v::PREPARE_PRINCIPAL,
        0, // lockCommit: V2 has no vault, so the base cap column
        v::PREPARE_ROOT,
        v::PREPARE_DECIMALS,
        v::PREPARE_SK_ID,
        v::PREPARE_DEAL_ID,
        0,
        0,
        0,
        0,
        0, // leaf0: token zero, all-zero stats — the genesis branch
        v::PREPARE_SALT,
        0,
        v::PREPARE_NEW_SALT,
        v::PREPARE_SIBLINGS,
        v::PREPARE_INDICES,
    );
}

#[test]
fn new_leaf_is_the_transition() {
    // The transition's own arithmetic, pinned straight against the vectors: the sample
    // newLeaf is leaf0 with the principal into flight, the token moved to the deal's,
    // the salt rotated and the version bumped.
    let s = account_commitment(v::PREPARE_SK_ID);
    let new_leaf = leaf_rep(
        s,
        0,
        0,
        0,
        v::PREPARE_PRINCIPAL,
        v::PREPARE_TOKEN,
        v::PREPARE_NEW_SALT,
        1,
    );
    assert(new_leaf == v::PREPARE_NEW_LEAF, "transition leaf");
    let nullifier = null_rep(v::PREPARE_SK_ID, 0);
    assert(nullifier == v::PREPARE_NULL_REP, "version-0 nullifier");
}
