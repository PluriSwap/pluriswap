// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {TestToken} from "../mocks/TestToken.sol";
import {HumanityVerifierMock} from "../mocks/HumanityVerifierMock.sol";
import {AccountVerifierMock} from "../mocks/AccountVerifierMock.sol";
import {PreparePassportVerifierMock} from "../mocks/PreparePassportVerifierMock.sol";
import {PrepareAdmitVerifierMock} from "../mocks/PrepareAdmitVerifierMock.sol";
import {ClaimVerifierMock} from "../mocks/ClaimVerifierMock.sol";
import {DepositVerifierMock} from "../mocks/DepositVerifierMock.sol";
import {PrepareBondVerifierMock} from "../mocks/PrepareBondVerifierMock.sol";
import {ReabsorbVerifierMock} from "../mocks/ReabsorbVerifierMock.sol";
import {WithdrawVerifierMock} from "../mocks/WithdrawVerifierMock.sol";
import {PackageId} from "../src/libraries/PackageId.sol";
import {IPassport} from "../src/packages/interfaces/IPassport.sol";
import {IPrivateReputation} from "../src/packages/interfaces/IPrivateReputation.sol";
import {IDepositVerifier} from "../src/packages/interfaces/IDepositVerifier.sol";
import {IPrepareBondVerifier} from "../src/packages/interfaces/IPrepareBondVerifier.sol";
import {IReabsorbVerifier} from "../src/packages/interfaces/IReabsorbVerifier.sol";
import {IWithdrawVerifier} from "../src/packages/interfaces/IWithdrawVerifier.sol";
import {PoseidonTree} from "../src/packages/PoseidonTree.sol";
import {PrivateBondVault} from "../src/packages/PrivateBondVault.sol";

/// @dev A passport whose decoder is dead: `identify` always reverts, like a passport whose
///      third-party proxy went down. The vault holds it as its peer, and every deposit, prepare,
///      reabsorb and withdraw below still works — the proof replaces the identification
///      (PLURISWAP.md §3.15.6), so the vault has no liveness dependency on any decoder.
contract DeadPassportMock is IPassport {
    function identify(address) external pure returns (bytes32) {
        revert NoPassport();
    }

    function packageId() external pure returns (bytes32) {
        return keccak256("dead-passport");
    }
}

/// @dev Stand-in for `PrivateReputation.claimed`: the vault's reabsorb gating, flippable by hand.
contract GatingMock is IPrivateReputation {
    mapping(bytes32 => bool) public claimed;

    function setClaimed(bytes32 subject) external {
        claimed[subject] = true;
    }
}

