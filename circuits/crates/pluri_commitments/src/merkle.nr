// Merkle membership against a PoseidonTree root (§3.15.3): the witness format every
// circuit that proves membership consumes — one sibling and one index bit per level,
// hashing pairs with PoseidonT3 exactly as `src/packages/PoseidonTree.sol` does
// (index bit 0: node on the left; bit 1: node on the right).
use crate::commitments::poseidon_t3;
use crate::vectors;

/// Root of the empty tree with `D` levels — zero leaves folded with PoseidonT3, the same
/// seeding PoseidonTree performs at deploy.
pub fn empty_root<let D: u32>() -> Field {
    let mut z: Field = 0;
    for _ in 0..D {
        z = poseidon_t3(z, z);
    }
    z
}

/// Root implied by a membership witness: the leaf's position path and its siblings.
pub fn compute_root<let D: u32>(leaf: Field, siblings: [Field; D], indices: [u8; D]) -> Field {
    let mut node = leaf;
    for level in 0..D {
        let bit = indices[level];
        assert(bit < 2, "index bit must be 0 or 1");
        if bit == 0 {
            node = poseidon_t3(node, siblings[level]);
        } else {
            node = poseidon_t3(siblings[level], node);
        }
    }
    node
}

/// Convenience for circuits: membership against an expected root (the public input).
pub fn is_member<let D: u32>(leaf: Field, siblings: [Field; D], indices: [u8; D], root: Field) -> bool {
    compute_root::<D>(leaf, siblings, indices) == root
}

// ---------------------------------------------------------------- parity tests (vectors.nr)

#[test]
fn empty_root_matches() {
    // 8 is the literal the vectors were generated with (turbofish wants a literal in this
    // nargo); the assertion pins the generated TREE_DEPTH to it.
    assert(vectors::TREE_DEPTH == 8, "vectors depth != 8");
    assert(empty_root::<8>() == vectors::TREE_EMPTY_ROOT);
}

#[test]
fn memberships_match() {
    assert(vectors::TREE_DEPTH == 8, "vectors depth != 8");
    assert(
        compute_root::<8>(
            vectors::TREE_LEAVES[0],
            vectors::TREE_SIBLINGS_0,
            vectors::TREE_INDICES_0,
        ) == vectors::TREE_MEMBERSHIP_ROOT_0,
        "membership 0",
    );
    assert(
        compute_root::<8>(
            vectors::TREE_LEAVES[1],
            vectors::TREE_SIBLINGS_1,
            vectors::TREE_INDICES_1,
        ) == vectors::TREE_MEMBERSHIP_ROOT_1,
        "membership 1",
    );
    assert(
        compute_root::<8>(
            vectors::TREE_LEAVES[2],
            vectors::TREE_SIBLINGS_2,
            vectors::TREE_INDICES_2,
        ) == vectors::TREE_MEMBERSHIP_ROOT_2,
        "membership 2",
    );
}
