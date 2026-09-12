// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Status, DealTerms, DealClocks, PackageMods} from "../../src/libraries/Types.sol";
import {PackageId} from "../../src/libraries/PackageId.sol";
import {Escrow} from "../../src/Escrow.sol";
import {TestToken} from "../../src/TestToken.sol";
import {PassportMock} from "../../src/packages/PassportMock.sol";
import {Reputation} from "../../src/packages/Reputation.sol";
import {BondVault} from "../../src/packages/BondVault.sol";
import {ZkMock} from "../../src/packages/ZkMock.sol";
import {VerifierMock} from "../../src/mocks/VerifierMock.sol";
import {KlerosAdapter} from "../../src/packages/KlerosAdapter.sol";
import {MockArbitratorV2} from "../../src/mocks/MockArbitratorV2.sol";
import {IPassport} from "../../src/packages/interfaces/IPassport.sol";
import {IReputation} from "../../src/packages/interfaces/IReputation.sol";
import {HandlerBase} from "./HandlerBase.sol";

/// @dev Reputation whose completion fee can drift mid-deal (proxy that changes policy).
///      Tracks nothing: the kernel must treat it as fail-open (TRUST-03) and keep Core exits alive.
contract DriftingReputation is IReputation {
    error Unauthorized();

    IPassport public immutable passport;
    address public immutable operator;
    address public immutable feeRecipient;
    uint256 public immutable activationFee;
    uint256 public completionFee;
    bytes32 public packageId;

    constructor(IPassport passport_, address feeRecipient_, uint256 completionFee_, address operator_) {
        passport = passport_;
        feeRecipient = feeRecipient_;
        activationFee = 0;
        completionFee = completionFee_;
        operator = operator_;
        packageId = PackageId.reputation(address(this), feeRecipient_, 0, completionFee_);
    }

    function setCompletionFee(uint256 fee) external {
        completionFee = fee;
        packageId = PackageId.reputation(address(this), feeRecipient, 0, fee);
    }

    function invoiceActivation() external pure returns (uint256, address) {
        return (0, address(0));
    }

    function invoiceCompletion() external view returns (uint256, address) {
        return (completionFee, feeRecipient);
    }

    function admit(address wallet, address, uint256, address) external view returns (bytes32) {
        if (msg.sender != operator) revert Unauthorized();
        return passport.identify(wallet);
    }

    function notifyTerminal(bytes32, address, uint256, IReputation.Close) external view {
        if (msg.sender != operator) revert Unauthorized();
    }
}

