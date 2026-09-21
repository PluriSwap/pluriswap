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
import {PoseidonTree} from "../src/packages/PoseidonTree.sol";
import {IPassport} from "../src/packages/interfaces/IPassport.sol";

/// @title Private prepare tests (F2, PLURISWAP.md §3.15.4)
/// @dev The activation bundle's write side: proofs fail closed, the wallet consent pins the
///      subject under the wallet, nullifiers serialize concurrent prepares by version.
///      Verifier mocks decode the proof as a bool: a passing mock is not privacy.
///
///      Test hygiene: every external call that feeds a reverting call (roots, signatures) is
///      hoisted to a local BEFORE `vm.expectRevert` — the expectation is consumed by the next
///      call, whatever it is.
contract PrivatePrepareTest is Test {
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
        tree = new PoseidonTree(32, predictedRep);
        passport = new PrivatePassport(tree, humanity, passportProof);
        reputation =
            new PrivateReputation(passport, tree, account, admitProof, claimProof, FEE_TO, 0, 0, 0, 0, address(this));
        assertEq(address(reputation), predictedRep, "predicted tree owner drifted");
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
            deadline,
            ok(true),
            _sig(address(reputation), holderPk, DEAL_ID, SUBJECT_H, deadline)
        );
        assertTrue(tree.isSpent(NULLREP_H), "version nullifier not burned");
        assertEq(tree.nextIndex(), 1, "transition leaf not inserted");
        assertTrue(tree.isKnownRoot(tree.root()));
        (bytes32 buffered, address bufferedToken, uint256 bufferedPrincipal, uint256 bufferedDeadline) =
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
            deadline,
            ok(false),
            sig
        );
        assertFalse(tree.isSpent(NULLREP_H));
        assertEq(tree.nextIndex(), 0);
        (bytes32 buffered,,,) = reputation.preparedAdmit(holder);
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
            deadline,
            ok(true),
            sig
        );
        assertFalse(tree.isSpent(NULLREP_H));
        assertEq(tree.nextIndex(), 0);
    }
}
