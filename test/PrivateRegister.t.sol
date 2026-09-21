// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {HumanityVerifierMock} from "../mocks/HumanityVerifierMock.sol";
import {AccountVerifierMock} from "../mocks/AccountVerifierMock.sol";
import {PrivatePassport} from "../src/packages/PrivatePassport.sol";
import {PrivateReputation} from "../src/packages/PrivateReputation.sol";
import {PoseidonTree} from "../src/packages/PoseidonTree.sol";
import {IAccountVerifier} from "../src/packages/interfaces/IAccountVerifier.sol";
import {IHumanityVerifier} from "../src/packages/interfaces/IHumanityVerifier.sol";
import {IPrivatePassport} from "../src/packages/interfaces/IPrivatePassport.sol";

/// @title Private register tests (F1, PLURISWAP.md §3.15.3 and §3.15.11)
/// @dev One human (one hn) = one account. The bundle order passport -> reputation is enforced
///      on-chain: reputation only trusts an hn the passport has already burned in this tx.
///      Verifier mocks decode the proof as a bool: a passing mock is not privacy.
contract PrivateRegisterTest is Test {
    bytes32 internal constant HN_A = keccak256("human-a");
    bytes32 internal constant HN_B = keccak256("human-b");
    bytes32 internal constant LEAF_A = bytes32(uint256(0xA));
    bytes32 internal constant LEAF_B = bytes32(uint256(0xB));

    HumanityVerifierMock internal humanity;
    AccountVerifierMock internal account;
    PrivatePassport internal passport;
    PrivateReputation internal reputation;

    function setUp() public {
        humanity = new HumanityVerifierMock();
        account = new AccountVerifierMock();
        passport = new PrivatePassport(humanity);
        reputation = new PrivateReputation(passport, account);
    }

    function ok(bool pass) internal pure returns (bytes memory) {
        return abi.encode(pass);
    }

    // ---------------------------------------------------------------- PrivatePassport.register

    function test_humanity_burnsHn() public {
        vm.expectEmit(true, true, true, true, address(passport));
        emit PrivatePassport.HumanityRegistered(HN_A);
        passport.register(ok(true), HN_A);
        assertTrue(passport.humanitySpent(HN_A));
    }

    function test_humanity_replayReverts() public {
        passport.register(ok(true), HN_A);
        vm.expectRevert(PrivatePassport.HumanAlreadySpent.selector);
        passport.register(ok(true), HN_A);
        assertTrue(passport.humanitySpent(HN_A));
    }

    function test_humanity_badProofMarksNothing() public {
        vm.expectRevert(PrivatePassport.HumanityNotVerified.selector);
        passport.register(ok(false), HN_A);
        assertFalse(passport.humanitySpent(HN_A));
    }

    function test_humanity_zeroVerifier() public {
        vm.expectRevert(PrivatePassport.ZeroVerifier.selector);
        new PrivatePassport(IHumanityVerifier(address(0)));
    }

    // ---------------------------------------------------------------- PrivateReputation.register

    function test_account_insertsLeaf0() public {
        passport.register(ok(true), HN_A);
        vm.expectEmit(true, true, true, true, address(reputation));
        emit PrivateReputation.AccountRegistered(HN_A, LEAF_A, 0);
        reputation.register(ok(true), HN_A, LEAF_A);
        assertTrue(reputation.registeredHn(HN_A));
        assertEq(reputation.accountTree().nextIndex(), 1);
        assertTrue(reputation.accountTree().isKnownRoot(reputation.accountTree().root()));
    }

    function test_account_requiresHumanityFirst() public {
        vm.expectRevert(PrivateReputation.HumanityNotProven.selector);
        reputation.register(ok(true), HN_A, LEAF_A);
        assertFalse(reputation.registeredHn(HN_A));
        assertEq(reputation.accountTree().nextIndex(), 0);
    }

    function test_account_replayHnReverts() public {
        passport.register(ok(true), HN_A);
        reputation.register(ok(true), HN_A, LEAF_A);
        vm.expectRevert(PrivateReputation.AlreadyRegistered.selector);
        reputation.register(ok(true), HN_A, LEAF_B);
        assertEq(reputation.accountTree().nextIndex(), 1);
    }

    function test_account_badProofIsAtomic() public {
        passport.register(ok(true), HN_A);
        vm.expectRevert(PrivateReputation.AccountNotVerified.selector);
        reputation.register(ok(false), HN_A, LEAF_A);
        assertFalse(reputation.registeredHn(HN_A));
        assertEq(reputation.accountTree().nextIndex(), 0);
    }

    function test_twoHumansTwoLeaves() public {
        passport.register(ok(true), HN_A);
        reputation.register(ok(true), HN_A, LEAF_A);
        bytes32 root1 = reputation.accountTree().root();

        passport.register(ok(true), HN_B);
        reputation.register(ok(true), HN_B, LEAF_B);
        bytes32 root2 = reputation.accountTree().root();

        assertTrue(root2 != root1, "root did not move");
        assertEq(reputation.accountTree().nextIndex(), 2);
        assertTrue(passport.humanitySpent(HN_B));
        assertTrue(reputation.registeredHn(HN_B));
    }

    // ---------------------------------------------------------------- hygiene

    function test_tree_ownedByReputation() public {
        PoseidonTree tree = reputation.accountTree();
        vm.prank(address(0xB0B));
        vm.expectRevert(PoseidonTree.NotOwner.selector);
        tree.insert(LEAF_B);
    }

    function test_zeroConstructorArgs() public {
        vm.expectRevert(PrivateReputation.ZeroPassport.selector);
        new PrivateReputation(IPrivatePassport(address(0)), account);
        vm.expectRevert(PrivateReputation.ZeroVerifier.selector);
        new PrivateReputation(passport, IAccountVerifier(address(0)));
    }
}
