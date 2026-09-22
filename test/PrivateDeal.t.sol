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
import {IPrivateReputation} from "../src/packages/interfaces/IPrivateReputation.sol";
import {PoseidonTree, DEFAULT_ROOT_HISTORY, MIN_ROOT_HISTORY, MAX_ROOT_HISTORY} from "../src/packages/PoseidonTree.sol";
import {PrivatePassport} from "../src/packages/PrivatePassport.sol";
import {PrivateReputation} from "../src/packages/PrivateReputation.sol";
import {PrivateBondVault} from "../src/packages/PrivateBondVault.sol";
import {HumanityVerifierMock} from "../mocks/HumanityVerifierMock.sol";
import {AccountVerifierMock} from "../mocks/AccountVerifierMock.sol";
import {PreparePassportVerifierMock} from "../mocks/PreparePassportVerifierMock.sol";
import {PrepareAdmitVerifierMock} from "../mocks/PrepareAdmitVerifierMock.sol";
import {ClaimVerifierMock} from "../mocks/ClaimVerifierMock.sol";
import {DepositVerifierMock} from "../mocks/DepositVerifierMock.sol";
import {PrepareBondVerifierMock} from "../mocks/PrepareBondVerifierMock.sol";
import {ReabsorbVerifierMock} from "../mocks/ReabsorbVerifierMock.sol";
import {WithdrawVerifierMock} from "../mocks/WithdrawVerifierMock.sol";
import {MockArbitratorV2} from "../mocks/MockArbitratorV2.sol";
import {KlerosAdapter} from "../src/packages/KlerosAdapter.sol";
import {RelayerMock} from "../mocks/RelayerMock.sol";
import {BaseTest} from "./Base.t.sol";
import {PoseidonSingletons} from "./PoseidonSingletons.sol";

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
    address internal constant SINK = address(0xDEAD);
    // Bond pieces (F3): one note per side funding the split, the lock commitments, the reabsorb.
    uint256 internal constant LOCK = (PRINCIPAL + 9) / 10; // §3.14.5, same curve as the public vault
    bytes32 internal constant DEPOSIT_NOTE_H = bytes32(uint256(0x2001));
    bytes32 internal constant DEPOSIT_NOTE_P = bytes32(uint256(0x2002));
    bytes32 internal constant CHANGE_H = bytes32(uint256(0x2101));
    bytes32 internal constant CHANGE_P = bytes32(uint256(0x2102));
    bytes32 internal constant LOCKCOMMIT_H = bytes32(uint256(0x3101));
    bytes32 internal constant LOCKCOMMIT_P = bytes32(uint256(0x3102));
    bytes32 internal constant NULLBOND_H1 = keccak256("nullbond-h-1");
    bytes32 internal constant NULLBOND_P1 = keccak256("nullbond-p-1");
    bytes32 internal constant REABSORB_NOTE_H = bytes32(uint256(0x2201));
    bytes32 internal constant NULLBOND_H2 = keccak256("nullbond-h-2");

    HumanityVerifierMock internal humanity;
    AccountVerifierMock internal account;
    PreparePassportVerifierMock internal passportProof;
    PrepareAdmitVerifierMock internal admitProof;
    ClaimVerifierMock internal claimProof;
    DepositVerifierMock internal depositProof;
    PrepareBondVerifierMock internal bondProof;
    ReabsorbVerifierMock internal reabsorbProof;
    WithdrawVerifierMock internal withdrawProof;
    RelayerMock internal relayer;
    PoseidonTree internal tree;
    PrivatePassport internal passport;
    PrivateReputation internal reputation;
    PrivateBondVault internal vault;

    HolderAuthorization internal ha;
    ProviderAgreement internal pa;
    PackageMods internal mods;
    bytes32 internal dealId;
    HolderAuthorization internal bondHa;
    ProviderAgreement internal bondPa;
    PackageMods internal bondMods;
    bytes32 internal bondDealId;

    function setUp() public override {
        // The private layer hashes through the pinned poseidon-solidity singletons, which a test
        // EVM starts without (PLURISWAP.md §5.1).
        PoseidonSingletons.install();
        super.setUp();
        humanity = new HumanityVerifierMock();
        account = new AccountVerifierMock();
        passportProof = new PreparePassportVerifierMock();
        admitProof = new PrepareAdmitVerifierMock();
        claimProof = new ClaimVerifierMock();
        depositProof = new DepositVerifierMock();
        bondProof = new PrepareBondVerifierMock();
        reabsorbProof = new ReabsorbVerifierMock();
        withdrawProof = new WithdrawVerifierMock();
        relayer = new RelayerMock();
        // The accounts tree is wired before its owner exists: predict PrivateReputation's address
        // (tree, passport, vault, then reputation itself consume the next four nonces — the vault
        // is deployed between them, so it can hold the predicted reputation for its reabsorb
        // gating while the reputation holds the actual vault for its admit binding). The notes
        // tree needs no prediction: the vault deploys it for itself. The operator is the kernel:
        // reserve/unlock/slash/burn and admit/notifyTerminal must only ever answer the escrow's
        // context.
        address predictedRep = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 3);
        tree = new PoseidonTree(32, DEFAULT_ROOT_HISTORY, predictedRep);
        passport = new PrivatePassport(tree, humanity, passportProof);
        vault = new PrivateBondVault(
            passport,
            IPrivateReputation(predictedRep),
            SINK,
            address(escrow),
            depositProof,
            bondProof,
            reabsorbProof,
            withdrawProof
        );
        reputation = new PrivateReputation(
            passport, tree, account, admitProof, claimProof, FEE_TO, 0, 0, 0, 0, address(escrow), address(vault)
        );
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
        bondHa = _holderAuth(_bondTerms(), 1);
        bondPa = _providerAuth(_bondTerms(), 1);
        bondMods = _bondMods();
        bondDealId = Consent.dealId(escrow.domainSeparator(), _bondTerms(), 1, 1, 0);
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

    function _sorted3(bytes32 a, bytes32 b, bytes32 c) internal pure returns (bytes32[] memory out) {
        if (a > b) (a, b) = (b, a);
        if (b > c) (b, c) = (c, b);
        if (a > b) (a, b) = (b, a);
        out = new bytes32[](3);
        out[0] = a;
        out[1] = b;
        out[2] = c;
    }

    function _sorted4(bytes32 a, bytes32 b, bytes32 c, bytes32 d) internal pure returns (bytes32[] memory out) {
        if (a > b) (a, b) = (b, a);
        if (c > d) (c, d) = (d, c);
        if (a > c) (a, c) = (c, a);
        if (b > d) (b, d) = (d, b);
        if (b > c) (b, c) = (c, b);
        out = new bytes32[](4);
        out[0] = a;
        out[1] = b;
        out[2] = c;
        out[3] = d;
    }

    /// @dev The full private set: PASSPORT + REPUTATION + BONDS (§3.15.6). The bonds id is the
    ///      vault's own (`vault`, `sink`) pair, which is what the kernel's peer check signs.
    function _bondTerms() internal view returns (DealTerms memory t) {
        t = _p2pTerms();
        t.packageIds = _sorted3(
            PackageId.passport(address(passport)),
            PackageId.reputation(address(reputation), FEE_TO, 0, 0, 0, 0),
            PackageId.bonds(address(vault), SINK)
        );
    }

    function _bondMods() internal view returns (PackageMods memory m) {
        m.passport = address(passport);
        m.reputation = address(reputation);
        m.bonds = address(vault);
    }

    function _side(
        address wallet,
        uint256 pk,
        bytes32 subject,
        bytes32 newLeaf,
        bytes32 nullRep,
        bytes32 forDealId,
        uint256 forDeadline
    ) internal view returns (RelayerMock.Side memory s) {
        s.wallet = wallet;
        s.dealSubject = subject;
        s.newLeaf = newLeaf;
        s.nullRep = nullRep;
        s.passportProof = ok(true);
        s.admitProof = ok(true);
        s.passportSig = _sig(address(passport), pk, forDealId, subject, forDeadline);
        s.admitSig = _sig(address(reputation), pk, forDealId, subject, forDeadline);
    }

    /// @dev The bond pieces of one side: the split commitment, its change note, the source note's
    ///      nullifier, and the wallet's consent over the vault's own EIP-712 domain.
    function _bondSide(
        address wallet,
        uint256 pk,
        bytes32 subject,
        bytes32 newLeaf,
        bytes32 nullRep,
        bytes32 lockCommit,
        bytes32 changeNote,
        bytes32 nullBond,
        bytes32 forDealId,
        uint256 forDeadline
    ) internal view returns (RelayerMock.Side memory s) {
        s = _side(wallet, pk, subject, newLeaf, nullRep, forDealId, forDeadline);
        s.lockCommit = lockCommit;
        s.changeNote = changeNote;
        s.nullBond = nullBond;
        s.bondProof = ok(true);
        s.bondSig = _sig(address(vault), pk, forDealId, subject, forDeadline);
    }

    /// @dev Each side funds one whole note; the split carves the lock out of it in the bundle. The
    ///      holder is re-funded because the deposit would otherwise eat the balance the kernel
    ///      pulls as principal at `activate`.
    function _fundBonds() internal {
        token.mint(holder, PRINCIPAL);
        token.mint(provider, PRINCIPAL);
        vm.prank(holder);
        token.approve(address(vault), type(uint256).max);
        vm.prank(provider);
        token.approve(address(vault), type(uint256).max);
        vm.prank(holder);
        vault.deposit(address(token), PRINCIPAL, DEPOSIT_NOTE_H, ok(true));
        vm.prank(provider);
        vault.deposit(address(token), PRINCIPAL, DEPOSIT_NOTE_P, ok(true));
    }

    /// @dev The activation bundle of the bonded deal: six prepares (passport, vault, reputation,
    ///      per side — §3.15.4's composition order) and `activate` in one tx.
    function _activateBonded() internal returns (bytes32) {
        _fundBonds();
        ControllerAcceptance memory ca;
        bytes memory hs = _signHolder(bondHa);
        bytes memory ps = _signProvider(bondPa);
        RelayerMock.Side memory sideH = _bondSide(
            holder,
            holderPk,
            SUBJECT_H,
            ADMIT_LEAF_H,
            NULLREP_H1,
            LOCKCOMMIT_H,
            CHANGE_H,
            NULLBOND_H1,
            bondDealId,
            bondHa.deadline
        );
        RelayerMock.Side memory sideP = _bondSide(
            provider,
            providerPk,
            SUBJECT_P,
            ADMIT_LEAF_P,
            NULLREP_P1,
            LOCKCOMMIT_P,
            CHANGE_P,
            NULLBOND_P1,
            bondDealId,
            bondHa.deadline
        );
        return relayer.activatePrivate(
            escrow, passport, reputation, vault, bondHa, hs, bondPa, ps, ca, "", bondMods, bondDealId, sideH, sideP
        );
    }

    /// @dev The activation bundle: four prepares and `activate` in one tx (PLURISWAP.md §3.15.4).
    ///      All argument evaluation is hoisted so no expectation or prank leaks into it.
    function _activate() internal returns (bytes32) {
        ControllerAcceptance memory ca;
        bytes memory hs = _signHolder(ha);
        bytes memory ps = _signProvider(pa);
        RelayerMock.Side memory sideH =
            _side(holder, holderPk, SUBJECT_H, ADMIT_LEAF_H, NULLREP_H1, dealId, ha.deadline);
        RelayerMock.Side memory sideP =
            _side(provider, providerPk, SUBJECT_P, ADMIT_LEAF_P, NULLREP_P1, dealId, ha.deadline);
        return relayer.activatePrivate(
            escrow,
            passport,
            reputation,
            PrivateBondVault(address(0)), // a PASSPORT+REPUTATION deal: no bond pieces
            ha,
            hs,
            pa,
            ps,
            ca,
            "",
            mods,
            dealId,
            sideH,
            sideP
        );
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
        RelayerMock.Side memory sideH =
            _side(holder, holderPk, SUBJECT_H, ADMIT_LEAF_H, NULLREP_H1, dealId, ha.deadline);
        RelayerMock.Side memory sideP =
            _side(provider, providerPk, SUBJECT_P, ADMIT_LEAF_P, NULLREP_P1, dealId, ha.deadline);
        vm.expectRevert(Escrow.InvalidProviderSignature.selector);
        relayer.activatePrivate(
            escrow,
            passport,
            reputation,
            PrivateBondVault(address(0)),
            ha,
            hs,
            pa,
            providerSig,
            ca,
            "",
            mods,
            dealId,
            sideH,
            sideP
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

    // ---------------------------------------------------------------- bonds deal (F3, §3.15.6)

    function test_admit_acceptsTheBoundVault() public {
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
        vm.prank(address(escrow));
        bytes32 subject = reputation.admit(holder, address(token), PRINCIPAL, address(vault));
        assertEq(subject, SUBJECT_H, "the bound vault is the one vault this reputation admits");
    }

    function test_admit_rejectsForeignVault() public {
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
        // A counterparty signs a BONDS deal trusting that the lock exists: a foreign vault under
        // the same reputation would fake that protection, so the binding refuses it.
        vm.prank(address(escrow));
        vm.expectRevert(PrivateReputation.UnsupportedVault.selector);
        reputation.admit(holder, address(token), PRINCIPAL, address(0xB0B));
    }

    function test_bondDeal_fullBundle() public {
        bytes32 id = _activateBonded();

        assertEq(id, bondDealId);
        assertTrue(uint8(escrow.status(bondDealId)) == uint8(Status.FUNDED));
        // Both lock records: the §3.14.5 lock each, with the split commitments inside.
        (address lockTokenH, uint256 lockAmountH, bytes32 lockCommitH, bool releasedH) =
            vault.lockOf(bondDealId, SUBJECT_H);
        assertEq(lockTokenH, address(token));
        assertEq(lockAmountH, LOCK);
        assertEq(lockCommitH, LOCKCOMMIT_H);
        assertFalse(releasedH);
        (, uint256 lockAmountP, bytes32 lockCommitP,) = vault.lockOf(bondDealId, SUBJECT_P);
        assertEq(lockAmountP, LOCK);
        assertEq(lockCommitP, LOCKCOMMIT_P);
        // The bond buffers are consumed; the notes tree holds both deposits and both change notes.
        (address bufferedToken,, bytes32 bufferedCommit) = vault.preparedBond(bondDealId, SUBJECT_H);
        assertEq(bufferedToken, address(0));
        assertEq(bufferedCommit, 0);
        assertEq(vault.notesTree().nextIndex(), 4);
        assertTrue(vault.notesTree().isSpent(NULLBOND_H1));
        assertTrue(vault.notesTree().isSpent(NULLBOND_P1));
    }

    function test_bondDeal_bundleIsAtomic() public {
        _fundBonds();
        ControllerAcceptance memory ca;
        bytes memory hs = _signHolder(bondHa);
        bytes memory ps = _signProvider(bondPa);
        ps[10] = ps[10] ^ 0x01; // break the deal consent, AFTER the prepares would have run
        RelayerMock.Side memory sideH = _bondSide(
            holder,
            holderPk,
            SUBJECT_H,
            ADMIT_LEAF_H,
            NULLREP_H1,
            LOCKCOMMIT_H,
            CHANGE_H,
            NULLBOND_H1,
            bondDealId,
            bondHa.deadline
        );
        RelayerMock.Side memory sideP = _bondSide(
            provider,
            providerPk,
            SUBJECT_P,
            ADMIT_LEAF_P,
            NULLREP_P1,
            LOCKCOMMIT_P,
            CHANGE_P,
            NULLBOND_P1,
            bondDealId,
            bondHa.deadline
        );
        vm.expectRevert(Escrow.InvalidProviderSignature.selector);
        relayer.activatePrivate(
            escrow, passport, reputation, vault, bondHa, hs, bondPa, ps, ca, "", bondMods, bondDealId, sideH, sideP
        );
        // The deposits predate the bundle and survive it; the splits did not land.
        assertEq(vault.notesTree().nextIndex(), 2);
        assertFalse(vault.notesTree().isSpent(NULLBOND_H1));
        assertFalse(vault.notesTree().isSpent(NULLBOND_P1));
        (address bufferedToken,, bytes32 bufferedCommit) = vault.preparedBond(bondDealId, SUBJECT_H);
        assertEq(bufferedToken, address(0));
        assertEq(bufferedCommit, 0);
        (, uint256 lockAmountH,,) = vault.lockOf(bondDealId, SUBJECT_H);
        assertEq(lockAmountH, 0);
        assertTrue(uint8(escrow.status(bondDealId)) == uint8(Status.NONE));
    }

    function test_bondDeal_peacefulThenClaimThenReabsorb() public {
        _activateBonded();
        _markFiat(bondDealId);
        vm.prank(holder); // the controller releases after fiat was marked
        escrow.release(bondDealId);
        assertEq(escrow.postPending(bondDealId), 0, "notifications and unlocks all landed");

        (,, bytes32 lockCommitH, bool releasedH) = vault.lockOf(bondDealId, SUBJECT_H);
        assertTrue(releasedH, "kernel unlock did not release the holder lock");
        assertEq(lockCommitH, LOCKCOMMIT_H);
        // Gating: the lock does not come back before the terminal delta is claimed.
        vm.expectRevert(PrivateBondVault.ClaimRequired.selector);
        vault.reabsorb(bondDealId, SUBJECT_H, REABSORB_NOTE_H, NULLBOND_H2, ok(true));

        // Claim the delta, then the lock merges into a fresh note — exactly once.
        reputation.claim(bondDealId, SUBJECT_H, CLAIM_LEAF_H, NULLREP_H2, tree.root(), ok(true));
        uint256 notesBefore = vault.notesTree().nextIndex();
        vault.reabsorb(bondDealId, SUBJECT_H, REABSORB_NOTE_H, NULLBOND_H2, ok(true));
        assertEq(vault.notesTree().nextIndex(), notesBefore + 1, "reabsorb did not merge a note");
        assertTrue(vault.notesTree().isSpent(NULLBOND_H2));
        (, uint256 lockAmountH,,) = vault.lockOf(bondDealId, SUBJECT_H);
        assertEq(lockAmountH, 0, "reabsorbed lock still on the books");
        vm.expectRevert(PrivateBondVault.NoLock.selector);
        vault.reabsorb(bondDealId, SUBJECT_H, REABSORB_NOTE_H, NULLBOND_H2, ok(true));

        // The provider side is still gated: no claim, no reabsorb.
        vm.expectRevert(PrivateBondVault.ClaimRequired.selector);
        vault.reabsorb(bondDealId, SUBJECT_P, bytes32(uint256(0x2202)), keccak256("nullbond-p-2"), ok(true));
    }

    function test_bondDeal_stalemateBurnsBothLocks() public {
        _activateBonded();
        _markFiat(bondDealId);
        _openDisputed(bondDealId);
        vm.warp(block.timestamp + 7200 + 1); // disputeDuration of the p2p terms
        escrow.forceStalemate(bondDealId);

        assertTrue(uint8(escrow.status(bondDealId)) == uint8(Status.STALEMATE));
        assertEq(escrow.postPending(bondDealId), 0);
        assertEq(token.balanceOf(SINK), LOCK * 2, "both locks burned to the sink, nothing to the sides");
        (, uint256 lockAmountH,,) = vault.lockOf(bondDealId, SUBJECT_H);
        assertEq(lockAmountH, 0);
        (, uint256 lockAmountP,,) = vault.lockOf(bondDealId, SUBJECT_P);
        assertEq(lockAmountP, 0);
        // A burned lock is never reabsorbable.
        vm.expectRevert(PrivateBondVault.NoLock.selector);
        vault.reabsorb(bondDealId, SUBJECT_H, REABSORB_NOTE_H, NULLBOND_H2, ok(true));
    }

    /// @dev The last kernel verb the private vault had never answered under fire: `slash`, driven
    ///      by a real ruling. The KlerosAdapter is the production court; only the arbitrator under
    ///      it is the mock. Ruling 1 = HolderWins: the kernel slashes (subjectP, subjectH, ...,
    ///      t.holder) — the provider's lock to the holder's signing address, the holder's own lock
    ///      released for a claim-gated reabsorb.
    function test_bondDeal_ruledSlashThroughCourt() public {
        MockArbitratorV2 arbitrator = new MockArbitratorV2(0.01 ether);
        KlerosAdapter court = new KlerosAdapter(
            address(arbitrator), abi.encode(uint256(1), uint256(3), uint256(1)), 0, "", address(escrow), address(0), ""
        );
        vm.deal(holder, 1 ether);

        // The bonded deal, now with arbitration: four sorted ids and a ruling clock.
        DealTerms memory t = _bondTerms();
        t.packageIds = _sorted4(
            PackageId.passport(address(passport)),
            PackageId.reputation(address(reputation), FEE_TO, 0, 0, 0, 0),
            PackageId.bonds(address(vault), SINK),
            court.packageId()
        );
        t.arbitrationDuration = 1 days;
        HolderAuthorization memory courtHa = _holderAuth(t, 1);
        ProviderAgreement memory courtPa = _providerAuth(t, 1);
        PackageMods memory courtMods = _bondMods();
        courtMods.court = address(court);
        bytes32 courtDealId = Consent.dealId(escrow.domainSeparator(), t, 1, 1, 0);

        _fundBonds();
        ControllerAcceptance memory ca;
        bytes memory hs = _signHolder(courtHa);
        bytes memory ps = _signProvider(courtPa);
        RelayerMock.Side memory sideH = _bondSide(
            holder,
            holderPk,
            SUBJECT_H,
            ADMIT_LEAF_H,
            NULLREP_H1,
            LOCKCOMMIT_H,
            CHANGE_H,
            NULLBOND_H1,
            courtDealId,
            courtHa.deadline
        );
        RelayerMock.Side memory sideP = _bondSide(
            provider,
            providerPk,
            SUBJECT_P,
            ADMIT_LEAF_P,
            NULLREP_P1,
            LOCKCOMMIT_P,
            CHANGE_P,
            NULLBOND_P1,
            courtDealId,
            courtPa.deadline
        );
        bytes32 id = relayer.activatePrivate(
            escrow, passport, reputation, vault, courtHa, hs, courtPa, ps, ca, "", courtMods, courtDealId, sideH, sideP
        );
        assertEq(id, courtDealId);

        _markFiat(courtDealId);
        vm.prank(holder);
        escrow.openCourt{value: 0.01 ether}(courtDealId);
        assertTrue(uint8(escrow.status(courtDealId)) == uint8(Status.ARBITRATION_ACTIVE));
        arbitrator.giveRuling(court.disputeOf(courtDealId), 1); // the court rules for the holder
        escrow.readRuling(courtDealId);

        assertTrue(uint8(escrow.status(courtDealId)) == uint8(Status.RESOLVED_BY_ARBITRATION));
        assertEq(escrow.postPending(courtDealId), 0, "notifications and the slash all landed");
        // Principal refund + the provider's lock, both to the holder's signing address.
        assertEq(token.balanceOf(holder), PRINCIPAL + LOCK);
        assertEq(token.balanceOf(provider), 0);
        // The loser's record is consumed; the winner's own lock is released, not taken.
        (, uint256 loserAmount,,) = vault.lockOf(courtDealId, SUBJECT_P);
        assertEq(loserAmount, 0, "the loser's lock was not consumed");
        (,, bytes32 winnerCommit, bool winnerReleased) = vault.lockOf(courtDealId, SUBJECT_H);
        assertTrue(winnerReleased, "the winner's own lock was not released");
        assertEq(winnerCommit, LOCKCOMMIT_H);
        // Both terminal deltas pended: ArbWin for the holder, ArbLoss for the provider.
        (IReputation.Close kindH,,) = reputation.pending(SUBJECT_H);
        assertTrue(kindH == IReputation.Close.ArbWin);
        (IReputation.Close kindP,,) = reputation.pending(SUBJECT_P);
        assertTrue(kindP == IReputation.Close.ArbLoss);
        // The winner still gates on the claim: ruling is not completion.
        vm.expectRevert(PrivateBondVault.ClaimRequired.selector);
        vault.reabsorb(courtDealId, SUBJECT_H, REABSORB_NOTE_H, NULLBOND_H2, ok(true));
        reputation.claim(courtDealId, SUBJECT_H, CLAIM_LEAF_H, NULLREP_H2, tree.root(), ok(true));
        vault.reabsorb(courtDealId, SUBJECT_H, REABSORB_NOTE_H, NULLBOND_H2, ok(true));
        (, uint256 winnerAmount,,) = vault.lockOf(courtDealId, SUBJECT_H);
        assertEq(winnerAmount, 0, "the winner's reabsorb did not clear the record");
        // The loser never reabsorbs: the record is gone.
        vm.expectRevert(PrivateBondVault.NoLock.selector);
        vault.reabsorb(courtDealId, SUBJECT_P, bytes32(uint256(0x2202)), keccak256("nullbond-p-2"), ok(true));
    }
}
