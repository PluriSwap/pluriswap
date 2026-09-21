// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {PoseidonT3} from "poseidon-solidity/PoseidonT3.sol";
import {PoseidonTree} from "../src/packages/PoseidonTree.sol";

/// @title PoseidonTree tests (F1, PLURISWAP.md §3.15.11)
/// @dev Behavior first: insert, root ring buffer, nullifiers, ownership, field hygiene.
contract PoseidonTreeTest is Test {
    uint8 internal constant DEPTH = 8;

    /// @dev circomlib PoseidonT3([1, 2]) — pins the BN254 params so circuits and contracts
    ///      agree. Source: iden3/circomlibjs `test/poseidon.js`, `poseidonperm_x5_254_3`.
    uint256 internal constant CIRCOM_T3_1_2 =
        7853200120776062878684798364095072458815029376092732009249414926327459813530;

    bytes32 internal constant LEAF_A = bytes32(uint256(0xA));
    bytes32 internal constant LEAF_B = bytes32(uint256(0xB));
    bytes32 internal constant NULLIFIER = keccak256("nullifier-a");

    PoseidonTree internal tree;

    function setUp() public {
        tree = new PoseidonTree(DEPTH);
    }

    // ---------------------------------------------------------------- primitives

    function test_poseidon_matchesCircomVector() public pure {
        assertEq(PoseidonT3.hash([uint256(1), uint256(2)]), CIRCOM_T3_1_2);
    }

    // ---------------------------------------------------------------- constructor

    function test_constructor_rejectsBadDepth() public {
        vm.expectRevert(PoseidonTree.BadDepth.selector);
        new PoseidonTree(0);
        // 33 = PoseidonTree.MAX_DEPTH + 1 (qualified contract-constant reads from
        // another file trip solc 9582 here; the contract re-checks the bound itself).
        vm.expectRevert(PoseidonTree.BadDepth.selector);
        new PoseidonTree(33);
    }

    function test_initialRoot_isKnownAndNonZero() public view {
        bytes32 r0 = tree.root();
        assertTrue(r0 != bytes32(0), "empty root is zero");
        assertTrue(tree.isKnownRoot(r0), "empty root not known");
        assertEq(tree.nextIndex(), 0);
    }

    // ---------------------------------------------------------------- insert

    function test_insert_firstLeaf() public {
        bytes32 before = tree.root();
        (uint256 index, bytes32 newRoot) = tree.insert(LEAF_A);
        assertEq(index, 0);
        assertTrue(newRoot != before, "root did not move");
        assertEq(tree.root(), newRoot);
        assertTrue(tree.isKnownRoot(newRoot));
        assertEq(tree.nextIndex(), 1);
    }

    function test_insert_movesRootForward() public {
        (, bytes32 root1) = tree.insert(LEAF_A);
        (, bytes32 root2) = tree.insert(LEAF_B);
        assertTrue(root2 != root1, "root did not move");
        assertTrue(tree.isKnownRoot(root1), "older root evicted too early");
        assertTrue(tree.isKnownRoot(root2));
        assertEq(tree.nextIndex(), 2);
    }

    function test_insert_isDeterministic() public {
        PoseidonTree other = new PoseidonTree(DEPTH);
        (, bytes32 root1) = tree.insert(LEAF_A);
        (, bytes32 root1b) = other.insert(LEAF_A);
        assertEq(root1, root1b);
        (, bytes32 root2) = tree.insert(LEAF_B);
        (, bytes32 root2b) = other.insert(LEAF_B);
        assertEq(root2, root2b);
    }

    function test_insert_rejectsZeroLeaf() public {
        vm.expectRevert(PoseidonTree.ZeroLeaf.selector);
        tree.insert(bytes32(0));
        assertEq(tree.nextIndex(), 0);
    }

    function test_insert_onlyOwner() public {
        vm.prank(address(0xB0B));
        vm.expectRevert(PoseidonTree.NotOwner.selector);
        tree.insert(LEAF_A);
    }

    function test_insert_treeFull() public {
        PoseidonTree tiny = new PoseidonTree(1);
        tiny.insert(LEAF_A);
        tiny.insert(LEAF_B);
        vm.expectRevert(PoseidonTree.TreeFull.selector);
        tiny.insert(bytes32(uint256(0xC)));
        assertEq(tiny.nextIndex(), 2);
    }

    // ---------------------------------------------------------------- root ring buffer

    function test_ringBuffer_evictsOldRoots() public {
        bytes32 initial = tree.root();
        (, bytes32 root1) = tree.insert(LEAF_A);
        (, bytes32 root2) = tree.insert(LEAF_B);
        for (uint256 i = 2; i < 65; i++) {
            tree.insert(bytes32(uint256(0x1000 + i)));
        }
        assertFalse(tree.isKnownRoot(initial), "initial root should be evicted");
        assertFalse(tree.isKnownRoot(root1), "root1 should be evicted");
        assertTrue(tree.isKnownRoot(root2), "root2 should still be known");
        assertTrue(tree.isKnownRoot(tree.root()));
    }

    // ---------------------------------------------------------------- nullifiers

    function test_spend_burnsNullifierOnce() public {
        tree.spend(NULLIFIER);
        assertTrue(tree.isSpent(NULLIFIER));
        vm.expectRevert(PoseidonTree.NullifierUsed.selector);
        tree.spend(NULLIFIER);
    }

    function test_spend_defaultUnspent() public view {
        assertFalse(tree.isSpent(NULLIFIER));
    }

    function test_spend_onlyOwner() public {
        vm.prank(address(0xB0B));
        vm.expectRevert(PoseidonTree.NotOwner.selector);
        tree.spend(NULLIFIER);
    }

    // ---------------------------------------------------------------- max depth

    function test_maxDepth_tree() public {
        // 32 = PoseidonTree.MAX_DEPTH (see note in test_constructor_rejectsBadDepth).
        PoseidonTree deep = new PoseidonTree(32);
        bytes32 before = deep.root();
        (uint256 index, bytes32 newRoot) = deep.insert(LEAF_A);
        assertEq(index, 0);
        assertTrue(newRoot != before, "root did not move");
        assertTrue(deep.isKnownRoot(newRoot));
        assertEq(deep.nextIndex(), 1);
    }
}
