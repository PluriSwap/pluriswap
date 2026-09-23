// The lock's way home (PLURISWAP.md §3.15.6, V3 as-built). The proof says, in one: "I
// know the account behind `dealSubject = Poseidon(sk_id, dealId)`; the stored
// `lockCommit` opens to exactly `(sk_id, dealId, amount, salt)` — the record the contract
// read, not a lock of my choosing —; and `newNote = Poseidon(sk_id, token, amount,
// newSalt)` mints exactly the record's amount in the record's token".
//
// No membership and no root: the lock record is contract state, not a leaf, and the
// account's existence was proven when the deal activated. The vault gates the call on
// `reputation.claimed(dealSubject)` — without the terminal delta the lock does not come
// back (§3.15.5: the delta is atomic).
//
// `nullBond = Poseidon(sk_id, "bond", lockSalt)` is one-use-per-lock: the vault burns it
// in the notes tree's nullifier set, so the same released record cannot merge twice.
//
// Both salts are DERIVED (2026-09-23), which collapses this circuit's private witness to the
// SECRET ALONE: the lock's salt comes from the deal it belongs to (one lock per deal per subject),
// the merged note's from the nullifier this proof publishes. Everything else reabsorb needs is on
// the public record the vault stored. It is the clearest statement of what deriving the salts buys
// — a proof whose entire witness is `sk_id` plus what anyone can read.
use pluri_commitments::commitments::{
    deal_subject, lock_commit as lock_commit_of, lock_salt, note_bond, note_salt, null_bond,
};
use pluri_commitments::vectors as v;

fn main(
    deal_id: pub Field,
    subject: pub Field,
    token: pub Field,
    amount: pub Field,
    lock_commit: pub Field,
    new_note: pub Field,
    nullifier: pub Field,
    // The owner's secret — the whole witness.
    sk_id: Field,
) {
    assert(token != 0, "zero token");
    // A released lock is never zero: `reserve` rejects a zero principal, so §3.14.5's
    // lock of it is at least 1. (The vault's record carries exactly that amount.)
    let amt: u128 = amount as u128;
    assert(amt as Field == amount, "amount too big");
    assert(amt >= 1, "zero amount");

    // The per-deal binding: the same pseudonym the whole deal ran under.
    assert(deal_subject(sk_id, deal_id) == subject, "deal subject mismatch");
    // The lock's salt, re-derived from the deal — the same value `prepare_bond` committed to when
    // it carved the earmark out. The stored commit then opens to exactly the record's (deal, amount):
    // the proof binds the lock the vault read, not a lock of the prover's choosing.
    let lock_s = lock_salt(sk_id, deal_id);
    assert(lock_commit_of(sk_id, deal_id, amount, lock_s) == lock_commit, "lock commit mismatch");
    // One use per lock (§3.15.3's bond tag over the lock's own salt).
    assert(null_bond(sk_id, lock_s) == nullifier, "lock nullifier mismatch");
    // The merge (§3.15.6): exactly the record's amount, in the record's token, into a fresh note —
    // the value the split carved out, coming back whole, under the salt the nullifier above seeds.
    assert(note_bond(sk_id, token, amount, note_salt(sk_id, nullifier)) == new_note, "new note mismatch");
}

// ---------------------------------------------------------------- parity tests (vectors.nr)

#[test]
fn reabsorb_sample_verifies() {
    // The pinned sample (vectors.json `reabsorb`): the prepare deal's released lock —
    // 10_000_000 of the 6-dec token, the exact §3.14.5 lock the split carved — merges
    // back into a fresh note.
    main(
        v::REABSORB_DEAL_ID,
        v::REABSORB_DEAL_SUBJECT,
        v::REABSORB_TOKEN,
        v::REABSORB_AMOUNT,
        v::REABSORB_LOCK_COMMIT,
        v::REABSORB_NEW_NOTE,
        v::REABSORB_NULL_BOND,
        v::REABSORB_SK_ID,
    );
}

#[test]
fn the_whole_witness_is_the_secret() {
    // What deriving the salts bought here: `main` above takes `sk_id` and nothing else private.
    // The lock's salt comes from the deal, the note's from the nullifier — so a released lock is
    // reabsorbable by whoever holds the secret, reading only what the vault already stored.
    let lock_s = lock_salt(v::REABSORB_SK_ID, v::REABSORB_DEAL_ID);
    assert(lock_s == v::REABSORB_LOCK_SALT, "the lock salt is the deal's");
    let nullifier = null_bond(v::REABSORB_SK_ID, lock_s);
    assert(nullifier == v::REABSORB_NULL_BOND, "the nullifier follows");
    assert(note_salt(v::REABSORB_SK_ID, nullifier) == v::REABSORB_NEW_SALT, "and seeds the merged note");
}

#[test]
fn the_lock_opens_and_merges() {
    // The sample's own arithmetic, pinned straight: the lock commit is the bond split's
    // earmark (same constant the `bond` section generated), and the merged note is a
    // note of exactly the record's amount.
    let lc = lock_commit_of(v::REABSORB_SK_ID, v::REABSORB_DEAL_ID, v::REABSORB_AMOUNT, v::REABSORB_LOCK_SALT);
    assert(lc == v::REABSORB_LOCK_COMMIT, "lock opens");
    assert(lc == v::BOND_LOCK_COMMIT, "the split's earmark");
    let note = note_bond(v::REABSORB_SK_ID, v::REABSORB_TOKEN, v::REABSORB_AMOUNT, v::REABSORB_NEW_SALT);
    assert(note == v::REABSORB_NEW_NOTE, "merge is exact");
    assert(v::REABSORB_AMOUNT == v::BOND_LOCK_AMOUNT, "the record's amount is the lock's");
}