contract PackagesHandler is HandlerBase {
    uint8 internal constant K_PASSPORT = 1;
    uint8 internal constant K_REP = 2;
    uint8 internal constant K_BONDS = 4;

    uint256 internal constant ACT_FEE = 500_000;
    uint256 internal constant COMP_FEE = 250_000;
    uint256 internal constant ZK_FEE = 100_000;
    uint256 internal constant HUGE_FEE = 1e30;
    uint256 internal constant COURT_ETH = 0.01 ether;
    uint256 internal constant MAX_PRINCIPAL = 200e6; // under the T1 cap so packaged deals stay admissible
    uint256 internal constant BOND_SEED = 1e12;

    bytes32 public constant SUB_H = keccak256("human-h");
    bytes32 public constant SUB_P = keccak256("human-p");
    address public constant FEE_RECIPIENT = address(0xFEE);
    address public constant SINK = address(0xdEaD);

    TestToken public token;
    PassportMock public passport;
    Reputation public reputation;
    Reputation public reputationHuge;
    DriftingReputation public reputationDrift;
    BondVault public vault;
    ZkMock public zk;
    MockArbitratorV2 public arbitrator;
    KlerosAdapter public court;

    uint256 public ghost_actFees;
    uint256 public ghost_bondDeposited;
    uint256 internal nullifierSeed;

    constructor(Escrow escrow_, TestToken token_) HandlerBase(escrow_) {
        token = token_;
        passport = new PassportMock();
        reputation = new Reputation(passport, FEE_RECIPIENT, ACT_FEE, COMP_FEE, address(escrow_));
        reputationHuge = new Reputation(passport, FEE_RECIPIENT, 0, HUGE_FEE, address(escrow_));
        reputationDrift = new DriftingReputation(passport, FEE_RECIPIENT, COMP_FEE, address(escrow_));
        vault = new BondVault(address(escrow_), SINK, passport);
        zk = new ZkMock(new VerifierMock(), FEE_RECIPIENT, ZK_FEE, address(escrow_));
        arbitrator = new MockArbitratorV2(COURT_ETH);
        court = new KlerosAdapter(
            address(arbitrator), abi.encode(uint256(1), uint256(3), uint256(1)), 0, "", address(escrow_), address(0)
        );
        passport.setHuman(holder, SUB_H);
        passport.setHuman(provider, SUB_P);
    }

    // --- activation ------------------------------------------------------------------------------

    /// kind: 0 core | 1 passport+rep | 2 trio | 3 trio+court | 4 zk | 5 zk+trio | 6 huge-fee trio | 7 drift rep | 8 court
    function activate(uint8 kind, uint256 principal, bool distinct, uint256 fiatDur, uint256 relDur, uint256 dispDur)
        external
        count("activate")
    {
        kind = kind % 9;
        principal = bound(principal, 1, MAX_PRINCIPAL);
        DealTerms memory t = _baseTerms(principal, distinct, fiatDur, relDur, dispDur);
        t.token = address(token);

        (PackageMods memory mods, uint8 kinds, address rep) = _mods(kind);
        if (kinds != 0 && !_admissible(kinds, rep, principal)) return;

        t.packageIds = _ids(mods, kinds);
        uint256 actFee = rep == address(0) ? 0 : IReputation(rep).activationFee();
        token.mint(holder, principal + actFee);
        ghost_minted += principal + actFee;
        ghost_actFees += actFee;
        _activateSigned(t, kinds, rep, mods, kinds != 0);
    }

    function _mods(uint8 kind) internal view returns (PackageMods memory m, uint8 kinds, address rep) {
        if (kind == 0) return (m, 0, address(0));
        if (kind == 4) {
            m.zk = address(zk);
            return (m, K_ZK, address(0));
        }
        if (kind == 8) {
            m.court = address(court);
            return (m, K_ARB, address(0));
        }
        m.passport = address(passport);
        kinds = K_PASSPORT;
        if (kind == 7) {
            m.reputation = address(reputationDrift);
            return (m, kinds | K_REP, address(reputationDrift));
        }
        rep = kind == 6 ? address(reputationHuge) : address(reputation);
        m.reputation = rep;
        kinds |= K_REP;
        if (kind == 1) return (m, kinds, rep);
        m.bonds = address(vault);
        kinds |= K_BONDS;
        if (kind == 3) {
            m.court = address(court);
            kinds |= K_ARB;
        } else if (kind == 5) {
            m.zk = address(zk);
            kinds |= K_ZK;
        }
    }

    function _ids(PackageMods memory m, uint8 kinds) internal view returns (bytes32[] memory ids_) {
        bytes32[5] memory buf;
        uint256 n;
        if ((kinds & K_PASSPORT) != 0) buf[n++] = PackageId.passport(m.passport);
        if ((kinds & K_REP) != 0) buf[n++] = IReputation(m.reputation).packageId();
        if ((kinds & K_BONDS) != 0) buf[n++] = vault.packageId();
        if ((kinds & K_ZK) != 0) buf[n++] = zk.packageId();
        if ((kinds & K_ARB) != 0) buf[n++] = court.packageId();
        for (uint256 i = 1; i < n; i++) {
            for (uint256 j = i; j > 0 && buf[j] < buf[j - 1]; j--) {
                (buf[j], buf[j - 1]) = (buf[j - 1], buf[j]);
            }
        }
        ids_ = new bytes32[](n);
        for (uint256 i; i < n; i++) {
            ids_[i] = buf[i];
        }
    }

    /// Mirrors `Reputation.admit` + `BondVault.reserve` preconditions so a skipped deal is a no-op, not a revert.
    function _admissible(uint8 kinds, address rep, uint256 principal) internal view returns (bool) {
        if ((kinds & K_REP) == 0) return true;
        if (rep == address(reputationDrift)) return true;
        Reputation r = Reputation(rep);
        bool withBond = (kinds & K_BONDS) != 0;
        bytes32[2] memory subs = [SUB_H, SUB_P];
        for (uint256 i; i < 2; i++) {
            uint256 next = r.inFlight(subs[i], address(token)) + principal;
            if (next > r.cap(subs[i], address(token), withBond)) return false;
            if (withBond) {
                uint256 lockAmount = (principal + 9) / 10;
                if (vault.available(subs[i], address(token)) < lockAmount) return false;
                if ((vault.locked(subs[i], address(token)) + lockAmount) * 10 < next) return false;
            }
        }
        return true;
    }

    // --- package-specific verbs ----------------------------------------------------------------

    function _canVerifyProof(bytes32 id) internal view returns (bool) {
        return _status(id) == Status.FUNDED && _zk(id);
    }

    function _canOpenCourt(bytes32 id) internal view returns (bool) {
        if (!_arb(id) || _zk(id)) return false;
        Status s = _status(id);
        if (s == Status.FIAT_SENT) return !_releaseDue(id);
        if (s == Status.DISPUTED) return !_disputeDue(id);
        return false;
    }

    function _canRule(bytes32 id) internal view returns (bool) {
        return _status(id) == Status.ARBITRATION_ACTIVE && court.rulingOf(id) == KlerosAdapter.Ruling.None;
    }

    function _canReadRuling(bytes32 id) internal view returns (bool) {
        return _status(id) == Status.ARBITRATION_ACTIVE && court.readRuling(id) != 0;
    }

    function _canArbTimeout(bytes32 id) internal view returns (bool) {
        return _status(id) == Status.ARBITRATION_ACTIVE
            && _due(escrow.clocks(id).arbitrationOpenedAt, escrow.terms(id).arbitrationDuration);
    }

    function verifyProof(uint256 seed) external count("verifyProof") {
        (bytes32 id, bool ok) = _pickIf(seed, _canVerifyProof);
        if (!ok) return;
        bytes32 nullifier = keccak256(abi.encode("rail-receipt", ++nullifierSeed));
        vm.prank(relayer);
        escrow.verifyProof(id, abi.encode(id, nullifier));
        _recordTerminal(id);
    }

    function openCourt(uint256 seed) external count("openCourt") {
        (bytes32 id, bool ok) = _pickIf(seed, _canOpenCourt);
        if (!ok) return;
        address c = escrow.terms(id).controller;
        vm.deal(c, COURT_ETH);
        vm.prank(c);
        escrow.openCourt{value: COURT_ETH}(id);
    }

    function rule(uint256 seed, uint8 ruling) external count("rule") {
        (bytes32 id, bool ok) = _pickIf(seed, _canRule);
        if (!ok) return;
        arbitrator.giveRuling(court.disputeOf(id), ruling % 3);
    }

    /// Jurors rule and anyone reads. If nothing is ruled yet, rule the first open dispute (seed-derived) and read it.
    function readRuling(uint256 seed) external count("readRuling") {
        (bytes32 id, bool ok) = _pickIf(seed, _canReadRuling);
        if (!ok) {
            (id, ok) = _pickIf(seed, _canRule);
            if (!ok) return;
            arbitrator.giveRuling(court.disputeOf(id), seed % 3);
        }
        vm.prank(relayer);
        escrow.readRuling(id);
        _recordTerminal(id);
    }

    function forceArbitrationTimeout(uint256 seed) external count("forceArbitrationTimeout") {
        (bytes32 id, bool ok) = _pickIf(seed, _canArbTimeout);
        if (!ok) return;
        vm.prank(relayer);
        escrow.forceArbitrationTimeout(id);
        _recordTerminal(id);
    }

    function driftFee(uint256 fee) external count("driftFee") {
        reputationDrift.setCompletionFee(bound(fee, 0, HUGE_FEE));
    }

    function depositBond(uint8 who, uint256 amount) external count("depositBond") {
        amount = bound(amount, 1, BOND_SEED);
        (address wallet, bytes32 subject) = who % 2 == 0 ? (holder, SUB_H) : (provider, SUB_P);
        token.mint(wallet, amount);
        ghost_minted += amount;
        ghost_bondDeposited += amount;
        vm.startPrank(wallet);
        token.approve(address(vault), amount);
        vault.deposit(subject, address(token), amount);
        vm.stopPrank();
    }

    function withdrawBond(uint8 who, uint256 amount) external count("withdrawBond") {
        (address wallet, bytes32 subject) = who % 2 == 0 ? (holder, SUB_H) : (provider, SUB_P);
        uint256 avail = vault.available(subject, address(token));
        if (avail == 0) return;
        amount = bound(amount, 1, avail);
        vm.prank(wallet);
        vault.withdraw(subject, address(token), amount);
    }

    function withdraw(uint8 who) external count("withdraw") {
        address a = who % 3 == 0 ? holder : who % 3 == 1 ? provider : FEE_RECIPIENT;
        vm.prank(a);
        escrow.withdraw(address(token));
    }
}

