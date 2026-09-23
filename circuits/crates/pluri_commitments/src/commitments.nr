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
pub global TAG_NOTE: Field = 5;
pub global TAG_LOCK: Field = 6;
pub global TAG_PAIR: Field = 7;
pub global TAG_CP: Field = 8;

/// Depth of an account's own COUNTERPARTY tree (§3.14.7 anti-farming). 32 levels of sparse slots,
/// addressed by `cp_path`: with a few hundred counterparties the odds of two landing on the same
/// slot are around 10^-4, and a collision only ever DENIES credit — the safe direction.
pub global CP_DEPTH: u32 = 32;

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

/// `pairId = Poseidon("pair", S_a + S_b, S_a · S_b)` — the name two accounts share, computed
/// COMMUTATIVELY without ordering them (this nargo has no relational operators on Field, so sorting
/// two field elements is not available; the symmetric polynomials are, and the unordered pair is
/// uniquely determined by its sum and its product).
///
/// It is what lets the anti-farming rule of §3.14.7 exist at all, and its soundness is a small
/// pleasure: each side proves this with its OWN `S` bound to its own leaf and the other's as a
/// private witness. For the two proofs to land on the same value the multisets must match — and
/// since `S_a != S_b`, the only solution is that each used the other's true `S`. A farmer running
/// both sides cannot mint a fresh pair name per round without breaking Poseidon; the honest pair
/// is forced.
pub fn pair_id(s_a: Field, s_b: Field) -> Field {
    chain([TAG_PAIR, s_a + s_b, s_a * s_b])
}

/// `pairTag = Poseidon(pairId, dealId)` — what the two sides of ONE activation publish so the
/// module can check they named the same counterparty.
///
/// Blinded by the deal on purpose. A bare `pairId` would be identical across every deal between the
/// same two accounts, which publishes the trading graph — precisely what §3.15.8 keeps hidden. Tagged
/// by `dealId` it is fresh every time, so it proves agreement WITHIN a deal and says nothing across
/// deals. The cross-deal memory lives privately instead, inside each account's own counterparty tree.
pub fn pair_tag(s_a: Field, s_b: Field, deal_id: Field) -> Field {
    poseidon_t3(pair_id(s_a, s_b), deal_id)
}

/// The slot a counterparty occupies in an account's counterparty tree: the low `CP_DEPTH` bits of
/// `Poseidon("cp", S_other)`, little-endian, one bit per level.
///
/// Derived rather than chosen, for the same reason every salt in this protocol is: the claim must not
/// be free to point its non-membership proof at whatever empty slot it likes. The truncation is the
/// point — an address space of 2^32 slots for a few hundred entries — and the cast keeps the low bits
/// (pinned by `field_to_u32_truncates`).
pub fn cp_path(s_other: Field) -> [u8; CP_DEPTH] {
    let h = poseidon_t3(TAG_CP, s_other);
    let mut rest: u32 = h as u32;
    let mut bits: [u8; CP_DEPTH] = [0; CP_DEPTH];
    for i in 0..CP_DEPTH {
        bits[i] = (rest & 1) as u8;
        rest = rest >> 1;
    }
    bits
}

/// `noteSalt = Poseidon(sk_id, "note", seed)` — a vault note's salt, DERIVED, for the same reason
/// the account leaf's is (`leaf_salt`) and with more at stake: a note holds TOKENS, and its salt is
/// what spends it (`null_bond` is taken over the salt). A salt that only lives in a client's local
/// state is money that dies with a laptop.
///
/// Two seed families, one rule — a note's salt derives from whatever the note came from:
///   * a DEPOSIT has no parent, so the seed is a small per-account index (the deposit circuit binds
///     it under 2^32). Recovery walks the index space against the public deposit events.
///   * every other note is change: the seed is the NULLIFIER of the note or lock it came out of,
///     which the spending transaction publishes. No counter, no gap, no ambiguity — the recovery
///     walk follows the same edges the chain already shows.
///
/// The two families cannot collide in practice: a nullifier is a Poseidon output, uniform over the
/// field, so landing inside the 2^32 index window has probability ~2^-222.
///
/// Recovery works because every amount is public somewhere: a deposit publishes `(token, amount)`,
/// a withdraw its `amount`, a bond split its `lockAmount`, a reabsorb the record's `amount`. So a
/// child's amount is its parent's minus something the chain states, and the walk bottoms out at
/// deposits, which are public in full. Salts derived + amounts derivable = the vault is
/// reconstructible from `sk_id` and the chain, with nothing kept on the side.
pub fn note_salt(sk_id: Field, seed: Field) -> Field {
    chain([sk_id, TAG_NOTE, seed])
}

