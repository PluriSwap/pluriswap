// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {PoseidonTree} from "../src/packages/PoseidonTree.sol";
import {PoseidonSingletons} from "./PoseidonSingletons.sol";

/// @title What a private deal spends, by the piece
/// @dev EVALUACION.md's LHF-5 asked what privacy costs, and the answer used to be a single number
///      nobody could act on. Measuring the verifies clean (2026-09-23) showed they are only 4.36M of
///      a ~15M two-sided activation, so the rest is the tree and the kernel — and the tree is where
///      the levers are. This suite measures them, so the next decision is arithmetic and not taste.
///
///      Everything here is measured against the pinned Poseidon singletons (§5.1): a tree that hashes
///      through a locally compiled library would report a different, and wrong, number.
contract PrivateGasTest is Test {
    uint256 internal constant ROOT_HISTORY = 4096;

    function setUp() public {
        PoseidonSingletons.install();
    }

    function _insert(PoseidonTree tree, uint256 seed) internal returns (uint256 gas) {
        uint256 before = gasleft();
        tree.insert(keccak256(abi.encode(seed)));
        gas = before - gasleft();
    }

    /// LEVER 1: the depth of the accounts tree. 32 levels address 4.3 billion accounts, and every
    /// level is `depth` Poseidon hashes on the hot path of every insert — four of them per private
    /// deal. This measures the marginal cost of a level, so the depth stops being a number nobody
    /// priced: how many accounts the protocol wants to address is a decision, but it should be made
    /// knowing what each power of two costs per deal.
    function test_lever_treeDepth() public {
        uint8[5] memory depths = [20, 24, 26, 28, 32];
        uint256[5] memory firsts;
        uint256[5] memory steadies;
        for (uint256 i = 0; i < depths.length; i++) {
            PoseidonTree tree = new PoseidonTree(depths[i], ROOT_HISTORY, address(this));
            firsts[i] = _insert(tree, 1);
            // The first insert of a tree writes every `filledSubtrees` slot cold; the steady state is
            // what a deal on a live tree actually pays, so measure a few in and take that.
            for (uint256 k = 2; k < 6; k++) {
                _insert(tree, k);
            }
            steadies[i] = _insert(tree, 6);
            emit log_named_uint("depth", depths[i]);
            emit log_named_uint("  first insert gas", firsts[i]);
            emit log_named_uint("  steady insert gas", steadies[i]);
        }
        // The marginal level, from the two ends of the range.
        emit log_named_uint("gas per level (steady, 20->32)", (steadies[4] - steadies[0]) / 12);
        emit log_named_uint("saved per insert by 32->26", steadies[4] - steadies[2]);
        assertGt(steadies[4], steadies[0], "a deeper tree costs more per insert");
    }

    /// LEVER 2: inserts inside one transaction. A two-sided private activation inserts four leaves —
    /// two account leaves and two note changes — and each `insert` walks its whole path alone. Leaves
    /// that land at adjacent indices share every level above the first, so a batched insert could hash
    /// the shared part once. This measures what the repetition actually costs today: the gap between
    /// the first insert of a transaction and the ones after it is the ceiling on what batching buys.
    function test_lever_repeatedInserts() public {
        PoseidonTree tree = new PoseidonTree(32, ROOT_HISTORY, address(this));
        uint256 first = _insert(tree, 1);
        uint256 second = _insert(tree, 2);
        uint256 third = _insert(tree, 3);
        uint256 fourth = _insert(tree, 4);
        emit log_named_uint("insert #1 (cold tree)", first);
        emit log_named_uint("insert #2", second);
        emit log_named_uint("insert #3", third);
        emit log_named_uint("insert #4", fourth);
        emit log_named_uint("four inserts, total", first + second + third + fourth);
        // What the same four would cost if the shared upper path were hashed once: four leaves under
        // one depth-2 subtree is 4 + 2 + 1 = 7 hashes for the bottom two levels plus one walk of the
        // remaining 30, against four full walks of 32.
        emit log_named_uint("hashes now (4 x depth 32)", 128);
        emit log_named_uint("hashes if batched", 7 + 30);
        assertLt(second, first, "the cold tree pays for its own first insert");
    }

    /// The same question for the notes tree, which is depth 20 and takes two inserts in a bonded deal
    /// (the split's change note, and later the reabsorbed lock's note).
    function test_lever_notesTree() public {
        PoseidonTree tree = new PoseidonTree(20, ROOT_HISTORY, address(this));
        uint256 first = _insert(tree, 1);
        uint256 second = _insert(tree, 2);
        emit log_named_uint("notes depth 20, first insert", first);
        emit log_named_uint("notes depth 20, second insert", second);
        assertGt(first, second);
    }

    /// The nullifier burn, for completeness: every prepare and every claim spends one, and it is the
    /// one piece of the private path that is a plain storage write.
    function test_lever_nullifier() public {
        PoseidonTree tree = new PoseidonTree(32, ROOT_HISTORY, address(this));
        uint256 before = gasleft();
        tree.spend(keccak256("a nullifier"));
        emit log_named_uint("spend (one nullifier)", before - gasleft());
    }
}