/// @title Private vault tests (F3, PLURISWAP.md §3.15.6)
/// @dev Notes in, locks out, everything fail-closed. The mock verifiers decode the proof as a
///      bool: a passing mock is not privacy, and nothing here claims it is.
///
///      Test hygiene: every external call that feeds a reverting call (roots, signatures, sides)
///      is hoisted to a local BEFORE `vm.expectRevert` — the expectation is consumed by the next
///      call, whatever it is.
contract PrivateVaultTest is Test {
    bytes32 internal constant PREPARE_TYPEHASH =
        keccak256("PrivatePrepare(bytes32 dealId,bytes32 dealSubject,address module,uint256 deadline)");

    uint256 internal constant PRINCIPAL = 1_000_000;
    uint256 internal constant LOCK = (PRINCIPAL + 9) / 10; // §3.14.5, same curve as the public vault
    bytes32 internal constant DEAL_ID = keccak256("deal-1");
    bytes32 internal constant SUBJECT_H = bytes32(uint256(0x51));
    bytes32 internal constant SUBJECT_P = bytes32(uint256(0x52));
    bytes32 internal constant NOTE_H = bytes32(uint256(0x2001));
    bytes32 internal constant NOTE_P = bytes32(uint256(0x2002));
    bytes32 internal constant CHANGE_H = bytes32(uint256(0x2101));
    bytes32 internal constant CHANGE_P = bytes32(uint256(0x2102));
    bytes32 internal constant CHANGE_H2 = bytes32(uint256(0x2111));
    bytes32 internal constant LOCKCOMMIT_H = bytes32(uint256(0x3101));
    bytes32 internal constant LOCKCOMMIT_P = bytes32(uint256(0x3102));
    bytes32 internal constant LOCKCOMMIT_H2 = bytes32(uint256(0x3111));
    bytes32 internal constant NULLBOND_H1 = keccak256("nullbond-h-1");
    bytes32 internal constant NULLBOND_P1 = keccak256("nullbond-p-1");
    bytes32 internal constant NULLBOND_H2 = keccak256("nullbond-h-2");
    bytes32 internal constant REABSORB_NOTE_H = bytes32(uint256(0x2201));
    bytes32 internal constant WITHDRAW_NOTE = bytes32(uint256(0x2301));
    bytes32 internal constant FAKE_ROOT = keccak256("fake-root");
    address internal constant SINK = address(0xDEAD);
    address internal constant DEST = address(0x0DD);

    uint256 internal holderPk = 0xA11CE;
    uint256 internal providerPk = 0xB0B;
    address internal holder;
    address internal provider;

    TestToken internal token;
    DeadPassportMock internal deadPassport;
    GatingMock internal gating;
    DepositVerifierMock internal depositProof;
    PrepareBondVerifierMock internal bondProof;
    ReabsorbVerifierMock internal reabsorbProof;
    WithdrawVerifierMock internal withdrawProof;
    PrivateBondVault internal vault;
    uint256 internal deadline;

    function setUp() public {
        holder = vm.addr(holderPk);
        provider = vm.addr(providerPk);
        deadline = block.timestamp + 1 hours;

        token = new TestToken();
        deadPassport = new DeadPassportMock();
        gating = new GatingMock();
        depositProof = new DepositVerifierMock();
        bondProof = new PrepareBondVerifierMock();
        reabsorbProof = new ReabsorbVerifierMock();
        withdrawProof = new WithdrawVerifierMock();
        // The test contract is the operator, so reserve/unlock/slash/burn are direct calls; the
        // kernel's context is exercised end-to-end in PrivateDeal.t.sol.
        vault = new PrivateBondVault(
            deadPassport, gating, SINK, address(this), depositProof, bondProof, reabsorbProof, withdrawProof
        );
        // Generously funded: several tests split more than one whole note per side.
        token.mint(holder, PRINCIPAL * 100);
        vm.prank(holder);
        token.approve(address(vault), type(uint256).max);
    }

    function ok(bool pass) internal pure returns (bytes memory) {
        return abi.encode(pass);
    }

    /// @dev The standard EIP-712 domain of the private modules ("PluriSwap", "1", own address):
    ///      building it here also pins that the vault uses the standard construction.
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

    function _deposit(address from, uint256 amount, bytes32 note) internal {
        vm.prank(from);
        vault.deposit(address(token), amount, note, ok(true));
    }

    function _prepareBond(bytes32 dealId_, bytes32 subject, bytes32 lockCommit, bytes32 changeNote, bytes32 nullBond)
        internal
    {
        address wallet = subject == SUBJECT_H ? holder : provider;
        uint256 pk = subject == SUBJECT_H ? holderPk : providerPk;
        vault.prepare(
            wallet,
            dealId_,
            subject,
            address(token),
            LOCK,
            lockCommit,
            changeNote,
            nullBond,
            vault.bondRoot(),
            deadline,
            ok(true),
            _sig(address(vault), pk, dealId_, subject, deadline)
        );
    }

    /// @dev Both sides funded, split, and locked: the state every kernel terminal starts from.
    function _lockBoth(bytes32 dealId_) internal {
        token.mint(provider, PRINCIPAL);
        vm.prank(provider);
        token.approve(address(vault), type(uint256).max);
        _deposit(holder, PRINCIPAL, NOTE_H);
        _deposit(provider, PRINCIPAL, NOTE_P);
        _prepareBond(dealId_, SUBJECT_H, LOCKCOMMIT_H, CHANGE_H, NULLBOND_H1);
        _prepareBond(dealId_, SUBJECT_P, LOCKCOMMIT_P, CHANGE_P, NULLBOND_P1);
        vault.reserve(SUBJECT_H, address(token), dealId_, PRINCIPAL);
        vault.reserve(SUBJECT_P, address(token), dealId_, PRINCIPAL);
    }

    // ---------------------------------------------------------------- constructor

    function test_constructor_wiresPeersAndNotesTree() public view {
        assertEq(vault.packageId(), PackageId.bonds(address(vault), SINK));
        assertEq(address(vault.passport()), address(deadPassport));
        assertEq(address(vault.reputation()), address(gating));
        assertEq(vault.sink(), SINK);
        assertEq(vault.notesTree().depth(), 20, "notes tree is depth 20 (3.15.3)");
        assertEq(vault.bondRoot(), vault.notesTree().root());
        assertTrue(vault.notesTree().isKnownRoot(vault.bondRoot()), "empty root seeded into the ring");
    }

    function test_constructor_rejectsZeroAddresses() public {
        vm.expectRevert(PrivateBondVault.ZeroAddress.selector);
        new PrivateBondVault(
            IPassport(address(0)), gating, SINK, address(this), depositProof, bondProof, reabsorbProof, withdrawProof
        );
        vm.expectRevert(PrivateBondVault.ZeroAddress.selector);
        new PrivateBondVault(
            deadPassport,
            IPrivateReputation(address(0)),
            SINK,
            address(this),
            depositProof,
            bondProof,
            reabsorbProof,
            withdrawProof
        );
        vm.expectRevert(PrivateBondVault.ZeroAddress.selector);
        new PrivateBondVault(
            deadPassport, gating, address(0), address(this), depositProof, bondProof, reabsorbProof, withdrawProof
        );
        vm.expectRevert(PrivateBondVault.ZeroAddress.selector);
        new PrivateBondVault(
            deadPassport, gating, SINK, address(0), depositProof, bondProof, reabsorbProof, withdrawProof
        );
        vm.expectRevert(PrivateBondVault.ZeroAddress.selector);
        new PrivateBondVault(
            deadPassport,
            gating,
            SINK,
            address(this),
            IDepositVerifier(address(0)),
            bondProof,
            reabsorbProof,
            withdrawProof
        );
        vm.expectRevert(PrivateBondVault.ZeroAddress.selector);
        new PrivateBondVault(
            deadPassport,
            gating,
            SINK,
            address(this),
            depositProof,
            IPrepareBondVerifier(address(0)),
            reabsorbProof,
            withdrawProof
        );
        vm.expectRevert(PrivateBondVault.ZeroAddress.selector);
        new PrivateBondVault(
            deadPassport,
            gating,
            SINK,
            address(this),
            depositProof,
            bondProof,
            IReabsorbVerifier(address(0)),
            withdrawProof
        );
        vm.expectRevert(PrivateBondVault.ZeroAddress.selector);
        new PrivateBondVault(
            deadPassport,
            gating,
            SINK,
            address(this),
            depositProof,
            bondProof,
            reabsorbProof,
            IWithdrawVerifier(address(0))
        );
    }

    // ---------------------------------------------------------------- deposit

    function test_deposit_pullsAndInsertsNote() public {
        vm.expectEmit(true, true, true, true, address(vault));
        emit PrivateBondVault.Deposited(address(token), holder, PRINCIPAL);
        vm.prank(holder); // the wallet and the amount are public exactly as in the public vault
        vault.deposit(address(token), PRINCIPAL, NOTE_H, ok(true));
        assertEq(token.balanceOf(address(vault)), PRINCIPAL);
        assertEq(token.balanceOf(holder), PRINCIPAL * 100 - PRINCIPAL);
        assertEq(vault.notesTree().nextIndex(), 1, "the note's owner is the only thing not public");
    }

    function test_deposit_badProofIsAtomic() public {
        vm.prank(holder);
        vm.expectRevert(PrivateBondVault.DepositProofFailed.selector);
        vault.deposit(address(token), PRINCIPAL, NOTE_H, ok(false));
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(token.balanceOf(holder), PRINCIPAL * 100);
        assertEq(vault.notesTree().nextIndex(), 0);
    }

    function test_deposit_zeroAmount() public {
        vm.prank(holder);
        vm.expectRevert(PrivateBondVault.ZeroAmount.selector);
        vault.deposit(address(token), 0, NOTE_H, ok(true));
    }

    // ---------------------------------------------------------------- prepare (bond split)

    function test_bondPrepare_splitsAndBuffers() public {
        _deposit(holder, PRINCIPAL, NOTE_H);
        vm.expectEmit(true, true, true, true, address(vault));
        emit PrivateBondVault.BondPrepared(DEAL_ID, SUBJECT_H, LOCKCOMMIT_H, LOCK, CHANGE_H);
        _prepareBond(DEAL_ID, SUBJECT_H, LOCKCOMMIT_H, CHANGE_H, NULLBOND_H1);
        // The source note is dead, the change note lives, the buffer waits for `reserve`.
        assertTrue(vault.notesTree().isSpent(NULLBOND_H1));
        assertEq(vault.notesTree().nextIndex(), 2);
        (address bufferedToken, uint256 bufferedLock, bytes32 bufferedCommit) = vault.preparedBond(DEAL_ID, SUBJECT_H);
        assertEq(bufferedToken, address(token));
        assertEq(bufferedLock, LOCK);
        assertEq(bufferedCommit, LOCKCOMMIT_H);
    }

    function test_bondPrepare_badProofIsAtomic() public {
        _deposit(holder, PRINCIPAL, NOTE_H);
        bytes32 root = vault.bondRoot();
        bytes memory sig = _sig(address(vault), holderPk, DEAL_ID, SUBJECT_H, deadline);
        vm.expectRevert(PrivateBondVault.BondProofFailed.selector);
        vault.prepare(
            holder,
            DEAL_ID,
            SUBJECT_H,
            address(token),
            LOCK,
            LOCKCOMMIT_H,
            CHANGE_H,
            NULLBOND_H1,
            root,
            deadline,
            ok(false),
            sig
        );
        assertFalse(vault.notesTree().isSpent(NULLBOND_H1));
        assertEq(vault.notesTree().nextIndex(), 1);
        (address bufferedToken,, bytes32 bufferedCommit) = vault.preparedBond(DEAL_ID, SUBJECT_H);
        assertEq(bufferedToken, address(0));
        assertEq(bufferedCommit, 0);
    }

    function test_bondPrepare_unknownRoot() public {
        _deposit(holder, PRINCIPAL, NOTE_H);
        bytes memory sig = _sig(address(vault), holderPk, DEAL_ID, SUBJECT_H, deadline);
        vm.expectRevert(PrivateBondVault.UnknownRoot.selector);
        vault.prepare(
            holder,
            DEAL_ID,
            SUBJECT_H,
            address(token),
            LOCK,
            LOCKCOMMIT_H,
            CHANGE_H,
            NULLBOND_H1,
            FAKE_ROOT,
            deadline,
            ok(true),
            sig
        );
    }

    function test_bondPrepare_expired() public {
        _deposit(holder, PRINCIPAL, NOTE_H);
        vm.warp(deadline + 1);
        bytes32 root = vault.bondRoot();
        bytes memory sig = _sig(address(vault), holderPk, DEAL_ID, SUBJECT_H, deadline);
        vm.expectRevert(PrivateBondVault.PrepareExpired.selector);
        vault.prepare(
            holder,
            DEAL_ID,
            SUBJECT_H,
            address(token),
            LOCK,
            LOCKCOMMIT_H,
            CHANGE_H,
            NULLBOND_H1,
            root,
            deadline,
            ok(true),
            sig
        );
    }

    function test_bondPrepare_wrongWalletKey() public {
        _deposit(holder, PRINCIPAL, NOTE_H);
        bytes32 root = vault.bondRoot();
        bytes memory sig = _sig(address(vault), providerPk, DEAL_ID, SUBJECT_H, deadline);
        vm.expectRevert(PrivateBondVault.InvalidWalletSignature.selector);
        vault.prepare(
            holder,
            DEAL_ID,
            SUBJECT_H,
            address(token),
            LOCK,
            LOCKCOMMIT_H,
            CHANGE_H,
            NULLBOND_H1,
            root,
            deadline,
            ok(true),
            sig
        );
        assertFalse(vault.notesTree().isSpent(NULLBOND_H1));
    }

    function test_bondPrepare_latestWins() public {
        _deposit(holder, PRINCIPAL, NOTE_H);
        _deposit(holder, PRINCIPAL, NOTE_P); // a second note to split
        _prepareBond(DEAL_ID, SUBJECT_H, LOCKCOMMIT_H, CHANGE_H, NULLBOND_H1);
        _prepareBond(DEAL_ID, SUBJECT_H, LOCKCOMMIT_H2, CHANGE_H2, NULLBOND_H2);
        (, uint256 bufferedLock, bytes32 bufferedCommit) = vault.preparedBond(DEAL_ID, SUBJECT_H);
        assertEq(bufferedLock, LOCK);
        assertEq(bufferedCommit, LOCKCOMMIT_H2, "latest wallet-signed split wins");
        assertTrue(vault.notesTree().isSpent(NULLBOND_H1));
        assertTrue(vault.notesTree().isSpent(NULLBOND_H2));
        assertEq(vault.notesTree().nextIndex(), 4, "both change notes live; the orphaned lock value is stranded");
    }

    // ---------------------------------------------------------------- reserve (kernel)

    function test_reserve_consumesPrepareAndWritesLock() public {
        _deposit(holder, PRINCIPAL, NOTE_H);
        _prepareBond(DEAL_ID, SUBJECT_H, LOCKCOMMIT_H, CHANGE_H, NULLBOND_H1);
        vm.expectEmit(true, true, true, true, address(vault));
        emit PrivateBondVault.Reserved(DEAL_ID, SUBJECT_H, address(token), LOCK);
        vault.reserve(SUBJECT_H, address(token), DEAL_ID, PRINCIPAL);
        (address lockToken, uint256 lockAmount, bytes32 lockCommit, bool released) = vault.lockOf(DEAL_ID, SUBJECT_H);
        assertEq(lockToken, address(token));
        assertEq(lockAmount, LOCK);
        assertEq(lockCommit, LOCKCOMMIT_H);
        assertFalse(released);
        (address bufferedToken,, bytes32 bufferedCommit) = vault.preparedBond(DEAL_ID, SUBJECT_H);
        assertEq(bufferedToken, address(0));
        assertEq(bufferedCommit, 0, "reserve consumed the buffer");
    }

    function test_reserve_withoutPrepareFailsClosed() public {
        _deposit(holder, PRINCIPAL, NOTE_H); // funded, but never split for this deal
        vm.expectRevert(PrivateBondVault.NoPrepare.selector);
        vault.reserve(SUBJECT_H, address(token), DEAL_ID, PRINCIPAL);
        (, uint256 lockAmount,,) = vault.lockOf(DEAL_ID, SUBJECT_H);
        assertEq(lockAmount, 0);
    }

    function test_reserve_mismatchedTokenOrLock() public {
        _deposit(holder, PRINCIPAL, NOTE_H);
        _deposit(holder, PRINCIPAL, NOTE_P);
        _prepareBond(DEAL_ID, SUBJECT_H, LOCKCOMMIT_H, CHANGE_H, NULLBOND_H1);
        TestToken otherToken = new TestToken();
        vm.expectRevert(PrivateBondVault.PrepareMismatch.selector);
        vault.reserve(SUBJECT_H, address(otherToken), DEAL_ID, PRINCIPAL);
        // A split proven for a lock that is not §3.14.5's: the vault must not write it, or a
        // slash would pay out more than the split ever covered.
        address wallet = holder;
        uint256 pk = holderPk;
        bytes32 root = vault.bondRoot();
        bytes memory sig = _sig(address(vault), pk, DEAL_ID, SUBJECT_H, deadline);
        vault.prepare(
            wallet,
            DEAL_ID,
            SUBJECT_H,
            address(token),
            LOCK + 1, // not the §3.14.5 lock of this principal
            LOCKCOMMIT_H2,
            CHANGE_H2,
            NULLBOND_H2,
            root,
            deadline,
            ok(true),
            sig
        );
        vm.expectRevert(PrivateBondVault.PrepareMismatch.selector);
        vault.reserve(SUBJECT_H, address(token), DEAL_ID, PRINCIPAL);
        (, uint256 lockAmount,,) = vault.lockOf(DEAL_ID, SUBJECT_H);
        assertEq(lockAmount, 0, "no lock was written for either mismatch");
    }

    function test_reserve_principalZero() public {
        _deposit(holder, PRINCIPAL, NOTE_H);
        _prepareBond(DEAL_ID, SUBJECT_H, LOCKCOMMIT_H, CHANGE_H, NULLBOND_H1);
        vm.expectRevert(PrivateBondVault.LockTooSmall.selector);
        vault.reserve(SUBJECT_H, address(token), DEAL_ID, 0);
    }

    function test_reserve_doubleReserve() public {
        _deposit(holder, PRINCIPAL, NOTE_H);
        _deposit(holder, PRINCIPAL, NOTE_P);
        _prepareBond(DEAL_ID, SUBJECT_H, LOCKCOMMIT_H, CHANGE_H, NULLBOND_H1);
        vault.reserve(SUBJECT_H, address(token), DEAL_ID, PRINCIPAL);
        _prepareBond(DEAL_ID, SUBJECT_H, LOCKCOMMIT_H2, CHANGE_H2, NULLBOND_H2);
        vm.expectRevert(PrivateBondVault.LockExists.selector);
        vault.reserve(SUBJECT_H, address(token), DEAL_ID, PRINCIPAL);
    }

    function test_reserve_onlyOperator() public {
        _deposit(holder, PRINCIPAL, NOTE_H);
        _prepareBond(DEAL_ID, SUBJECT_H, LOCKCOMMIT_H, CHANGE_H, NULLBOND_H1);
        vm.prank(address(0xB0B));
        vm.expectRevert(PrivateBondVault.Unauthorized.selector);
        vault.reserve(SUBJECT_H, address(token), DEAL_ID, PRINCIPAL);
    }

    // ---------------------------------------------------------------- unlock (kernel)

    function test_unlock_marksReleased() public {
        _lockBoth(DEAL_ID);
        vm.expectEmit(true, true, true, true, address(vault));
        emit PrivateBondVault.Unlocked(DEAL_ID, SUBJECT_H, address(token), LOCK);
        vault.unlock(SUBJECT_H, address(token), DEAL_ID);
        (,, bytes32 lockCommit, bool released) = vault.lockOf(DEAL_ID, SUBJECT_H);
        assertTrue(released, "unlocked but parked: the tokens move only at reabsorb");
        assertEq(lockCommit, LOCKCOMMIT_H);
        assertEq(token.balanceOf(address(vault)), PRINCIPAL * 2, "nothing left the vault");
    }

    function test_unlock_missingLock() public {
        vm.expectRevert(PrivateBondVault.NoLock.selector);
        vault.unlock(SUBJECT_H, address(token), DEAL_ID);
    }

    function test_unlock_twiceFailsClosed() public {
        _lockBoth(DEAL_ID);
        vault.unlock(SUBJECT_H, address(token), DEAL_ID);
        vm.expectRevert(PrivateBondVault.NoLock.selector);
        vault.unlock(SUBJECT_H, address(token), DEAL_ID);
    }

    function test_unlock_onlyOperator() public {
        _lockBoth(DEAL_ID);
        vm.prank(address(0xB0B));
        vm.expectRevert(PrivateBondVault.Unauthorized.selector);
        vault.unlock(SUBJECT_H, address(token), DEAL_ID);
    }

    // ---------------------------------------------------------------- slash (kernel)

    function test_slash_paysWinnerAndReleasesWinnerLock() public {
        _lockBoth(DEAL_ID);
        vm.expectEmit(true, true, true, true, address(vault));
        emit PrivateBondVault.Slashed(DEAL_ID, SUBJECT_P, SUBJECT_H, address(token), DEST, LOCK);
        vault.slash(SUBJECT_P, SUBJECT_H, address(token), DEAL_ID, DEST);
        assertEq(token.balanceOf(DEST), LOCK, "the loser's lock went to the winner's signing address");
        assertEq(token.balanceOf(address(vault)), PRINCIPAL * 2 - LOCK);
        (, uint256 loserAmount,,) = vault.lockOf(DEAL_ID, SUBJECT_P);
        assertEq(loserAmount, 0, "the loser's lock is consumed, never reabsorbable");
        (,, bytes32 winnerCommit, bool winnerReleased) = vault.lockOf(DEAL_ID, SUBJECT_H);
        assertTrue(winnerReleased, "the winner's own lock is released for a later reabsorb");
        assertEq(winnerCommit, LOCKCOMMIT_H);
    }

    function test_slash_missingLock() public {
        _lockBoth(DEAL_ID);
        vault.slash(SUBJECT_P, SUBJECT_H, address(token), DEAL_ID, DEST); // consumes both
        vm.expectRevert(PrivateBondVault.NoLock.selector);
        vault.slash(SUBJECT_P, SUBJECT_H, address(token), DEAL_ID, DEST);
    }

    function test_slash_onlyOperator() public {
        _lockBoth(DEAL_ID);
        vm.prank(address(0xB0B));
        vm.expectRevert(PrivateBondVault.Unauthorized.selector);
        vault.slash(SUBJECT_P, SUBJECT_H, address(token), DEAL_ID, DEST);
    }

    // ---------------------------------------------------------------- burn (kernel)

    function test_burn_sendsBothToSink() public {
        _lockBoth(DEAL_ID);
        vm.expectEmit(true, true, true, true, address(vault));
        emit PrivateBondVault.Burned(DEAL_ID, SUBJECT_H, SUBJECT_P, address(token), LOCK * 2);
        vault.burn(SUBJECT_H, SUBJECT_P, address(token), DEAL_ID);
        assertEq(token.balanceOf(SINK), LOCK * 2);
        assertEq(token.balanceOf(address(vault)), PRINCIPAL * 2 - LOCK * 2);
        (, uint256 amountH,,) = vault.lockOf(DEAL_ID, SUBJECT_H);
        assertEq(amountH, 0);
        (, uint256 amountP,,) = vault.lockOf(DEAL_ID, SUBJECT_P);
        assertEq(amountP, 0);
    }

    function test_burn_onlyOperator() public {
        _lockBoth(DEAL_ID);
        vm.prank(address(0xB0B));
        vm.expectRevert(PrivateBondVault.Unauthorized.selector);
        vault.burn(SUBJECT_H, SUBJECT_P, address(token), DEAL_ID);
    }

    // ---------------------------------------------------------------- reabsorb (the subject's)

    function test_reabsorb_requiresClaim() public {
        _lockBoth(DEAL_ID);
        vault.unlock(SUBJECT_H, address(token), DEAL_ID);
        vm.expectRevert(PrivateBondVault.ClaimRequired.selector);
        vault.reabsorb(DEAL_ID, SUBJECT_H, REABSORB_NOTE_H, NULLBOND_H2, ok(true));
    }

    function test_reabsorb_requiresReleased() public {
        _lockBoth(DEAL_ID);
        gating.setClaimed(SUBJECT_H);
        // Still Reserved: no kernel terminal has let this lock go.
        vm.expectRevert(PrivateBondVault.NotReleased.selector);
        vault.reabsorb(DEAL_ID, SUBJECT_H, REABSORB_NOTE_H, NULLBOND_H2, ok(true));
    }

    function test_reabsorb_mergesOnce() public {
        _lockBoth(DEAL_ID);
        vault.unlock(SUBJECT_H, address(token), DEAL_ID);
        gating.setClaimed(SUBJECT_H);
        uint256 notesBefore = vault.notesTree().nextIndex();
        vm.expectEmit(true, true, true, true, address(vault));
        emit PrivateBondVault.Reabsorbed(DEAL_ID, SUBJECT_H, REABSORB_NOTE_H, LOCK);
        vault.reabsorb(DEAL_ID, SUBJECT_H, REABSORB_NOTE_H, NULLBOND_H2, ok(true));
        assertEq(vault.notesTree().nextIndex(), notesBefore + 1, "the lock merged into a fresh note");
        assertTrue(vault.notesTree().isSpent(NULLBOND_H2));
        (, uint256 lockAmount,,) = vault.lockOf(DEAL_ID, SUBJECT_H);
        assertEq(lockAmount, 0, "the record is gone");
        vm.expectRevert(PrivateBondVault.NoLock.selector);
        vault.reabsorb(DEAL_ID, SUBJECT_H, REABSORB_NOTE_H, NULLBOND_H2, ok(true));
    }

    function test_reabsorb_badProofIsAtomic() public {
        _lockBoth(DEAL_ID);
        vault.unlock(SUBJECT_H, address(token), DEAL_ID);
        gating.setClaimed(SUBJECT_H);
        vm.expectRevert(PrivateBondVault.ReabsorbProofFailed.selector);
        vault.reabsorb(DEAL_ID, SUBJECT_H, REABSORB_NOTE_H, NULLBOND_H2, ok(false));
        assertFalse(vault.notesTree().isSpent(NULLBOND_H2));
        assertEq(vault.notesTree().nextIndex(), 4, "deposit + change, both sides: nothing merged");
        (,, bytes32 lockCommit, bool released) = vault.lockOf(DEAL_ID, SUBJECT_H);
        assertEq(lockCommit, LOCKCOMMIT_H);
        assertTrue(released);
    }

    function test_reabsorb_unknownSubject() public {
        _lockBoth(DEAL_ID);
        vault.unlock(SUBJECT_H, address(token), DEAL_ID);
        gating.setClaimed(SUBJECT_H);
        vm.expectRevert(PrivateBondVault.NoLock.selector);
        vault.reabsorb(DEAL_ID, keccak256("no-such-subject"), REABSORB_NOTE_H, NULLBOND_H2, ok(true));
    }

    // ---------------------------------------------------------------- withdraw (the subject's)

    function test_withdraw_exactPaysDest() public {
        _deposit(holder, PRINCIPAL, NOTE_H);
        vm.expectEmit(true, true, true, true, address(vault));
        emit PrivateBondVault.Withdrawn(address(token), DEST, PRINCIPAL, bytes32(0));
        // No change note: the note is consumed whole, and no passport was ever asked anything.
        vault.withdraw(address(token), DEST, PRINCIPAL, bytes32(0), NULLBOND_H1, vault.bondRoot(), ok(true));
        assertEq(token.balanceOf(DEST), PRINCIPAL);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(vault.notesTree().nextIndex(), 1, "no change leaf for an exact consumption");
        assertTrue(vault.notesTree().isSpent(NULLBOND_H1));
    }

    function test_withdraw_withChangeNote() public {
        _deposit(holder, PRINCIPAL, NOTE_H);
        vault.withdraw(address(token), DEST, LOCK, CHANGE_H, NULLBOND_H1, vault.bondRoot(), ok(true));
        assertEq(token.balanceOf(DEST), LOCK);
        assertEq(token.balanceOf(address(vault)), PRINCIPAL - LOCK);
        assertEq(vault.notesTree().nextIndex(), 2, "the remainder lives on as a change note");
        assertTrue(vault.notesTree().isSpent(NULLBOND_H1));
    }

    function test_withdraw_badProofIsAtomic() public {
        _deposit(holder, PRINCIPAL, NOTE_H);
        bytes32 root = vault.bondRoot();
        vm.expectRevert(PrivateBondVault.WithdrawProofFailed.selector);
        vault.withdraw(address(token), DEST, PRINCIPAL, bytes32(0), NULLBOND_H1, root, ok(false));
        assertEq(token.balanceOf(DEST), 0);
        assertFalse(vault.notesTree().isSpent(NULLBOND_H1));
    }

    function test_withdraw_nullifierReplay() public {
        _deposit(holder, PRINCIPAL, NOTE_H);
        _deposit(holder, PRINCIPAL, NOTE_P); // a second note so the replay has something to eat
        vault.withdraw(address(token), DEST, LOCK, CHANGE_H, NULLBOND_H1, vault.bondRoot(), ok(true));
        bytes32 root = vault.bondRoot();
        vm.expectRevert(PoseidonTree.NullifierUsed.selector);
        vault.withdraw(address(token), DEST, LOCK, CHANGE_P, NULLBOND_H1, root, ok(true));
        assertEq(token.balanceOf(DEST), LOCK, "the replay moved nothing");
    }

    function test_withdraw_unknownRoot() public {
        _deposit(holder, PRINCIPAL, NOTE_H);
        vm.expectRevert(PrivateBondVault.UnknownRoot.selector);
        vault.withdraw(address(token), DEST, PRINCIPAL, bytes32(0), NULLBOND_H1, FAKE_ROOT, ok(true));
    }

    function test_withdraw_zeroGuards() public {
        _deposit(holder, PRINCIPAL, NOTE_H);
        // Hoisted: the getter would otherwise consume the expectations.
        bytes32 root = vault.bondRoot();
        vm.expectRevert(PrivateBondVault.ZeroAmount.selector);
        vault.withdraw(address(token), DEST, 0, bytes32(0), NULLBOND_H1, root, ok(true));
        vm.expectRevert(PrivateBondVault.ZeroAddress.selector);
        vault.withdraw(address(token), address(0), LOCK, CHANGE_H, NULLBOND_H1, root, ok(true));
    }

    // ---------------------------------------------------------------- the reads the vault refuses

    function test_availableAndLocked_areHidden() public {
        vm.expectRevert(PrivateBondVault.HiddenBalances.selector);
        vault.available(SUBJECT_H, address(token));
        vm.expectRevert(PrivateBondVault.HiddenBalances.selector);
        vault.locked(SUBJECT_H, address(token));
    }

    // ---------------------------------------------------------------- hygiene

    function test_notesTree_ownedByVault() public {
        // Hoisted: the getter would otherwise consume the prank and the expectation.
        PoseidonTree notes = vault.notesTree();
        vm.prank(address(0xB0B));
        vm.expectRevert(PoseidonTree.NotOwner.selector);
        notes.insert(WITHDRAW_NOTE);
    }
}