/// `lockSalt = Poseidon(sk_id, "lock", dealId)` — the earmark's salt, DERIVED from the deal it
/// belongs to. One lock per deal per subject (the kernel reserves once), so the deal id is the only
/// index it needs — and `reabsorb` gets its whole witness back from public data: the record names
/// the deal, the deal derives the salt.
pub fn lock_salt(sk_id: Field, deal_id: Field) -> Field {
    chain([sk_id, TAG_LOCK, deal_id])
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
    // The anti-farming state of §3.14.7, added 2026-09-23 while nothing was deployed: a leaf field
    // cannot be added later without leaving every existing leaf unprovable, which is the same
    // migration cliff the derived salts had.
    //
    //   cp_root       the root of THIS account's counterparty tree — who has already vouched for it
    //                 by trading with it. Credit is once per counterparty; this is where that memory
    //                 lives, privately, so the rule costs no linkability.
    //   epoch         the rate window the last credit was taken in
    //   epoch_credits how much of that window is already spent
    cp_root: Field,
    epoch: Field,
    epoch_credits: Field,
) -> Field {
    chain([s, count, volume, penalty, in_flight, token, salt, version, cp_root, epoch, epoch_credits])
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
    assert(note_salt(vectors::SK_ID, vectors::NOTE_SALT) == vectors::EXPECTED_NOTE_SALT, "noteSalt");
    assert(lock_salt(vectors::SK_ID, vectors::DEAL_ID) == vectors::EXPECTED_LOCK_SALT, "lockSalt");
    assert(pair_id(vectors::PAIR_S_A, vectors::PAIR_S_B) == vectors::EXPECTED_PAIR_ID, "pairId");
    assert(
        pair_tag(vectors::PAIR_S_A, vectors::PAIR_S_B, vectors::DEAL_ID) == vectors::EXPECTED_PAIR_TAG,
        "pairTag",
    );
    assert(handle_commit(vectors::SK_ID, vectors::HANDLE_SALT) == vectors::EXPECTED_HANDLE_COMMIT, "handleCommit");
    assert(note_bond(vectors::SK_ID, vectors::TOKEN_ID, vectors::AMOUNT, vectors::NOTE_SALT) == vectors::EXPECTED_NOTE_BOND, "noteBond");
    assert(lock_commit(vectors::SK_ID, vectors::DEAL_ID, vectors::LOCK_AMOUNT, vectors::LOCK_SALT) == vectors::EXPECTED_LOCK_COMMIT, "lockCommit");
    assert(
        leaf_rep(
            s,
            vectors::COUNT,
            vectors::VOLUME,
            vectors::PENALTY,
            vectors::IN_FLIGHT,
            vectors::TOKEN_ID,
            vectors::LEAF_SALT,
            vectors::VERSION,
            vectors::LEAF_CP_ROOT,
            vectors::LEAF_EPOCH,
            vectors::LEAF_EPOCH_CREDITS,
        ) == vectors::EXPECTED_LEAF_REP,
        "leafRep",
    );
}

#[test]
fn tags_are_distinct() {
    assert((TAG_REP != TAG_BOND) & (TAG_BOND != TAG_HANDLE) & (TAG_REP != TAG_HANDLE));
    assert((TAG_LEAF != TAG_REP) & (TAG_LEAF != TAG_BOND) & (TAG_LEAF != TAG_HANDLE));
    assert((TAG_NOTE != TAG_REP) & (TAG_NOTE != TAG_BOND) & (TAG_NOTE != TAG_HANDLE) & (TAG_NOTE != TAG_LEAF));
    assert(
        (TAG_LOCK != TAG_REP)
            & (TAG_LOCK != TAG_BOND)
            & (TAG_LOCK != TAG_HANDLE)
            & (TAG_LOCK != TAG_LEAF)
            & (TAG_LOCK != TAG_NOTE),
    );
}

#[test]
fn a_salt_is_never_its_own_nullifier() {
    // The domain separation that matters for the derived salts: a note's salt and the nullifier
    // taken OVER that salt are different tags of the same fold, so they cannot collide — which is
    // what lets a child's salt be seeded by its parent's nullifier without the two ever naming the
    // same value.
    let salt = note_salt(vectors::SK_ID, 7);
    assert(salt != null_bond(vectors::SK_ID, 7), "note tag != bond tag");
    assert(note_salt(vectors::SK_ID, salt) != salt, "a salt never seeds itself");
    // And the two seed families of `note_salt` (a small deposit index, a parent nullifier) stay
    // apart because a nullifier is a Poseidon output: nothing forces it, but nothing lands there.
    assert(null_bond(vectors::SK_ID, salt) != 0, "the nullifier is a field element, not an index");
}

#[test]
fn field_to_u32_truncates() {
    // The whole counterparty-path derivation rests on this: casting a big Field down to u32 keeps the
    // LOW 32 bits rather than failing. (The cast-round-trip idiom used everywhere else in this crate
    // only makes sense if that is the behaviour — it asserts the round trip precisely to catch it.)
    let big: Field = 0x1234567800000000 + 0xdeadbeef;
    let low: u32 = big as u32;
    assert(low == 0xdeadbeef, "the low 32 bits survive");
    assert(low as Field != big, "and the high ones are gone");
}

#[test]
fn the_pair_does_not_care_who_asks() {
    // The property the anti-farming rule is built on: `pair_id` is commutative, so the two sides of a
    // deal reach the same name without ever having to agree on an order — which this nargo could not
    // express anyway (no relational operators on Field). The generator pins both orders; here is the
    // function itself saying it.
    assert(
        pair_id(vectors::PAIR_S_A, vectors::PAIR_S_B) == pair_id(vectors::PAIR_S_B, vectors::PAIR_S_A),
        "the pair is unordered",
    );
    assert(vectors::EXPECTED_PAIR_ID == vectors::EXPECTED_PAIR_ID_SWAPPED, "and the twin agrees");
}

#[test]
fn a_counterparty_cannot_choose_its_own_slot() {
    // The slot is a function of the counterparty's account commitment, so a claim cannot aim its
    // non-membership proof at a convenient empty corner of the tree. Different accounts, different
    // paths; the same account, the same path, every time.
    let a = cp_path(vectors::PAIR_S_A);
    let b = cp_path(vectors::PAIR_S_B);
    let a_again = cp_path(vectors::PAIR_S_A);
    let mut same_as_itself = true;
    let mut differs_somewhere = false;
    for i in 0..CP_DEPTH {
        assert(a[i] < 2, "a path is bits");
        same_as_itself = same_as_itself & (a[i] == a_again[i]);
        differs_somewhere = differs_somewhere | (a[i] != b[i]);
    }
    assert(same_as_itself, "derived, not chosen");
    assert(differs_somewhere, "two accounts do not share a slot");
}
