// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {
    Status,
    DealTerms,
    HolderAuthorization,
    ProviderAgreement,
    ControllerAcceptance,
    PackageMods
} from "../src/libraries/Types.sol";
import {Consent} from "../src/libraries/Consent.sol";
import {PackageId} from "../src/libraries/PackageId.sol";
import {Escrow} from "../src/Escrow.sol";
import {IReputation} from "../src/packages/interfaces/IReputation.sol";
import {PoseidonTree} from "../src/packages/PoseidonTree.sol";
import {PrivatePassport} from "../src/packages/PrivatePassport.sol";
import {PrivateReputation} from "../src/packages/PrivateReputation.sol";
import {HumanityVerifierMock} from "../mocks/HumanityVerifierMock.sol";
import {AccountVerifierMock} from "../mocks/AccountVerifierMock.sol";
import {PreparePassportVerifierMock} from "../mocks/PreparePassportVerifierMock.sol";
import {PrepareAdmitVerifierMock} from "../mocks/PrepareAdmitVerifierMock.sol";
import {ClaimVerifierMock} from "../mocks/ClaimVerifierMock.sol";
import {RelayerMock} from "../mocks/RelayerMock.sol";
import {BaseTest} from "./Base.t.sol";

/// @title Private deal tests (F2, PLURISWAP.md §3.15.4–3.15.5)
/// @dev The private package set (PrivatePassport + PrivateReputation) against the real kernel:
///      the activation bundle is one tx, admit consumes the buffer, terminals pend one delta per
///      deal subject, claim applies it once. Verifier mocks decode the proof as a bool: a passing
///      mock is not privacy, and nothing here claims it is.
///
///      Test hygiene: every external call that feeds a reverting call (roots, signatures, sides)
///      is hoisted to a local BEFORE `vm.expectRevert` — the expectation is consumed by the next
///      call, whatever it is.
contract PrivateDealTest is BaseTest {
    bytes32 internal constant PREPARE_TYPEHASH =
        keccak256("PrivatePrepare(bytes32 dealId,bytes32 dealSubject,address module,uint256 deadline)");

    bytes32 internal constant HN_H = keccak256("human-h");
    bytes32 internal constant HN_P = keccak256("human-p");
    bytes32 internal constant LEAF0_H = bytes32(uint256(0x1001));
    bytes32 internal constant LEAF0_P = bytes32(uint256(0x1002));
    bytes32 internal constant SUBJECT_H = bytes32(uint256(0x51));
    bytes32 internal constant SUBJECT_P = bytes32(uint256(0x52));
    bytes32 internal constant ADMIT_LEAF_H = bytes32(uint256(0x61));
    bytes32 internal constant ADMIT_LEAF_P = bytes32(uint256(0x62));
    bytes32 internal constant CLAIM_LEAF_H = bytes32(uint256(0x71));
    bytes32 internal constant NULLREP_H1 = keccak256("nullrep-h-1");
    bytes32 internal constant NULLREP_P1 = keccak256("nullrep-p-1");
    bytes32 internal constant NULLREP_H2 = keccak256("nullrep-h-2");
    bytes32 internal constant FAKE_ROOT = keccak256("fake-root");
    address internal constant FEE_TO = address(0xFEE);

    HumanityVerifierMock internal humanity;
    AccountVerifierMock internal account;
    PreparePassportVerifierMock internal passportProof;
    PrepareAdmitVerifierMock internal admitProof;
    ClaimVerifierMock internal claimProof;
    RelayerMock internal relayer;
    PoseidonTree internal tree;
    PrivatePassport internal passport;
    PrivateReputation internal reputation;

    HolderAuthorization internal ha;
    ProviderAgreement internal pa;
    PackageMods internal mods;
    bytes32 internal dealId;

    function setUp() public override {
        super.setUp();
        humanity = new HumanityVerifierMock();
        account = new AccountVerifierMock();
        passportProof = new PreparePassportVerifierMock();
        admitProof = new PrepareAdmitVerifierMock();
        claimProof = new ClaimVerifierMock();
        relayer = new RelayerMock();
        // The accounts tree is wired before its owner exists: predict PrivateReputation's address
        // (tree, passport, then reputation itself consume the next three nonces). The operator is
        // the kernel: admit and notifyTerminal must only ever answer the escrow's context.
        address predictedRep = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        tree = new PoseidonTree(32, predictedRep);
        passport = new PrivatePassport(tree, humanity, passportProof);
        reputation =
            new PrivateReputation(passport, tree, account, admitProof, claimProof, FEE_TO, 0, 0, 0, 0, address(escrow));
        assertEq(address(reputation), predictedRep, "predicted tree owner drifted");

        // Two registered humans, two initial leaves.
        passport.register(ok(true), HN_H);
        reputation.register(ok(true), HN_H, LEAF0_H);
        passport.register(ok(true), HN_P);
        reputation.register(ok(true), HN_P, LEAF0_P);

        ha = _holderAuth(_privateTerms(), 1);
        pa = _providerAuth(_privateTerms(), 1);
        mods = _mods(address(passport), address(reputation));
        dealId = Consent.dealId(escrow.domainSeparator(), _privateTerms(), 1, 1, 0);
    }

    function ok(bool pass) internal pure returns (bytes memory) {
        return abi.encode(pass);
    }

    function _privateTerms() internal view returns (DealTerms memory t) {
        t = _p2pTerms();
        // The kernel signs a strictly ascending id list (Terms.UnsortedPackageIds): the relayer
        // sorts the private set the same way.
        bytes32 id0 = PackageId.passport(address(passport));
        bytes32 id1 = PackageId.reputation(address(reputation), FEE_TO, 0, 0, 0, 0);
        t.packageIds = new bytes32[](2);
        if (id0 < id1) {
            t.packageIds[0] = id0;
            t.packageIds[1] = id1;
        } else {
            t.packageIds[0] = id1;
            t.packageIds[1] = id0;
        }
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

    function _side(address wallet, uint256 pk, bytes32 subject, bytes32 newLeaf, bytes32 nullRep)
        internal
        view
        returns (RelayerMock.Side memory s)
    {
        s.wallet = wallet;
        s.dealSubject = subject;
        s.newLeaf = newLeaf;
        s.nullRep = nullRep;
        s.passportProof = ok(true);
        s.admitProof = ok(true);
        s.passportSig = _sig(address(passport), pk, dealId, subject, ha.deadline);
        s.admitSig = _sig(address(reputation), pk, dealId, subject, ha.deadline);
    }

    /// @dev The activation bundle: four prepares and `activate` in one tx (PLURISWAP.md §3.15.4).
    ///      All argument evaluation is hoisted so no expectation or prank leaks into it.
    function _activate() internal returns (bytes32) {
        ControllerAcceptance memory ca;
        bytes memory hs = _signHolder(ha);
        bytes memory ps = _signProvider(pa);
        RelayerMock.Side memory sideH = _side(holder, holderPk, SUBJECT_H, ADMIT_LEAF_H, NULLREP_H1);
        RelayerMock.Side memory sideP = _side(provider, providerPk, SUBJECT_P, ADMIT_LEAF_P, NULLREP_P1);
        return relayer.activatePrivate(escrow, passport, reputation, ha, hs, pa, ps, ca, "", mods, dealId, sideH, sideP);
    }

    function _terminalReleased() internal {
        _activate();
        _markFiat(dealId);
        vm.prank(holder); // the controller releases after fiat was marked
        escrow.release(dealId);
    }

    // ---------------------------------------------------------------- activation bundle

    function test_activate_fullBundle() public {
        bytes32 id = _activate();

        assertEq(id, dealId);
        assertTrue(uint8(escrow.status(dealId)) == uint8(Status.FUNDED));
        (bytes32 subjectH, bytes32 subjectP) = escrow.subjects(dealId);
        assertEq(subjectH, SUBJECT_H);
        assertEq(subjectP, SUBJECT_P);
        // Two leaf0s + two admit transitions.
        assertEq(tree.nextIndex(), 4);
        assertTrue(tree.isSpent(NULLREP_H1));
        assertTrue(tree.isSpent(NULLREP_P1));
        // The admit buffers are consumed: no second deal against the same transition.
        (bytes32 admitH,,,) = reputation.preparedAdmit(holder);
        (bytes32 admitP,,,) = reputation.preparedAdmit(provider);
        assertEq(admitH, 0);
        assertEq(admitP, 0);
        // The passport buffers persist (identify is view — accepted limitation, §3.15.4).
        assertEq(passport.identify(holder), SUBJECT_H);
        assertEq(passport.identify(provider), SUBJECT_P);
        assertEq(escrow.postPending(dealId), 0);
    }

    function test_bundle_isAtomic() public {
        ControllerAcceptance memory ca;
        bytes memory hs = _signHolder(ha);
        bytes memory providerSig = _signProvider(pa);
        providerSig[10] = providerSig[10] ^ 0x01; // break the deal consent, AFTER the prepares would have run
        RelayerMock.Side memory sideH = _side(holder, holderPk, SUBJECT_H, ADMIT_LEAF_H, NULLREP_H1);
        RelayerMock.Side memory sideP = _side(provider, providerPk, SUBJECT_P, ADMIT_LEAF_P, NULLREP_P1);
        vm.expectRevert(Escrow.InvalidProviderSignature.selector);
        relayer.activatePrivate(
            escrow, passport, reputation, ha, hs, pa, providerSig, ca, "", mods, dealId, sideH, sideP
        );
        // The failed activation reverted the prepares with it: no leaves, no nullifiers, no buffers.
        assertEq(tree.nextIndex(), 2);
        assertFalse(tree.isSpent(NULLREP_H1));
        assertFalse(tree.isSpent(NULLREP_P1));
        (bytes32 admitH,,,) = reputation.preparedAdmit(holder);
        (bytes32 admitP,,,) = reputation.preparedAdmit(provider);
        assertEq(admitH, 0);
        assertEq(admitP, 0);
        (bytes32 passH,) = passport.preparedPassport(holder);
        (bytes32 passP,) = passport.preparedPassport(provider);
        assertEq(passH, 0);
        assertEq(passP, 0);
        assertTrue(uint8(escrow.status(dealId)) == uint8(Status.NONE));
    }

    function test_activate_failsClosedWithoutFreshPrepare() public {
        // First deal lands normally and consumes both admit buffers.
        _activate();

        // A second deal for the same wallets needs fresh prepares: the stale buffers are gone,
        // so activation fails closed. This delete is what kills the cap replay (§3.15.4).
        HolderAuthorization memory ha2 = _holderAuth(_privateTerms(), 2);
        ProviderAgreement memory pa2 = _providerAuth(_privateTerms(), 2);
        bytes32 deal2 = Consent.dealId(escrow.domainSeparator(), _privateTerms(), 2, 2, 0);
        ControllerAcceptance memory ca;
        bytes memory hs2 = _signHolder(ha2);
        bytes memory ps2 = _signProvider(pa2);
        vm.expectRevert(PrivateReputation.NoPrepare.selector);
        escrow.activate(ha2, hs2, pa2, ps2, ca, "", mods);
        assertTrue(uint8(escrow.status(deal2)) == uint8(Status.NONE));
    }

    // ---------------------------------------------------------------- admit

    function test_admit_onlyOperator() public {
        vm.prank(address(0xB0B));
        vm.expectRevert(PrivateReputation.Unauthorized.selector);
        reputation.admit(holder, address(token), PRINCIPAL, address(0));
    }

    function test_admit_consumesBufferAndCrossChecks() public {
        bytes32 root = tree.root();
        bytes memory passportSig = _sig(address(passport), holderPk, dealId, SUBJECT_H, ha.deadline);
        bytes memory admitSig = _sig(address(reputation), holderPk, dealId, SUBJECT_H, ha.deadline);
        passport.prepare(holder, dealId, SUBJECT_H, root, ha.deadline, ok(true), passportSig);
        reputation.prepare(
            holder,
            dealId,
            SUBJECT_H,
            ADMIT_LEAF_H,
            NULLREP_H1,
            address(token),
            PRINCIPAL,
            bytes32(0),
            root,
            ha.deadline,
            ok(true),
            admitSig
        );
        vm.expectEmit(true, true, true, true, address(reputation));
        emit PrivateReputation.Admitted(holder, SUBJECT_H, address(token), PRINCIPAL);
        vm.prank(address(escrow));
        bytes32 subject = reputation.admit(holder, address(token), PRINCIPAL, address(0));
        assertEq(subject, SUBJECT_H);
        (bytes32 buffered,,,) = reputation.preparedAdmit(holder);
        assertEq(buffered, 0);
    }

    function test_admit_guards() public {
        bytes32 root = tree.root();
        bytes memory admitSig = _sig(address(reputation), holderPk, dealId, SUBJECT_H, ha.deadline);
        reputation.prepare(
            holder,
            dealId,
            SUBJECT_H,
            ADMIT_LEAF_H,
            NULLREP_H1,
            address(token),
            PRINCIPAL,
            bytes32(0),
            root,
            ha.deadline,
            ok(true),
            admitSig
        );
        vm.prank(address(escrow));
        vm.expectRevert(PrivateReputation.UnsupportedVault.selector);
        reputation.admit(holder, address(token), PRINCIPAL, address(0xB0B));
        vm.prank(address(escrow));
        vm.expectRevert(PrivateReputation.PrepareMismatch.selector);
        reputation.admit(holder, address(token), PRINCIPAL / 2, address(0));
        vm.prank(address(escrow));
        vm.expectRevert(PrivateReputation.NoPrepare.selector);
        reputation.admit(provider, address(token), PRINCIPAL, address(0));
        // Nothing was consumed by the failed admits.
        (bytes32 buffered,,,) = reputation.preparedAdmit(holder);
        assertEq(buffered, SUBJECT_H);
    }

    function test_admit_crossCheckFails() public {
        bytes32 root = tree.root();
        bytes32 otherSubject = bytes32(uint256(0x99));
        bytes memory passportSig = _sig(address(passport), holderPk, dealId, SUBJECT_H, ha.deadline);
        bytes memory admitSig = _sig(address(reputation), holderPk, dealId, otherSubject, ha.deadline);
        passport.prepare(holder, dealId, SUBJECT_H, root, ha.deadline, ok(true), passportSig);
        reputation.prepare(
            holder,
            dealId,
            otherSubject,
            ADMIT_LEAF_H,
            NULLREP_H1,
            address(token),
            PRINCIPAL,
            bytes32(0),
            root,
            ha.deadline,
            ok(true),
            admitSig
        );
        vm.prank(address(escrow));
        vm.expectRevert(PrivateReputation.PeerMismatch.selector);
        reputation.admit(holder, address(token), PRINCIPAL, address(0));
    }

    function test_admit_expiredPrepareFailsClosed() public {
        bytes32 root = tree.root();
        bytes memory admitSig = _sig(address(reputation), holderPk, dealId, SUBJECT_H, ha.deadline);
        reputation.prepare(
            holder,
            dealId,
            SUBJECT_H,
            ADMIT_LEAF_H,
            NULLREP_H1,
            address(token),
            PRINCIPAL,
            bytes32(0),
            root,
            ha.deadline,
            ok(true),
            admitSig
        );
        vm.warp(ha.deadline + 1);
        vm.prank(address(escrow));
        vm.expectRevert(PrivateReputation.NoPrepare.selector);
        reputation.admit(holder, address(token), PRINCIPAL, address(0));
    }

    // ---------------------------------------------------------------- terminal

    function test_terminal_pendsBothDeltas() public {
        _terminalReleased();
        assertTrue(uint8(escrow.status(dealId)) == uint8(Status.RELEASED));
        assertEq(escrow.postPending(dealId), 0); // both notifications landed on first attempt

        (IReputation.Close kindH, address tokenH, uint256 principalH) = reputation.pending(SUBJECT_H);
        assertTrue(kindH == IReputation.Close.Peaceful);
        assertEq(tokenH, address(token));
        assertEq(principalH, PRINCIPAL);
        (IReputation.Close kindP, address tokenP, uint256 principalP) = reputation.pending(SUBJECT_P);
        assertTrue(kindP == IReputation.Close.Peaceful);
        assertEq(tokenP, address(token));
        assertEq(principalP, PRINCIPAL);
        assertFalse(reputation.claimed(SUBJECT_H));
        assertFalse(reputation.claimed(SUBJECT_P));
    }

    function test_notifyTerminal_onlyOperator() public {
        vm.prank(address(0xB0B));
        vm.expectRevert(PrivateReputation.Unauthorized.selector);
        reputation.notifyTerminal(SUBJECT_H, address(token), PRINCIPAL, IReputation.Close.Peaceful);
    }

    function test_notifyTerminal_doublePendingFailsClosed() public {
        vm.prank(address(escrow));
        reputation.notifyTerminal(SUBJECT_H, address(token), PRINCIPAL, IReputation.Close.Peaceful);
        // Same subject twice: the same human on both ends of a deal is pathological, and the
        // module fails closed rather than overwrite a delta (the account punishes itself).
        vm.prank(address(escrow));
        vm.expectRevert(PrivateReputation.AlreadyPending.selector);
        reputation.notifyTerminal(SUBJECT_H, address(token), PRINCIPAL, IReputation.Close.Silent);
    }

    function test_notifyTerminal_afterClaimFailsClosed() public {
        vm.prank(address(escrow));
        reputation.notifyTerminal(SUBJECT_H, address(token), PRINCIPAL, IReputation.Close.Peaceful);
        bytes32 root = tree.root();
        reputation.claim(dealId, SUBJECT_H, CLAIM_LEAF_H, NULLREP_H2, root, ok(true));
        vm.prank(address(escrow));
        vm.expectRevert(PrivateReputation.AlreadyClaimed.selector);
        reputation.notifyTerminal(SUBJECT_H, address(token), PRINCIPAL, IReputation.Close.Silent);
    }

    // ---------------------------------------------------------------- claim

    function test_claim_appliesDeltaOnce() public {
        _terminalReleased();
        uint256 before = tree.nextIndex();
        bytes32 root = tree.root();

        reputation.claim(dealId, SUBJECT_H, CLAIM_LEAF_H, NULLREP_H2, root, ok(true));
        assertTrue(reputation.claimed(SUBJECT_H));
        assertTrue(tree.isSpent(NULLREP_H2));
        assertEq(tree.nextIndex(), before + 1);
        (IReputation.Close kind, address pendingToken, uint256 pendingPrincipal) = reputation.pending(SUBJECT_H);
        assertTrue(kind == IReputation.Close.Peaceful);
        assertEq(pendingToken, address(0));
        assertEq(pendingPrincipal, 0);

        vm.expectRevert(PrivateReputation.AlreadyClaimed.selector);
        reputation.claim(dealId, SUBJECT_H, CLAIM_LEAF_H, NULLREP_H2, root, ok(true));
    }

    function test_claim_requiresTerminalDelta() public {
        _activate(); // live deal, no terminal yet
        bytes32 root = tree.root();
        vm.expectRevert(PrivateReputation.NothingToClaim.selector);
        reputation.claim(dealId, SUBJECT_H, CLAIM_LEAF_H, NULLREP_H2, root, ok(true));
    }

    function test_claim_unknownSubject() public {
        bytes32 root = tree.root();
        vm.expectRevert(PrivateReputation.NothingToClaim.selector);
        reputation.claim(dealId, keccak256("no-such-subject"), CLAIM_LEAF_H, NULLREP_H2, root, ok(true));
    }

    function test_claim_badProofIsAtomic() public {
        _terminalReleased();
        bytes32 root = tree.root();
        vm.expectRevert(PrivateReputation.ClaimProofFailed.selector);
        reputation.claim(dealId, SUBJECT_H, CLAIM_LEAF_H, NULLREP_H2, root, ok(false));
        assertFalse(reputation.claimed(SUBJECT_H));
        assertFalse(tree.isSpent(NULLREP_H2));
        (, address pendingToken, uint256 pendingPrincipal) = reputation.pending(SUBJECT_H);
        assertEq(pendingToken, address(token));
        assertEq(pendingPrincipal, PRINCIPAL);
    }

    function test_claim_unknownRoot() public {
        _terminalReleased();
        vm.expectRevert(PrivateReputation.UnknownRoot.selector);
        reputation.claim(dealId, SUBJECT_H, CLAIM_LEAF_H, NULLREP_H2, FAKE_ROOT, ok(true));
    }
}
