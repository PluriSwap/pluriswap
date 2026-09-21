// The account circuit of the register bundle (PLURISWAP.md §3.15.9, V1 as-built): the
// account-leaf side of "one human, one account". It proves the binding the humanity circuit
// cannot express on its own: that the leaf being inserted belongs to the same secret behind
// the burned `hn`.
//
// The link is the shared secret: the initial leaf's salt IS the `hsk` (the per-human registry
// secret), so `leaf0 = leafRep(S, 0, 0, 0, 0, 0, hsk, 0)` is bound to `hn = PoseidonT3(hsk,
// registryId)` through hsk alone. No membership is re-proven here: the bundle order is
// enforced on-chain (passport.register first — the hn is only trusted once the passport has
// burned it against its own membership proof), and the identical public `hn` across both
// proofs cannot be satisfied twice with different registry domains without breaking Poseidon.
// The adapter still amplifies `registry_id` with its own read of the served registry, so a
// proof naming a foreign domain fails closed before the Honk verifier is ever reached.
//
// Initial leaf (§3.15.9): all counters zero (count, volume, penalty, inFlight), token zero
// (nothing has happened in any token yet), version zero, salt = hsk.
use pluri_commitments::commitments::{account_commitment, hn, leaf_rep};
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
    // The initial leaf, salted with the humanity secret.
    assert(leaf_rep(s, 0, 0, 0, 0, 0, hsk, 0) == leaf0, "leaf0 mismatch");
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
    assert(leaf_rep(s, 0, 0, 0, 0, 0, v::REGISTRY_HSK, 0) == v::REGISTRY_SAMPLE_LEAF0, "sample leaf0");
}