contract EscrowPackagesInvariantTest is Test {
    uint8 internal constant K_REP = 2;
    uint8 internal constant K_BONDS = 4;
    uint8 internal constant K_ZK = 8;
    uint8 internal constant K_ARB = 16;

    Escrow internal escrow;
    TestToken internal token;
    PackagesHandler internal h;

    function setUp() public {
        token = new TestToken();
        escrow = new Escrow();
        h = new PackagesHandler(escrow, token);
        vm.prank(h.holder());
        token.approve(address(escrow), type(uint256).max);

        // Seed bonds so trio deals are admissible from the first call.
        h.depositBond(0, 1e12);
        h.depositBond(1, 1e12);

        bytes4[] memory sel = new bytes4[](23);
        sel[0] = PackagesHandler.activate.selector;
        sel[1] = PackagesHandler.activate.selector;
        sel[21] = PackagesHandler.activate.selector;
        sel[22] = HandlerBase.markFiat.selector;
        sel[2] = HandlerBase.markFiat.selector;
        sel[3] = HandlerBase.cancelByProvider.selector;
        sel[4] = HandlerBase.timeoutFiat.selector;
        sel[5] = HandlerBase.release.selector;
        sel[6] = HandlerBase.claim.selector;
        sel[7] = HandlerBase.openDisputed.selector;
        sel[8] = HandlerBase.forceStalemate.selector;
        sel[9] = HandlerBase.mutualCancel.selector;
        sel[10] = HandlerBase.coSignedRelease.selector;
        sel[11] = HandlerBase.mutualSplit.selector;
        sel[12] = PackagesHandler.verifyProof.selector;
        sel[13] = PackagesHandler.openCourt.selector;
        sel[14] = PackagesHandler.rule.selector;
        sel[15] = PackagesHandler.readRuling.selector;
        sel[16] = PackagesHandler.forceArbitrationTimeout.selector;
        sel[17] = PackagesHandler.driftFee.selector;
        sel[18] = PackagesHandler.depositBond.selector;
        sel[19] = PackagesHandler.withdrawBond.selector;
        sel[20] = PackagesHandler.withdraw.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: sel}));
        targetContract(address(h));
    }

    /// Escrow balance == live principal + every matured credit (Holder, Provider, fee recipient).
    function invariant_solvency() public view {
        uint256 live;
        uint256 n = h.idsLength();
        for (uint256 i; i < n; i++) {
            bytes32 id = h.ids(i);
            if (!_terminal(escrow.status(id))) live += h.ghostOf(id).principal;
        }
        uint256 credits = escrow.creditOf(address(token), h.holder()) + escrow.creditOf(address(token), h.provider())
            + escrow.creditOf(address(token), h.FEE_RECIPIENT());
        assertEq(token.balanceOf(address(escrow)), live + credits, "escrow balance != live principal + credits");
    }

    /// Fees only ever come out of the principal, and every wei of fee lands with the fee recipient.
    /// holderAmt + providerAmt <= principal per deal; the gap summed over terminals == fees collected.
    function invariant_feesAccounted() public view {
        uint256 terminalFees;
        uint256 n = h.idsLength();
        for (uint256 i; i < n; i++) {
            bytes32 id = h.ids(i);
            (Status s, uint256 hAmt, uint256 pAmt) = escrow.settlementOf(id);
            uint256 principal = h.ghostOf(id).principal;
            if (!_terminal(s)) continue;
            assertLe(hAmt + pAmt, principal, "terminal paid out more than principal");
            uint8 kinds = escrow.kinds(id);
            if ((kinds & (K_REP | K_ZK)) == 0) assertEq(hAmt + pAmt, principal, "fee taken without a fee package");
            if (s == Status.CANCELLED || s == Status.STALEMATE) {
                assertEq(hAmt + pAmt, principal, "holder-positive terminal charged a fee");
            }
            terminalFees += principal - hAmt - pAmt;
        }
        uint256 collected = token.balanceOf(h.FEE_RECIPIENT()) + escrow.creditOf(address(token), h.FEE_RECIPIENT());
        assertEq(collected, h.ghost_actFees() + terminalFees, "fee recipient != activation + terminal fees");
    }

    /// CASE-CORE-17 with packages on: nothing a module does after commit can move a terminal record.
    function invariant_terminalImmutable() public view {
        uint256 n = h.idsLength();
        for (uint256 i; i < n; i++) {
            bytes32 id = h.ids(i);
            HandlerBase.Ghost memory g = h.ghostOf(id);
            if (!g.terminal) continue;
            (Status s, uint256 hAmt, uint256 pAmt) = escrow.settlementOf(id);
            assertEq(uint8(s), uint8(g.terminalStatus), "terminal status mutated");
            assertEq(hAmt, g.holderAmt, "holderAmt mutated");
            assertEq(pAmt, g.providerAmt, "providerAmt mutated");
        }
    }

    /// BondVault is another box: balance == sum of deposits, locks never exceed deposits,
    /// locked == sum of live locks, and no terminal deal keeps a lock (peaceful unlock, slash, or burn).
    function invariant_bondVault() public view {
        BondVault vault = h.vault();
        bytes32[2] memory subs = [h.SUB_H(), h.SUB_P()];
        uint256 depositedTotal;
        for (uint256 s; s < 2; s++) {
            uint256 dep = vault.deposited(subs[s], address(token));
            uint256 locked = vault.locked(subs[s], address(token));
            depositedTotal += dep;
            assertLe(locked, dep, "locked exceeds deposited");
            uint256 liveLocks;
            uint256 n = h.idsLength();
            for (uint256 i; i < n; i++) {
                bytes32 id = h.ids(i);
                if ((escrow.kinds(id) & K_BONDS) == 0) continue;
                uint256 lock = vault.lockOf(subs[s], id);
                if (_terminal(escrow.status(id))) {
                    assertEq(lock, 0, "terminal deal still locked");
                } else {
                    assertEq(lock, (h.ghostOf(id).principal + 9) / 10, "live lock is not 10%");
                    liveLocks += lock;
                }
            }
            assertEq(locked, liveLocks, "locked != sum of live locks");
        }
        assertEq(token.balanceOf(address(vault)), depositedTotal, "vault balance != deposits");
    }

    /// Reputation `inFlight` mirrors live exposure exactly, per module instance.
    function invariant_inFlight() public view {
        Reputation[2] memory reps = [h.reputation(), h.reputationHuge()];
        bytes32[2] memory subs = [h.SUB_H(), h.SUB_P()];
        for (uint256 r; r < 2; r++) {
            uint256 live;
            uint256 n = h.idsLength();
            for (uint256 i; i < n; i++) {
                bytes32 id = h.ids(i);
                HandlerBase.Ghost memory g = h.ghostOf(id);
                if (g.reputation != address(reps[r])) continue;
                if (!_terminal(escrow.status(id))) live += g.principal;
            }
            for (uint256 s; s < 2; s++) {
                assertEq(reps[r].inFlight(subs[s], address(token)), live, "inFlight != live principal");
            }
        }
    }

    /// Package edges stay closed: ZK deals never see FIAT_SENT / DISPUTED / court; only ARB deals reach court.
    function invariant_edgesClosed() public view {
        uint256 n = h.idsLength();
        for (uint256 i; i < n; i++) {
            bytes32 id = h.ids(i);
            Status s = escrow.status(id);
            uint8 kinds = escrow.kinds(id);
            if ((kinds & K_ZK) != 0) {
                assertTrue(
                    s == Status.FUNDED || s == Status.RELEASED || s == Status.CANCELLED,
                    "ZK deal entered a disputed edge"
                );
            }
            if (s == Status.ARBITRATION_ACTIVE || s == Status.RESOLVED_BY_ARBITRATION) {
                assertTrue((kinds & K_ARB) != 0, "court terminal without ARBITRATION package");
            }
        }
    }

    /// Nothing leaves the closed set of actors; the Controller and relayer never touch value.
    function invariant_noLeak() public view {
        uint256 total = token.balanceOf(address(escrow)) + token.balanceOf(address(h.vault()))
            + token.balanceOf(h.holder()) + token.balanceOf(h.provider()) + token.balanceOf(h.controller())
            + token.balanceOf(h.relayer()) + token.balanceOf(h.FEE_RECIPIENT()) + token.balanceOf(h.SINK());
        assertEq(total, h.ghost_minted(), "tokens left the recinto");
        assertEq(token.balanceOf(h.relayer()), 0, "relayer received value");
        // A distinct Controller never receives principal, fee, or slash (P2P Holder-Controller may).
        assertEq(token.balanceOf(h.controller()), 0, "distinct controller received value");
    }

    function afterInvariant() public view {
        uint256[10] memory byStatus;
        uint256 zkReleased;
        uint256 bondsTerminal;
        uint256 n = h.idsLength();
        for (uint256 i; i < n; i++) {
            bytes32 id = h.ids(i);
            Status s = escrow.status(id);
            byStatus[uint8(s)]++;
            uint8 k = escrow.kinds(id);
            if ((k & K_ZK) != 0 && s == Status.RELEASED) zkReleased++;
            if ((k & K_BONDS) != 0 && _terminal(s)) bondsTerminal++;
        }
        console2.log("deals", n);
        console2.log("FUNDED/FIAT_SENT/DISPUTED", byStatus[1], byStatus[2], byStatus[3]);
        console2.log("RELEASED/SPLIT/STALEMATE", byStatus[4], byStatus[5], byStatus[6]);
        console2.log("CANCELLED/ARB_ACTIVE/ARB_RESOLVED", byStatus[7], byStatus[8], byStatus[9]);
        console2.log("zkReleased/bondsTerminal", zkReleased, bondsTerminal);
        console2.log("sink/controller", token.balanceOf(h.SINK()), token.balanceOf(h.controller()));
    }

    function _terminal(Status s) internal pure returns (bool) {
        return s == Status.RELEASED || s == Status.RESOLVED_SPLIT || s == Status.STALEMATE || s == Status.CANCELLED
            || s == Status.RESOLVED_BY_ARBITRATION;
    }
}
