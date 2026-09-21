// The value gate of the notes world (PLURISWAP.md §3.15.6, V3 as-built). `deposit` is the
// ONE place fresh value enters, so it is the one place a note is pinned to the public
// amount: the proof says "I know `sk_id` and `salt` such that
// `note = Poseidon(sk_id, token, amount, salt)`" — with `token` and `amount` exactly the
// public inputs the vault pulls. Every later note creation (a split's change note, a
// reabsorb's merge, a withdraw's change) is conservation-bounded inside its own circuit;
// without this binding, a 10-token deposit could insert a note committing to a million —
// the minting machine §3.15.6 forbids.
//
// No membership and no nullifier: the note is fresh (the vault inserts it), and a deposit
// is replayable by design — each replay inserts a distinct note for a distinct pull.
use pluri_commitments::commitments::note_bond;
use pluri_commitments::vectors as v;

fn main(
    token: pub Field,
    amount: pub Field,
    note: pub Field,
    // The note's owner's secret and the note's salt — both never revealed.
    sk_id: Field,
    salt: Field,
) {
    // A zero amount deposits nothing (the vault reverts it too — fail-closed on both
    // sides of the interface), and a zero-token note could never pay any deal's lock or
    // be withdrawn (there is no token zero): both are malformed at the source.
    assert(token != 0, "zero token");
    assert(amount != 0, "zero amount");
    // The pinned note (§3.15.2, as amended in F3): token-specific, amount-pinned.
    assert(note_bond(sk_id, token, amount, salt) == note, "note mismatch");
}

// ---------------------------------------------------------------- parity tests (vectors.nr)

#[test]
fn deposit_sample_verifies() {
    // The pinned sample (vectors.json `deposit`): the builders' note — 1_500_000_000 of
    // the 6-dec pinned token, the same note the bond split later spends.
    main(
        v::DEPOSIT_TOKEN,
        v::DEPOSIT_AMOUNT,
        v::DEPOSIT_NOTE,
        v::DEPOSIT_SK_ID,
        v::DEPOSIT_SALT,
    );
}

#[test]
fn note_is_the_builder() {
    // The sample note is noteBond of exactly the public (token, amount) and the witness
    // salt — pinned straight against the generated constant.
    let computed = note_bond(v::DEPOSIT_SK_ID, v::DEPOSIT_TOKEN, v::DEPOSIT_AMOUNT, v::DEPOSIT_SALT);
    assert(computed == v::DEPOSIT_NOTE, "sample note");
    // And it is the same note the generic builders section pins (EXPECTED_NOTE_BOND):
    // the deposit sample IS the builders' note.
    assert(v::DEPOSIT_NOTE == v::EXPECTED_NOTE_BOND, "deposit note == builders note");
}
