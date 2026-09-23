// The account circuit of the register bundle (PLURISWAP.md §3.15.9, V1 as-built): the
// account-leaf side of "one human, one account". It proves the binding the humanity circuit
// cannot express on its own: that the leaf being inserted belongs to the same secret behind
// the burned `hn`.
//
// The link is `hn`: proving it requires knowing `hsk`, so the account being registered belongs to
// the enrolled human. The leaf's salt is DERIVED from `sk_id` instead (§3.15.3) — it used to be
// `hsk`, which tied recovery of the account to a second secret for no gain, since the `hn` assert
// already carries the binding. No membership is re-proven here: the bundle order is
// enforced on-chain (passport.register first — the hn is only trusted once the passport has
// burned it against its own membership proof), and the identical public `hn` across both
// proofs cannot be satisfied twice with different registry domains without breaking Poseidon.
// The adapter still amplifies `registry_id` with its own read of the served registry, so a
// proof naming a foreign domain fails closed before the Honk verifier is ever reached.
//
// Initial leaf (§3.15.9): all counters zero (count, volume, penalty, inFlight), token zero
// (nothing has happened in any token yet), version zero, salt derived from sk_id.
use pluri_commitments::commitments::{account_commitment, hn, leaf_rep, leaf_salt};
use pluri_commitments::merkle;
use pluri_commitments::vectors as v;

fn main(
    h_n: pub Field,
    leaf0: pub Field,
    registry_id: pub Field,
    hsk: Field,
    sk_id: Field,
) {
    // The same nullifier the humanity circuit derived — the bundle's binding.
    assert(hn(hsk, registry_id) == h_n, "hn mismatch");
    // The account: S = Poseidon(sk_id), never on-chain in the clear.
    let s = account_commitment(sk_id);
    // The initial leaf, salted by DERIVATION from the account secret (§3.15.3). It used to be
    // salted with `hsk`, which tied recovery of the account to a SECOND secret: you needed both
    // the registry secret and the account secret to rebuild version zero. The human-to-account
    // binding does not depend on it — the `hn` assert above already requires knowing `hsk` — so
    // deriving from `sk_id` loses nothing and makes `sk_id` alone enough to recover.
    // The genesis leaf: every counter zero, no token yet, the derived salt — and an EMPTY
    // counterparty tree (§3.14.7): a new account has met nobody, so its first deal with anyone at
    // all is creditable. The rate window starts at zero too.
    assert(
        leaf_rep(s, 0, 0, 0, 0, 0, leaf_salt(sk_id, 0), 0, merkle::empty_root::<32>(), 0, 0) == leaf0,
        "leaf0 mismatch",
    );
}

// ---------------------------------------------------------------- parity tests (vectors.nr)

#[test]
fn hn_matches_vectors() {
    assert(hn(v::REGISTRY_HSK, v::REGISTRY_ID) == v::REGISTRY_SAMPLE_HN, "sample hn");
}

#[test]
fn leaf0_matches_vectors() {
    let s = account_commitment(v::REGISTRY_SAMPLE_SK_ID);
    assert(s == v::REGISTRY_SAMPLE_S, "sample S");
    assert(
        leaf_rep(s, 0, 0, 0, 0, 0, leaf_salt(v::REGISTRY_SAMPLE_SK_ID, 0), 0, merkle::empty_root::<32>(), 0, 0) == v::REGISTRY_SAMPLE_LEAF0,
        "sample leaf0",
    );
}
