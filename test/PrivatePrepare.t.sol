// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {HumanityVerifierMock} from "../mocks/HumanityVerifierMock.sol";
import {AccountVerifierMock} from "../mocks/AccountVerifierMock.sol";
import {PreparePassportVerifierMock} from "../mocks/PreparePassportVerifierMock.sol";
import {PrepareAdmitVerifierMock} from "../mocks/PrepareAdmitVerifierMock.sol";
import {ClaimVerifierMock} from "../mocks/ClaimVerifierMock.sol";
import {PrivatePassport} from "../src/packages/PrivatePassport.sol";
import {PrivateReputation} from "../src/packages/PrivateReputation.sol";
import {PoseidonTree, DEFAULT_ROOT_HISTORY, MIN_ROOT_HISTORY, MAX_ROOT_HISTORY} from "../src/packages/PoseidonTree.sol";
import {IPassport} from "../src/packages/interfaces/IPassport.sol";
import {PoseidonSingletons} from "./PoseidonSingletons.sol";

/// @title Private prepare tests (F2, PLURISWAP.md §3.15.4)
/// @dev The activation bundle's write side: proofs fail closed, the wallet consent pins the
///      subject under the wallet, nullifiers serialize concurrent prepares by version.
///      Verifier mocks decode the proof as a bool: a passing mock is not privacy.
///
///      Test hygiene: every external call that feeds a reverting call (roots, signatures) is
///      hoisted to a local BEFORE `vm.expectRevert` — the expectation is consumed by the next
///      call, whatever it is.
contract PrivatePrepareTest is Test {

    /// @dev The §3.14.7 pair tag. With a mock verifier nothing checks its VALUE — what these tests
    ///      exercise is that both sides of one activation carry the SAME one, which is what the module
    ///      compares. The real value is pinned by the fixture tests and by the circuit itself.
    bytes32 internal constant PAIR_TAG = keccak256("pluri:test:pair-tag");
    bytes32 internal constant PREPARE_TYPEHASH =
        keccak256("PrivatePrepare(bytes32 dealId,bytes32 dealSubject,address module,uint256 deadline)");

    bytes32 internal constant DEAL_ID = keccak256("deal-1");
    bytes32 internal constant DEAL_ID_2 = keccak256("deal-2");
    bytes32 internal constant SUBJECT_H = bytes32(uint256(0x51));
    bytes32 internal constant SUBJECT_X = bytes32(uint256(0x99));
    bytes32 internal constant NEW_LEAF_H = bytes32(uint256(0x61));
    bytes32 internal constant NEW_LEAF_X = bytes32(uint256(0x69));
    bytes32 internal constant NULLREP_H = keccak256("nullrep-h-1");
    bytes32 internal constant FAKE_ROOT = keccak256("fake-root");
    address internal constant TOKEN = address(0x705);
    address internal constant FEE_TO = address(0xFEE);
    uint256 internal constant PRINCIPAL = 1_000_000;

    uint256 internal holderPk = 0xA11CE;
    uint256 internal otherPk = 0xB0B;
    address internal holder;
    address internal other;

    HumanityVerifierMock internal humanity;
    AccountVerifierMock internal account;
    PreparePassportVerifierMock internal passportProof;
    PrepareAdmitVerifierMock internal admitProof;
    ClaimVerifierMock internal claimProof;
    PoseidonTree internal tree;
    PrivatePassport internal passport;
    PrivateReputation internal reputation;
    uint256 internal deadline;

    function setUp() public {
        // The private layer hashes through the pinned poseidon-solidity singletons, which a test
        // EVM starts without (PLURISWAP.md §5.1).
        PoseidonSingletons.install();
        holder = vm.addr(holderPk);
        other = vm.addr(otherPk);
        deadline = block.timestamp + 1 hours;

        humanity = new HumanityVerifierMock();
        account = new AccountVerifierMock();
        passportProof = new PreparePassportVerifierMock();
        admitProof = new PrepareAdmitVerifierMock();
        claimProof = new ClaimVerifierMock();
        // The accounts tree is wired before its owner exists: predict PrivateReputation's address
        // (tree, passport, then reputation itself consume the next three nonces).
        address predictedRep = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        tree = new PoseidonTree(32, DEFAULT_ROOT_HISTORY, predictedRep);
        passport = new PrivatePassport(tree, humanity, passportProof);
        reputation = new PrivateReputation(
            passport, tree, account, admitProof, claimProof, FEE_TO, 0, 0, 0, 0, address(this), address(0)
        );
        assertEq(address(reputation), predictedRep, "predicted tree owner drifted");
    }

    /// @dev A second, identical stack: the two-sided prepare has to be compared against two separate
    ///      prepares on a tree in the same starting state, and a tree cannot be rewound.
    function _freshModule() internal returns (PrivateReputation rep2, PoseidonTree tree2) {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        tree2 = new PoseidonTree(32, DEFAULT_ROOT_HISTORY, predicted);
        PrivatePassport passport2 = new PrivatePassport(tree2, humanity, passportProof);
        rep2 = new PrivateReputation(
            passport2, tree2, account, admitProof, claimProof, FEE_TO, 0, 0, 0, 0, address(this), address(0)
        );
        assertEq(address(rep2), predicted, "predicted tree owner drifted");
    }

    function ok(bool pass) internal pure returns (bytes memory) {
        return abi.encode(pass);
    }

    /// @dev The standard EIP-712 domain of the private modules ("PluriSwap", "1", own address):
    ///      building it here also pins that the modules use the standard construction.
    function _domainSep(address module) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("PluriSwap"),
                keccak256("1"),
                block.chainid,
                module
            )
        );
    }

    function _sig(address module, uint256 pk, bytes32 dealId_, bytes32 subject, uint256 deadline_)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(PREPARE_TYPEHASH, dealId_, subject, module, deadline_));
        bytes32 digest = MessageHashUtils.toTypedDataHash(_domainSep(module), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    // ---------------------------------------------------------------- PrivatePassport.prepare

    function test_passport_prepare_buffersSubject() public {
        vm.prank(other); // the relayer is anyone; the proof and the signature are the authority
        vm.expectEmit(true, true, true, true, address(passport));
        emit PrivatePassport.PassportPrepared(holder, SUBJECT_H, deadline);
        passport.prepare(
            holder,
            DEAL_ID,
            SUBJECT_H,
            tree.root(),
            deadline,
            ok(true),
            _sig(address(passport), holderPk, DEAL_ID, SUBJECT_H, deadline)
        );
        (bytes32 buffered, uint256 bufferedDeadline) = passport.preparedPassport(holder);
        assertEq(buffered, SUBJECT_H);
        assertEq(bufferedDeadline, deadline);
    }

    function test_passport_prepare_badProofMarksNothing() public {
        bytes32 root = tree.root();
        bytes memory sig = _sig(address(passport), holderPk, DEAL_ID, SUBJECT_H, deadline);
        vm.expectRevert(PrivatePassport.PassportProofFailed.selector);
        passport.prepare(holder, DEAL_ID, SUBJECT_H, root, deadline, ok(false), sig);
        (bytes32 buffered,) = passport.preparedPassport(holder);
        assertEq(buffered, 0);
    }

    function test_passport_prepare_unknownRoot() public {
        vm.expectRevert(PrivatePassport.UnknownRoot.selector);
        passport.prepare(
            holder,
            DEAL_ID,
            SUBJECT_H,
            FAKE_ROOT,
            deadline,
            ok(true),
            _sig(address(passport), holderPk, DEAL_ID, SUBJECT_H, deadline)
        );
    }

    function test_passport_prepare_expired() public {
        vm.warp(deadline + 1);
        bytes32 root = tree.root();
        vm.expectRevert(PrivatePassport.PrepareExpired.selector);
        passport.prepare(
            holder,
            DEAL_ID,
            SUBJECT_H,
            root,
            deadline,
            ok(true),
            _sig(address(passport), holderPk, DEAL_ID, SUBJECT_H, deadline)
        );
    }

    function test_passport_prepare_wrongWalletKey() public {
        bytes32 root = tree.root();
        bytes memory sig = _sig(address(passport), otherPk, DEAL_ID, SUBJECT_H, deadline);
        vm.expectRevert(PrivatePassport.InvalidWalletSignature.selector);
        passport.prepare(holder, DEAL_ID, SUBJECT_H, root, deadline, ok(true), sig);
        (bytes32 buffered,) = passport.preparedPassport(holder);
        assertEq(buffered, 0);
    }

    function test_passport_prepare_latestWins() public {
        passport.prepare(
            holder,
            DEAL_ID,
            SUBJECT_H,
            tree.root(),
            deadline,
            ok(true),
            _sig(address(passport), holderPk, DEAL_ID, SUBJECT_H, deadline)
        );
        passport.prepare(
            holder,
            DEAL_ID,
            SUBJECT_X,
            tree.root(),
            deadline,
            ok(true),
            _sig(address(passport), holderPk, DEAL_ID, SUBJECT_X, deadline)
        );
        assertEq(passport.identify(holder), SUBJECT_X);
    }

    // ---------------------------------------------------------------- PrivatePassport.identify

    function test_passport_identify_answersPrepared() public {
        passport.prepare(
            holder,
            DEAL_ID,
            SUBJECT_H,
            tree.root(),
            deadline,
            ok(true),
            _sig(address(passport), holderPk, DEAL_ID, SUBJECT_H, deadline)
        );
        assertEq(passport.identify(holder), SUBJECT_H);
    }

    function test_passport_identify_failsClosedWithoutPrepare() public {
        vm.expectRevert(IPassport.NoPassport.selector);
        passport.identify(holder);
    }

    function test_passport_identify_failsClosedAfterExpiry() public {
        passport.prepare(
            holder,
            DEAL_ID,
            SUBJECT_H,
            tree.root(),
            deadline,
            ok(true),
            _sig(address(passport), holderPk, DEAL_ID, SUBJECT_H, deadline)
        );
        vm.warp(deadline + 1);
        vm.expectRevert(IPassport.NoPassport.selector);
        passport.identify(holder);
    }

    // ---------------------------------------------------------------- PrivateReputation.prepare

    function test_reputation_prepare_spendsInsertsBuffers() public {
        vm.expectEmit(true, true, true, true, address(reputation));
        emit PrivateReputation.ReputationPrepared(holder, SUBJECT_H, NEW_LEAF_H, deadline);
        reputation.prepare(
            holder,
            DEAL_ID,
            SUBJECT_H,
            NEW_LEAF_H,
            NULLREP_H,
            TOKEN,
            PRINCIPAL,
            bytes32(0),
            tree.root(),
            PAIR_TAG,
            deadline,
            ok(true),
            _sig(address(reputation), holderPk, DEAL_ID, SUBJECT_H, deadline)
        );
        assertTrue(tree.isSpent(NULLREP_H), "version nullifier not burned");
        assertEq(tree.nextIndex(), 1, "transition leaf not inserted");
        assertTrue(tree.isKnownRoot(tree.root()));
        (bytes32 buffered, address bufferedToken, uint256 bufferedPrincipal, uint256 bufferedDeadline,) =
            reputation.preparedAdmit(holder);
        assertEq(buffered, SUBJECT_H);
        assertEq(bufferedToken, TOKEN);
        assertEq(bufferedPrincipal, PRINCIPAL);
        assertEq(bufferedDeadline, deadline);
    }

    function test_reputation_prepare_serializesByNullifier() public {
        reputation.prepare(
            holder,
            DEAL_ID,
            SUBJECT_H,
            NEW_LEAF_H,
            NULLREP_H,
            TOKEN,
            PRINCIPAL,
            bytes32(0),
            tree.root(),
            PAIR_TAG,
            deadline,
            ok(true),
            _sig(address(reputation), holderPk, DEAL_ID, SUBJECT_H, deadline)
        );
        // A second prepare against the same account version burns the same nullRep: replay.
        bytes32 root = tree.root();
        bytes memory sig = _sig(address(reputation), holderPk, DEAL_ID_2, SUBJECT_H, deadline);
        vm.expectRevert(PoseidonTree.NullifierUsed.selector);
        reputation.prepare(
            holder,
            DEAL_ID_2,
            SUBJECT_H,
            NEW_LEAF_X,
            NULLREP_H,
            TOKEN,
            PRINCIPAL,
            bytes32(0),
            root,
            PAIR_TAG,
            deadline,
            ok(true),
            sig
        );
        assertEq(tree.nextIndex(), 1);
    }

    function test_reputation_prepare_badProofIsAtomic() public {
        bytes32 root = tree.root();
        bytes memory sig = _sig(address(reputation), holderPk, DEAL_ID, SUBJECT_H, deadline);
        vm.expectRevert(PrivateReputation.AdmitProofFailed.selector);
        reputation.prepare(
            holder,
            DEAL_ID,
            SUBJECT_H,
            NEW_LEAF_H,
            NULLREP_H,
            TOKEN,
            PRINCIPAL,
            bytes32(0),
            root,
            PAIR_TAG,
            deadline,
            ok(false),
            sig
        );
        assertFalse(tree.isSpent(NULLREP_H));
        assertEq(tree.nextIndex(), 0);
        (bytes32 buffered,,,,) = reputation.preparedAdmit(holder);
        assertEq(buffered, 0);
    }

    function test_reputation_prepare_unknownRoot() public {
        vm.expectRevert(PrivateReputation.UnknownRoot.selector);
        reputation.prepare(
            holder,
            DEAL_ID,
            SUBJECT_H,
            NEW_LEAF_H,
            NULLREP_H,
            TOKEN,
            PRINCIPAL,
            bytes32(0),
            FAKE_ROOT,
            PAIR_TAG,
            deadline,
            ok(true),
            _sig(address(reputation), holderPk, DEAL_ID, SUBJECT_H, deadline)
        );
    }

    function test_reputation_prepare_expired() public {
        vm.warp(deadline + 1);
        bytes32 root = tree.root();
        vm.expectRevert(PrivateReputation.PrepareExpired.selector);
        reputation.prepare(
            holder,
            DEAL_ID,
            SUBJECT_H,
            NEW_LEAF_H,
            NULLREP_H,
            TOKEN,
            PRINCIPAL,
            bytes32(0),
            root,
            PAIR_TAG,
            deadline,
            ok(true),
            _sig(address(reputation), holderPk, DEAL_ID, SUBJECT_H, deadline)
        );
    }

    function test_reputation_prepare_wrongWalletKey() public {
        bytes32 root = tree.root();
        bytes memory sig = _sig(address(reputation), otherPk, DEAL_ID, SUBJECT_H, deadline);
        vm.expectRevert(PrivateReputation.InvalidWalletSignature.selector);
        reputation.prepare(
            holder,
            DEAL_ID,
            SUBJECT_H,
            NEW_LEAF_H,
            NULLREP_H,
            TOKEN,
            PRINCIPAL,
            bytes32(0),
            root,
            PAIR_TAG,
            deadline,
            ok(true),
            sig
        );
        assertFalse(tree.isSpent(NULLREP_H));
        assertEq(tree.nextIndex(), 0);
    }
    // ---------------------------------------------------------------- the two-sided prepare

    /// @dev The consent is bound to the module that will read it (its address is in the EIP-712
    ///      domain AND in the struct), so a side built for one module is not valid on another.
    function _side(
        address module,
        address wallet,
        uint256 pk,
        bytes32 subject,
        bytes32 leaf,
        bytes32 nullifier,
        uint256 deadline_
    ) internal view returns (PrivateReputation.Side memory) {
        return _sideOf(module, DEAL_ID, wallet, pk, subject, leaf, nullifier, deadline_);
    }

    /// @dev The consent names the deal, so a side signed for one deal is not valid in another.
    function _sideOf(
        address module,
        bytes32 dealId_,
        address wallet,
        uint256 pk,
        bytes32 subject,
        bytes32 leaf,
        bytes32 nullifier,
        uint256 deadline_
    ) internal view returns (PrivateReputation.Side memory) {
        return PrivateReputation.Side({
            wallet: wallet,
            dealSubject: subject,
            newLeaf: leaf,
            nullRep: nullifier,
            lockCommit: bytes32(0),
            proof: ok(true),
            walletSig: _sig(module, pk, dealId_, subject, deadline_)
        });
    }

    /// The two sides of one activation, prepared together, have to leave EXACTLY the state two
    /// separate calls would: same root, same count, same buffers, same nullifiers burned. The saving
    /// is the tree's — two leaves at adjacent indices share every level above their common subtree.
    function test_prepareBoth_isTheSameStateAsTwoPrepares() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 root = tree.root();

        // Path A: the two calls, on this tree.
        reputation.prepare(
            holder, DEAL_ID, SUBJECT_H, NEW_LEAF_H, NULLREP_H, TOKEN, PRINCIPAL, bytes32(0), root, PAIR_TAG,
            deadline, ok(true), _sig(address(reputation), holderPk, DEAL_ID, SUBJECT_H, deadline)
        );
        // The second side proves against the root the first insert produced: that sequencing is what
        // `prepareBoth` removes.
        reputation.prepare(
            other, DEAL_ID, SUBJECT_X, NEW_LEAF_X, keccak256("nullrep-x-1"), TOKEN, PRINCIPAL, bytes32(0),
            tree.root(), PAIR_TAG, deadline, ok(true), _sig(address(reputation), otherPk, DEAL_ID, SUBJECT_X, deadline)
        );
        bytes32 rootAfterTwo = tree.root();
        uint256 countAfterTwo = tree.nextIndex();

        // Path B: a second stack, the same two sides, one call.
        (PrivateReputation rep2, PoseidonTree tree2) = _freshModule();
        bytes32 root2 = tree2.root();
        assertEq(root2, root, "both stacks start from the same empty tree");
        rep2.prepareBoth(
            DEAL_ID,
            _side(address(rep2), holder, holderPk, SUBJECT_H, NEW_LEAF_H, NULLREP_H, deadline),
            _side(address(rep2), other, otherPk, SUBJECT_X, NEW_LEAF_X, keccak256("nullrep-x-1"), deadline),
            TOKEN,
            PRINCIPAL,
            root2,
            PAIR_TAG,
            deadline
        );

        assertEq(tree2.root(), rootAfterTwo, "same root");
        assertEq(tree2.nextIndex(), countAfterTwo, "same count");
        assertTrue(tree2.isSpent(NULLREP_H) && tree2.isSpent(keccak256("nullrep-x-1")), "both nullifiers burned");
        (bytes32 bufH,,,,) = rep2.preparedAdmit(holder);
        (bytes32 bufX,,,,) = rep2.preparedAdmit(other);
        assertEq(bufH, SUBJECT_H, "holder buffered");
        assertEq(bufX, SUBJECT_X, "provider buffered");
        assertEq(rep2.pairTagOf(DEAL_ID), PAIR_TAG, "the pair is recorded once");
    }

    /// Concurrency, at the only level where it exists on chain: transactions are ordered, so "at the
    /// same time" means "the second one sees what the first left". These are the races that matter for
    /// a two-sided prepare, and each is already closed by something that was there for another reason.
    function test_prepareBoth_racesAreClosedByTheNullifier() public {
        uint256 deadline_ = block.timestamp + 1 hours;

        // The same account on BOTH sides of one deal: the two sides burn the same version nullifier,
        // so the call cannot complete. The counterparty rule has a subject-level guard in the kernel
        // (`SameSubject`), but the module does not need it — the tree refuses first.
        (PrivateReputation rep2,) = _freshModule();
        // Every argument built BEFORE the expectation: an external call in the argument list is a
        // call, and forge matches the expectation against the next one it sees.
        PrivateReputation.Side memory sameH = _side(address(rep2), holder, holderPk, SUBJECT_H, NEW_LEAF_H, NULLREP_H, deadline_);
        PrivateReputation.Side memory sameP = _side(address(rep2), other, otherPk, SUBJECT_X, NEW_LEAF_X, NULLREP_H, deadline_);
        bytes32 root2 = rep2.accountTree().root();
        vm.expectRevert(PoseidonTree.NullifierUsed.selector);
        rep2.prepareBoth(
            DEAL_ID,
            sameH,
            sameP,
            TOKEN,
            PRINCIPAL,
            root2,
            PAIR_TAG,
            deadline_
        );

        // Two activations of the same account racing: whoever lands first spends the version, and the
        // second dies on the nullifier rather than double-spending the cap.
        (PrivateReputation rep3,) = _freshModule();
        rep3.prepareBoth(
            DEAL_ID,
            _side(address(rep3), holder, holderPk, SUBJECT_H, NEW_LEAF_H, NULLREP_H, deadline_),
            _side(address(rep3), other, otherPk, SUBJECT_X, NEW_LEAF_X, keccak256("nullrep-x-1"), deadline_),
            TOKEN,
            PRINCIPAL,
            rep3.accountTree().root(),
            PAIR_TAG,
            deadline_
        );
        bytes32 movedRoot = rep3.accountTree().root();
        PrivateReputation.Side memory againH =
            _sideOf(address(rep3), DEAL_ID_2, holder, holderPk, SUBJECT_H, NEW_LEAF_H, NULLREP_H, deadline_);
        PrivateReputation.Side memory freshP =
            _sideOf(address(rep3), DEAL_ID_2, other, otherPk, SUBJECT_X, NEW_LEAF_X, keccak256("nullrep-x-2"), deadline_);
        vm.expectRevert(PoseidonTree.NullifierUsed.selector);
        rep3.prepareBoth(
            DEAL_ID_2,
            againH,
            freshP,
            TOKEN,
            PRINCIPAL,
            movedRoot,
            PAIR_TAG,
            deadline_
        );
    }

    /// The root moving under a proof is not a race at all: a prepare that landed first advances the
    /// root, and the one behind it still verifies because the ring keeps the old roots live. That is
    /// what the window is for, and the two-sided call makes it matter less — the two sides of one deal
    /// no longer move the root on each other at all.
    function test_prepareBoth_anOlderRootStillVerifies() public {
        uint256 deadline_ = block.timestamp + 1 hours;
        (PrivateReputation rep2, PoseidonTree tree2) = _freshModule();
        bytes32 rootBefore = tree2.root();

        // Somebody else's activation lands first and moves the root.
        rep2.prepareBoth(
            DEAL_ID,
            _side(address(rep2), holder, holderPk, SUBJECT_H, NEW_LEAF_H, NULLREP_H, deadline_),
            _side(address(rep2), other, otherPk, SUBJECT_X, NEW_LEAF_X, keccak256("nullrep-x-1"), deadline_),
            TOKEN,
            PRINCIPAL,
            rootBefore,
            PAIR_TAG,
            deadline_
        );
        assertTrue(tree2.root() != rootBefore, "the root moved");
        assertTrue(tree2.isKnownRoot(rootBefore), "and the old one is still accepted");
    }

    function test_prepareBoth_costsLess() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 root = tree.root();
        uint256 before = gasleft();
        reputation.prepare(
            holder, DEAL_ID, SUBJECT_H, NEW_LEAF_H, NULLREP_H, TOKEN, PRINCIPAL, bytes32(0), root, PAIR_TAG,
            deadline, ok(true), _sig(address(reputation), holderPk, DEAL_ID, SUBJECT_H, deadline)
        );
        reputation.prepare(
            other, DEAL_ID, SUBJECT_X, NEW_LEAF_X, keccak256("nullrep-x-1"), TOKEN, PRINCIPAL, bytes32(0),
            tree.root(), PAIR_TAG, deadline, ok(true), _sig(address(reputation), otherPk, DEAL_ID, SUBJECT_X, deadline)
        );
        uint256 separate = before - gasleft();

        (PrivateReputation rep2,) = _freshModule();
        PrivateReputation.Side memory h = _side(address(rep2), holder, holderPk, SUBJECT_H, NEW_LEAF_H, NULLREP_H, deadline);
        PrivateReputation.Side memory p = _side(address(rep2), other, otherPk, SUBJECT_X, NEW_LEAF_X, keccak256("nullrep-x-1"), deadline);
        bytes32 root2 = rep2.accountTree().root();
        before = gasleft();
        rep2.prepareBoth(DEAL_ID, h, p, TOKEN, PRINCIPAL, root2, PAIR_TAG, deadline);
        uint256 together = before - gasleft();

        emit log_named_uint("two prepares, separately", separate);
        emit log_named_uint("prepareBoth", together);
        emit log_named_uint("saved", separate - together);
        assertLt(together, separate, "batching the insert has to pay for the extra entrypoint");
    }

}
