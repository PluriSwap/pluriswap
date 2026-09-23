// The canonical commitments of §3.15.3 (as amended by the canonical-encoding decision):
// one builder per commitment the circuits prove about. Identical to the JS twin
// (circuits/js/lib/commitments.ts) and the Solidity twin
// (src/packages/libraries/PrivacyCommitments.sol); parity pinned by vectors.nr (test/fixtures/vectors.json).
//
// Chaining rule (the §3.15.3 amendment): a multi-field commitment chains PoseidonT3 in a
// pinned left fold over the field order of the spec — h0 = f0, hi = PoseidonT3(h(i-1), fi).
// Nullifier tags are pinned field constants inside this library's namespace.
use crate::poseidon2::permutation as t2_perm;
use crate::poseidon3::permutation as t3_perm;
use crate::vectors;

pub global TAG_REP: Field = 1;
pub global TAG_BOND: Field = 2;
pub global TAG_HANDLE: Field = 3;
pub global TAG_LEAF: Field = 4;

/// PoseidonT2 (one input, capacity 0): `S = Poseidon(sk_id)` — the account.
pub fn poseidon_t2(x: Field) -> Field {
    t2_perm([0, x])[0]
}

/// PoseidonT3 (two inputs, capacity 0): tree nodes, `hn`, `dealSubject`, the chain primitive.
pub fn poseidon_t3(a: Field, b: Field) -> Field {
    t3_perm([0, a, b])[0]
}

/// The pinned left fold of the multi-field commitments.
pub fn chain<let N: u32>(fields: [Field; N]) -> Field {
    let mut h = fields[0];
    for i in 1..N {
        h = poseidon_t3(h, fields[i]);
    }
    h
}

/// `S = Poseidon(sk_id)` — the account; lives inside leafRep, never on-chain in the clear.
pub fn account_commitment(sk_id: Field) -> Field {
    poseidon_t2(sk_id)
}

/// `hn = Poseidon(anchor, registryId)` — the humanity nullifier; anchor = Passport-live address.
pub fn hn(anchor: Field, registry_id: Field) -> Field {
    poseidon_t3(anchor, registry_id)
}

/// `dealSubject = Poseidon(sk_id, dealId)` — the per-deal pseudonym; all the kernel ever sees.
pub fn deal_subject(sk_id: Field, deal_id: Field) -> Field {
    poseidon_t3(sk_id, deal_id)
}

/// `nullRep = Poseidon(sk_id, "rep", version)` — one use per account version.
pub fn null_rep(sk_id: Field, version: Field) -> Field {
    chain([sk_id, TAG_REP, version])
}

/// `leafSalt = Poseidon(sk_id, "leaf", version)` — the account leaf's salt, DERIVED.
///
/// It used to be whatever the prover picked, which made an account unrecoverable from its secret:
/// rebuilding your leaf means reproducing its salt, and without a derivation the salt only lived in
/// the client's local state. Deriving it costs nothing in privacy — the leaf already hides behind
/// `S = Poseidon(sk_id)`, and whoever can recompute this salt already holds `sk_id` — and it buys
/// the property that `sk_id` alone is enough to recover an account.
///
/// The circuits ENFORCE it rather than trusting the prover to follow a convention: a user of a
/// non-conforming client would not discover the problem until the day they needed to recover, and
/// that is the one day it cannot be fixed.
pub fn leaf_salt(sk_id: Field, version: Field) -> Field {
    chain([sk_id, TAG_LEAF, version])
}

/// `nullBond = Poseidon(sk_id, "bond", noteSalt)` — one use per spent note.
pub fn null_bond(sk_id: Field, note_salt: Field) -> Field {
    chain([sk_id, TAG_BOND, note_salt])
}

/// `handleCommit = Poseidon(sk_id, "handle", handleSalt)` — the rotable market pseudonym.
pub fn handle_commit(sk_id: Field, handle_salt: Field) -> Field {
    chain([sk_id, TAG_HANDLE, handle_salt])
}

/// `noteBond = Poseidon(sk_id, token, amount, salt)` — token-specific vault note (F3).
pub fn note_bond(sk_id: Field, token: Field, amount: Field, salt: Field) -> Field {
    chain([sk_id, token, amount, salt])
}

/// `lockCommit = Poseidon(sk_id, dealId, lockAmount, salt)` — the earmark a reserve proves
/// openable. The fold's first step is exactly `dealSubject`: the lock binds to the deal.
pub fn lock_commit(sk_id: Field, deal_id: Field, lock_amount: Field, salt: Field) -> Field {
    chain([sk_id, deal_id, lock_amount, salt])
}

/// `leafRep = Poseidon(S, count, volume, penalty, inFlight, token, salt, version)` — the account leaf.
pub fn leaf_rep(
    s: Field,
    count: Field,
    volume: Field,
    penalty: Field,
    in_flight: Field,
    token: Field,
    salt: Field,
    version: Field,
) -> Field {
    chain([s, count, volume, penalty, in_flight, token, salt, version])
}

// ---------------------------------------------------------------- parity tests (vectors.nr)

#[test]
fn zero_gate_matches_circom_vector() {
    assert(poseidon_t3(1, 2) == vectors::ZERO_EXPECTED, "poseidon(1,2) != circomlib vector");
}

#[test]
fn high_edge_matches() {
    assert(poseidon_t3(vectors::P2_BIG_A, vectors::P2_BIG_B) == vectors::P2_BIG_EXPECTED);
}

#[test]
fn builders_match_vectors() {
    let s = account_commitment(vectors::SK_ID);
    assert(s == vectors::EXPECTED_S, "S");
    assert(hn(vectors::ANCHOR, vectors::REGISTRY_ID) == vectors::EXPECTED_HN, "hn");
    assert(deal_subject(vectors::SK_ID, vectors::DEAL_ID) == vectors::EXPECTED_DEAL_SUBJECT, "dealSubject");
    assert(null_rep(vectors::SK_ID, vectors::VERSION) == vectors::EXPECTED_NULL_REP, "nullRep");
    assert(null_bond(vectors::SK_ID, vectors::NOTE_SALT) == vectors::EXPECTED_NULL_BOND, "nullBond");
    assert(handle_commit(vectors::SK_ID, vectors::HANDLE_SALT) == vectors::EXPECTED_HANDLE_COMMIT, "handleCommit");
    assert(note_bond(vectors::SK_ID, vectors::TOKEN_ID, vectors::AMOUNT, vectors::NOTE_SALT) == vectors::EXPECTED_NOTE_BOND, "noteBond");
    assert(lock_commit(vectors::SK_ID, vectors::DEAL_ID, vectors::LOCK_AMOUNT, vectors::LOCK_SALT) == vectors::EXPECTED_LOCK_COMMIT, "lockCommit");
    assert(
        leaf_rep(s, vectors::COUNT, vectors::VOLUME, vectors::PENALTY, vectors::IN_FLIGHT, vectors::TOKEN_ID, vectors::LEAF_SALT, vectors::VERSION)
            == vectors::EXPECTED_LEAF_REP,
        "leafRep",
    );
}

#[test]
fn tags_are_distinct() {
    assert((TAG_REP != TAG_BOND) & (TAG_BOND != TAG_HANDLE) & (TAG_REP != TAG_HANDLE));
    assert((TAG_LEAF != TAG_REP) & (TAG_LEAF != TAG_BOND) & (TAG_LEAF != TAG_HANDLE));
}
