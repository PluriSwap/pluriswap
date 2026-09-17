// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    Status,
    DealTerms,
    HolderAuthorization,
    ProviderAgreement,
    ControllerAcceptance,
    PackageMods
} from "../src/libraries/Types.sol";
import {Clocks} from "../src/libraries/Clocks.sol";
import {Escrow} from "../src/Escrow.sol";
import {Packages} from "../src/libraries/Packages.sol";
import {TestToken} from "../mocks/TestToken.sol";
import {PassportMock} from "../mocks/PassportMock.sol";
import {Reputation} from "../src/packages/Reputation.sol";
import {BondVault} from "../src/packages/BondVault.sol";
import {ZkMock} from "../mocks/ZkMock.sol";
import {VerifierMock} from "../mocks/VerifierMock.sol";
import {KlerosAdapter} from "../src/packages/KlerosAdapter.sol";
import {MockArbitratorV2} from "../mocks/MockArbitratorV2.sol";
import {IPassport} from "../src/packages/interfaces/IPassport.sol";
import {IBondVault} from "../src/packages/interfaces/IBondVault.sol";
import {IReputation} from "../src/packages/interfaces/IReputation.sol";
import {IPaymentProof} from "../src/packages/interfaces/IPaymentProof.sol";
import {IVerifier} from "../src/packages/interfaces/IVerifier.sol";
import {PackageId} from "../src/libraries/PackageId.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseTest} from "./Base.t.sol";

contract PackagesTest is BaseTest {
    uint256 internal constant ACT_FEE = 100_000;
    uint256 internal constant COMP_FEE = 50_000;
    uint256 internal constant ZK_FEE = 10_000;
    uint256 internal constant COURT_ETH = 0.01 ether;
    uint256 internal constant BOND = PRINCIPAL / 10;
    bytes32 internal constant SUB_H = keccak256("human-h");
    bytes32 internal constant SUB_P = keccak256("human-p");

    PassportMock internal passport;
    Reputation internal reputation;
    BondVault internal vault;
    ZkMock internal zkMod;
    MockArbitratorV2 internal arbitrator;
    KlerosAdapter internal court;
    address internal feeRecipient = address(0xFEE);
    address internal sink = address(0xdeaD);
    bytes internal extraData;

    function setUp() public override {
        holder = vm.addr(holderPk);
        provider = vm.addr(providerPk);
        controller = vm.addr(controllerPk);
        token = new TestToken();
        passport = new PassportMock();
        extraData = abi.encode(uint256(1), uint256(3), uint256(1));
        uint64 n = vm.getNonce(address(this));
        address predicted = vm.computeCreateAddress(address(this), n + 6);
        reputation = new Reputation(passport, feeRecipient, ACT_FEE, COMP_FEE, predicted);
        VerifierMock verifier = new VerifierMock();
        zkMod = new ZkMock(verifier, feeRecipient, ZK_FEE, predicted);
        arbitrator = new MockArbitratorV2(COURT_ETH);
        vault = new BondVault(predicted, sink, passport);
        court = new KlerosAdapter(address(arbitrator), extraData, 0, "", predicted, address(0), "");
        escrow = new Escrow();
        assertEq(address(escrow), predicted);
        assertEq(reputation.operator(), address(escrow));
        assertEq(zkMod.operator(), address(escrow));

        passport.setHuman(holder, SUB_H);
        passport.setHuman(provider, SUB_P);
        vm.deal(holder, 1 ether);
        token.mint(holder, PRINCIPAL + ACT_FEE + BOND);
        token.mint(provider, BOND);
        vm.prank(holder);
        token.approve(address(escrow), type(uint256).max);
        vm.prank(holder);
        token.approve(address(vault), type(uint256).max);
        vm.prank(provider);
        token.approve(address(vault), type(uint256).max);
    }

    function test_unknownPackageIdReverts() public {
        DealTerms memory terms = _p2pTerms();
        terms.packageIds = new bytes32[](1);
        terms.packageIds[0] = keccak256("unknown");
        HolderAuthorization memory ha = _holderAuth(terms, 1);
        ProviderAgreement memory pa = _providerAuth(terms, 1);
        ControllerAcceptance memory ca;
        bytes memory hs = _signHolder(ha);
        bytes memory ps = _signProvider(pa);
        vm.expectRevert(Packages.UnknownPackage.selector);
        escrow.activate(ha, hs, pa, ps, ca, "");
        assertFalse(escrow.used(holder, 1));
    }

    function test_zkAndArbIncompatible() public {
        DealTerms memory terms = _p2pTerms();
        terms.packageIds = _sorted2(zkMod.packageId(), court.packageId());
        HolderAuthorization memory ha = _holderAuth(terms, 1);
        ProviderAgreement memory pa = _providerAuth(terms, 1);
        ControllerAcceptance memory ca;
        PackageMods memory mods;
        mods.zk = address(zkMod);
        mods.court = address(court);
        bytes memory hs = _signHolder(ha);
        bytes memory ps = _signProvider(pa);
        vm.expectRevert(Packages.IncompatiblePackages.selector);
        escrow.activate(ha, hs, pa, ps, ca, "", mods);
    }

    function test_noPassport_noAdmit() public {
        passport.setHuman(holder, bytes32(0));
        _fundBonds();
        DealTerms memory terms = _trioTerms();
        HolderAuthorization memory ha = _holderAuth(terms, 1);
        ProviderAgreement memory pa = _providerAuth(terms, 1);
        ControllerAcceptance memory ca;
        bytes memory hs = _signHolder(ha);
        bytes memory ps = _signProvider(pa);
        vm.expectRevert(IPassport.NoPassport.selector);
        escrow.activate(ha, hs, pa, ps, ca, "", _trioMods());
        assertFalse(escrow.used(holder, 1));
        assertEq(token.balanceOf(feeRecipient), 0);
    }

    function test_activate_trio_invoiceReservePull() public {
        _fundBonds();
        bytes32 id = _activateTrio(1, 1);
        assertEq(uint8(escrow.status(id)), uint8(Status.FUNDED));
        assertEq(token.balanceOf(feeRecipient), ACT_FEE);
        assertEq(token.balanceOf(address(escrow)), PRINCIPAL);
        assertEq(vault.lockOf(SUB_H, id), BOND);
        assertEq(vault.lockOf(SUB_P, id), BOND);
        assertEq(reputation.inFlight(SUB_H, address(token)), PRINCIPAL);
        (bytes32 h, bytes32 p) = escrow.subjects(id);
        assertEq(h, SUB_H);
        assertEq(p, SUB_P);
    }

    function test_release_unlocksAndCompletionFee() public {
        _fundBonds();
        bytes32 id = _activateTrio(1, 1);
        _markFiat(id);
        vm.prank(holder);
        escrow.release(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.RELEASED));
        assertEq(token.balanceOf(provider), PRINCIPAL - COMP_FEE);
        assertEq(token.balanceOf(feeRecipient), ACT_FEE + COMP_FEE);
        assertEq(vault.lockOf(SUB_H, id), 0);
        assertEq(vault.available(SUB_H, address(token)), BOND);
        assertEq(reputation.score(SUB_H, address(token)), 1);
        assertEq(reputation.inFlight(SUB_H, address(token)), 0);
    }

    function test_timeoutFiat_silentNoCompletion() public {
        _fundBonds();
        bytes32 id = _activateTrio(1, 1);
        vm.warp(block.timestamp + 3600);
        escrow.timeoutFiat(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.CANCELLED));
        assertEq(token.balanceOf(holder), PRINCIPAL);
        assertEq(token.balanceOf(feeRecipient), ACT_FEE);
        assertEq(reputation.score(SUB_H, address(token)), 0);
        assertEq(vault.available(SUB_H, address(token)), BOND);
    }

    function test_stalemate_burnsBonds() public {
        _fundBonds();
        bytes32 id = _activateTrio(1, 1);
        _markFiat(id);
        _openDisputed(id);
        vm.warp(block.timestamp + 7200);
        escrow.forceStalemate(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.STALEMATE));
        assertEq(token.balanceOf(sink), BOND * 2);
        (, uint32 penalty,) = reputation.stats(SUB_H, address(token));
        assertEq(penalty, 5);
    }

    /// Decision: the completion fee is invoiced on the whole pot whenever the Provider is paid, before any split.
    function test_stalemate_isASplit_chargesCompletionOnTotal() public {
        _fundBonds();
        bytes32 id = _activateTrio(1, 1);
        _markFiat(id);
        _openDisputed(id);
        vm.warp(block.timestamp + 7200);
        escrow.forceStalemate(id);
        uint256 pot = PRINCIPAL - COMP_FEE;
        assertEq(token.balanceOf(feeRecipient), ACT_FEE + COMP_FEE);
        assertEq(token.balanceOf(provider), pot / 2);
        assertEq(token.balanceOf(holder), pot - pot / 2);
    }

    /// Decision: CLAIMED is its own terminal. The trade happened: fee on the pot, Provider credited, Holder silent.
    function test_claim_isClaimed_chargesCompletion_creditsProviderOnly() public {
        _fundBonds();
        bytes32 id = _activateTrio(1, 1);
        _markFiat(id);
        vm.warp(block.timestamp + 1800);
        escrow.claim(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.CLAIMED));
        assertEq(token.balanceOf(provider), PRINCIPAL - COMP_FEE);
        assertEq(token.balanceOf(feeRecipient), ACT_FEE + COMP_FEE);
        assertEq(reputation.score(SUB_P, address(token)), 1, "provider closed the trade");
        assertEq(reputation.score(SUB_H, address(token)), 0, "absent controller is not credited");
        (, uint32 penaltyH,) = reputation.stats(SUB_H, address(token));
        assertEq(penaltyH, 0, "absent controller is not proven fault");
        assertEq(vault.available(SUB_H, address(token)), BOND);
        assertEq(vault.available(SUB_P, address(token)), BOND);
        assertEq(reputation.inFlight(SUB_H, address(token)), 0);
    }

    /// Decision: the court refusing to decide is not proven fault. Locks come back; both scores record the dispute.
    function test_courtRefuses_unlocksBonds_recordsStalemate() public {
        _fundBonds();
        bytes32 id = _activateArbTrio();
        _markFiat(id);
        vm.prank(holder);
        escrow.openCourt{value: COURT_ETH}(id);
        arbitrator.giveRuling(court.disputeOf(id), 0);
        escrow.readRuling(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.STALEMATE));
        assertEq(token.balanceOf(sink), 0, "court tie burned a bond");
        assertEq(vault.available(SUB_H, address(token)), BOND);
        assertEq(vault.available(SUB_P, address(token)), BOND);
        (, uint32 penaltyH,) = reputation.stats(SUB_H, address(token));
        (, uint32 penaltyP,) = reputation.stats(SUB_P, address(token));
        assertEq(penaltyH, 5);
        assertEq(penaltyP, 5);
    }

    /// Decision: a court that never answers is the court's failure. Locks back, no score moves.
    function test_courtTimeout_unlocksBonds_silent() public {
        _fundBonds();
        bytes32 id = _activateArbTrio();
        _markFiat(id);
        vm.prank(holder);
        escrow.openCourt{value: COURT_ETH}(id);
        vm.warp(block.timestamp + 1 days);
        escrow.forceArbitrationTimeout(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.STALEMATE));
        assertEq(token.balanceOf(sink), 0);
        assertEq(vault.available(SUB_H, address(token)), BOND);
        assertEq(vault.available(SUB_P, address(token)), BOND);
        (, uint32 penaltyH,) = reputation.stats(SUB_H, address(token));
        (, uint32 penaltyP,) = reputation.stats(SUB_P, address(token));
        assertEq(penaltyH, 0);
        assertEq(penaltyP, 0);
        assertEq(reputation.inFlight(SUB_P, address(token)), 0);
    }

    /// Decision: a ruled slash always compensates the wronged side; Provider wins → Holder's lock to the Provider.
    function test_providerWin_slashesHolderBondToProvider_feeOnPot() public {
        _fundBonds();
        bytes32 id = _activateArbTrio();
        _markFiat(id);
        vm.prank(holder);
        escrow.openCourt{value: COURT_ETH}(id);
        arbitrator.giveRuling(court.disputeOf(id), 2);
        escrow.readRuling(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.RESOLVED_BY_ARBITRATION));
        assertEq(token.balanceOf(provider), PRINCIPAL - COMP_FEE + BOND);
        assertEq(token.balanceOf(feeRecipient), ACT_FEE + COMP_FEE);
        assertEq(token.balanceOf(sink), 0);
        assertEq(vault.available(SUB_P, address(token)), BOND, "winner's own lock released");
        assertEq(vault.deposited(SUB_H, address(token)), 0, "loser's lock left the vault");
        (, uint32 penaltyH,) = reputation.stats(SUB_H, address(token));
        assertEq(penaltyH, 15);
    }

    function _activateArbTrio() internal returns (bytes32) {
        DealTerms memory terms = _p2pTerms();
        terms.packageIds = _sorted4(passport.packageId(), reputation.packageId(), vault.packageId(), court.packageId());
        terms.arbitrationDuration = 1 days;
        PackageMods memory mods = _trioMods();
        mods.court = address(court);
        return _activateWith(terms, mods, 1, 1);
    }

    /// The completion fee is invoiced on the whole pot before the split, and `_invoice` skips it when
    /// `fee >= left`. At `fee == principal` the fee therefore is not collected at all, and a Provider who won
    /// in court keeps the whole pot instead of netting zero. Consent is unchanged -- `completionFee` is
    /// immutable and inside the signed `packageId`, `principal` is signed too -- but the terminal no longer
    /// degenerates into a pure transfer to the fee recipient.
    function test_providerWin_feeEqualsPrincipal_feeSkippedProviderPaidInFull() public {
        DealTerms memory terms = _p2pTerms();
        terms.principal = COMP_FEE;
        terms.arbitrationDuration = 1 days;
        terms.packageIds = _sorted3(passport.packageId(), reputation.packageId(), court.packageId());
        PackageMods memory mods;
        mods.passport = address(passport);
        mods.reputation = address(reputation);
        mods.court = address(court);
        bytes32 id = _activateWith(terms, mods, 1, 1);
        assertEq(token.balanceOf(feeRecipient), ACT_FEE, "activation fee");

        _markFiat(id);
        vm.prank(holder);
        escrow.openCourt{value: COURT_ETH}(id);
        arbitrator.giveRuling(court.disputeOf(id), 2);
        escrow.readRuling(id);

        (Status s, uint256 hAmt, uint256 pAmt) = escrow.settlementOf(id);
        assertEq(uint8(s), uint8(Status.RESOLVED_BY_ARBITRATION));
        assertEq(hAmt, 0, "holder lost the ruling");
        assertEq(pAmt, COMP_FEE, "the fee did not fit, so the winner keeps the pot");
        assertEq(token.balanceOf(feeRecipient), ACT_FEE, "no completion fee at equality");
    }

    /// Same rule through the plain Provider-positive timeout. Pinned separately from the arbitration case to
    /// record that it is not court-specific: every provider-positive terminal (release, claim, co-sign, split,
    /// 50/50 stalemate) routes through one `_close`.
    function test_claim_feeEqualsPrincipal_feeSkippedProviderPaidInFull() public {
        DealTerms memory terms = _p2pTerms();
        terms.principal = COMP_FEE;
        terms.releaseDuration = 0;
        terms.packageIds = _sorted2(passport.packageId(), reputation.packageId());
        PackageMods memory mods;
        mods.passport = address(passport);
        mods.reputation = address(reputation);
        bytes32 id = _activateWith(terms, mods, 1, 1);
        assertEq(token.balanceOf(feeRecipient), ACT_FEE, "activation fee");

        _markFiat(id);
        escrow.claim(id);

        (Status s, uint256 hAmt, uint256 pAmt) = escrow.settlementOf(id);
        assertEq(uint8(s), uint8(Status.CLAIMED));
        assertEq(hAmt, 0, "holder side");
        assertEq(pAmt, COMP_FEE, "the fee did not fit, so the winner keeps the pot");
        assertEq(token.balanceOf(feeRecipient), ACT_FEE, "no completion fee at equality");
    }

    /// The residual the `>=` rule does not remove: one base unit below the principal the fee still fits, so it
    /// is collected and the winner nets a single unit. Pinned so the boundary is explicit rather than
    /// discovered, and so the client-side duty to show net proceeds before signing has a test pointing at it.
    function test_claim_feeOneBelowPrincipal_providerNetsOneUnit() public {
        DealTerms memory terms = _p2pTerms();
        terms.principal = COMP_FEE + 1;
        terms.releaseDuration = 0;
        terms.packageIds = _sorted2(passport.packageId(), reputation.packageId());
        PackageMods memory mods;
        mods.passport = address(passport);
        mods.reputation = address(reputation);
        bytes32 id = _activateWith(terms, mods, 1, 1);

        _markFiat(id);
        escrow.claim(id);

        (Status s, uint256 hAmt, uint256 pAmt) = escrow.settlementOf(id);
        assertEq(uint8(s), uint8(Status.CLAIMED));
        assertEq(pAmt, 1, "winner nets one base unit");
        assertEq(hAmt, 0, "holder side");
        assertEq(token.balanceOf(feeRecipient), ACT_FEE + COMP_FEE, "the fee did fit, so it was collected");
    }

    function test_notify_usesSnapshottedSubject() public {
        _fundBonds();
        bytes32 id = _activateTrio(1, 1);
        _markFiat(id);
        passport.setHuman(holder, bytes32(0));
        vm.prank(holder);
        escrow.release(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.RELEASED));
        assertEq(token.balanceOf(provider), PRINCIPAL - COMP_FEE);
        assertEq(reputation.inFlight(SUB_H, address(token)), 0);
        assertEq(reputation.score(SUB_H, address(token)), 1);
    }

    function test_disposeBondRevert_stillReleased() public {
        UnlockRevertingVault hostile = new UnlockRevertingVault(address(escrow), sink, passport);
        DealTerms memory terms = _p2pTerms();
        terms.packageIds = _sorted3(passport.packageId(), reputation.packageId(), hostile.packageId());
        PackageMods memory mods;
        mods.passport = address(passport);
        mods.reputation = address(reputation);
        mods.bonds = address(hostile);
        bytes32 id = _activateWith(terms, mods, 1, 1);
        _markFiat(id);
        vm.prank(holder);
        escrow.release(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.RELEASED));
        assertEq(token.balanceOf(provider), BOND + PRINCIPAL - COMP_FEE);
    }

    function test_verifyProof_fromFunded() public {
        DealTerms memory terms = _p2pTerms();
        terms.packageIds = _one(zkMod.packageId());
        bytes32 id = _activateWith(terms, _zkMods(), 1, 1);
        vm.expectRevert(Escrow.EdgeOff.selector);
        _markFiat(id);
        escrow.verifyProof(id, abi.encode(id, keccak256("receipt")));
        assertEq(uint8(escrow.status(id)), uint8(Status.RELEASED));
        assertEq(token.balanceOf(provider), BOND + PRINCIPAL - ZK_FEE);
        assertEq(token.balanceOf(feeRecipient), ZK_FEE);
    }

    function test_openCourt_readRuling_holderWin() public {
        DealTerms memory terms = _p2pTerms();
        terms.packageIds = _one(court.packageId());
        terms.arbitrationDuration = 1 days;
        bytes32 id = _activateWith(terms, _courtMods(), 1, 1);
        _markFiat(id);
        vm.prank(holder);
        escrow.openCourt{value: COURT_ETH}(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.ARBITRATION_ACTIVE));

        // What the Kleros Court dapp reads (template mapping) while the parties argue there.
        (bytes32 dealId, address h, address p, address t, string memory amount) = court.caseOf(uint256(id));
        assertEq(dealId, id);
        assertEq(h, holder);
        assertEq(p, provider);
        assertEq(t, address(token));
        assertEq(amount, "1 TUSD");

        arbitrator.giveRuling(court.disputeOf(id), 1);
        escrow.readRuling(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.RESOLVED_BY_ARBITRATION));
        assertEq(token.balanceOf(holder), PRINCIPAL + ACT_FEE + BOND);
    }

    function test_p2p_holderWin_slashesBondToHolder() public {
        _fundBonds();
        DealTerms memory terms = _p2pTerms();
        terms.packageIds = _sorted4(passport.packageId(), reputation.packageId(), vault.packageId(), court.packageId());
        terms.arbitrationDuration = 1 days;
        PackageMods memory mods = _trioMods();
        mods.court = address(court);
        bytes32 id = _activateWith(terms, mods, 1, 1);
        _markFiat(id);
        vm.prank(holder);
        escrow.openCourt{value: COURT_ETH}(id);
        arbitrator.giveRuling(court.disputeOf(id), 1);
        escrow.readRuling(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.RESOLVED_BY_ARBITRATION));
        // A refund is not a trade: no completion fee. The Provider's lock compensates the Holder.
        assertEq(token.balanceOf(holder), PRINCIPAL + BOND);
        assertEq(token.balanceOf(feeRecipient), ACT_FEE);
        assertEq(token.balanceOf(provider), 0);
        assertEq(vault.lockOf(SUB_H, id), 0);
        assertEq(vault.lockOf(SUB_P, id), 0);
        assertEq(vault.available(SUB_H, address(token)), BOND);
    }

    function test_openCourt_fromFiatSent_strictlyBeforeReleaseDeadline() public {
        DealTerms memory terms = _p2pTerms();
        terms.packageIds = _one(court.packageId());
        terms.releaseDuration = 100;
        terms.arbitrationDuration = 1 days;
        bytes32 id = _activateWith(terms, _courtMods(), 1, 1);
        _markFiat(id);
        vm.warp(block.timestamp + 100);

        vm.prank(holder);
        vm.expectRevert(Clocks.TooLate.selector);
        escrow.openCourt{value: COURT_ETH}(id);

        escrow.claim(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.CLAIMED));
    }

    function test_openCourt_fromDisputed_strictlyBeforeDisputeDeadline() public {
        DealTerms memory terms = _p2pTerms();
        terms.packageIds = _one(court.packageId());
        terms.disputeDuration = 100;
        terms.arbitrationDuration = 1 days;
        bytes32 id = _activateWith(terms, _courtMods(), 1, 1);
        _markFiat(id);
        _openDisputed(id);
        vm.warp(block.timestamp + 100);

        vm.prank(holder);
        vm.expectRevert(Clocks.TooLate.selector);
        escrow.openCourt{value: COURT_ETH}(id);

        escrow.forceStalemate(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.STALEMATE));
    }

    function test_completionFeeDrift_packageLosesInvoice() public {
        DriftReputation drift = new DriftReputation(passport, feeRecipient, 0, COMP_FEE, address(escrow));
        DealTerms memory terms = _p2pTerms();
        terms.packageIds = _sorted2(passport.packageId(), drift.packageId());
        PackageMods memory mods;
        mods.passport = address(passport);
        mods.reputation = address(drift);
        bytes32 id = _activateWith(terms, mods, 1, 1);
        drift.setCompletionFee(COMP_FEE + 1);
        _markFiat(id);
        vm.prank(holder);
        escrow.release(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.RELEASED));
        assertEq(token.balanceOf(provider), PRINCIPAL + BOND);
        assertEq(token.balanceOf(feeRecipient), 0);
        token.mint(holder, PRINCIPAL);
        vm.prank(holder);
        token.approve(address(escrow), type(uint256).max);
        bytes32 core = _activateP2P(2, 2);
        assertEq(uint8(escrow.status(core)), uint8(Status.FUNDED));
    }

    function test_zkVerifierDrift_verifyProofReverts() public {
        DriftZk drift = new DriftZk(new VerifierMock(), feeRecipient, ZK_FEE, address(escrow));
        DealTerms memory terms = _p2pTerms();
        terms.packageIds = _one(drift.packageId());
        PackageMods memory mods;
        mods.zk = address(drift);
        bytes32 id = _activateWith(terms, mods, 1, 1);
        drift.setVerifier(new VerifierMock());
        vm.expectRevert(Packages.PackageDrift.selector);
        escrow.verifyProof(id, abi.encode(id, keccak256("receipt")));
        assertEq(uint8(escrow.status(id)), uint8(Status.FUNDED));
    }

    function test_bondSinkDrift_disposeFailOpen() public {
        DriftSinkVault driftVault = new DriftSinkVault(address(escrow), sink, passport);
        DealTerms memory terms = _p2pTerms();
        terms.packageIds = _sorted3(passport.packageId(), reputation.packageId(), driftVault.packageId());
        PackageMods memory mods;
        mods.passport = address(passport);
        mods.reputation = address(reputation);
        mods.bonds = address(driftVault);
        bytes32 id = _activateWith(terms, mods, 1, 1);
        driftVault.setSink(address(0xBADD1));
        _markFiat(id);
        _openDisputed(id);
        vm.warp(block.timestamp + 7200);
        escrow.forceStalemate(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.STALEMATE));
        assertEq(token.balanceOf(sink), 0);
        assertTrue(driftVault.lockOf(SUB_H, id) != 0);
    }

    /// @dev KERNEL-04: a reputation module whose policy getters revert is unreadable drift. It loses the invoice;
    ///      the Core terminal still runs and the principal still reaches the Provider.
    function test_reputationGettersRevert_terminalStillRuns() public {
        RevertingGettersReputation hostile =
            new RevertingGettersReputation(passport, feeRecipient, 0, COMP_FEE, address(escrow));
        DealTerms memory terms = _p2pTerms();
        terms.packageIds = _sorted2(passport.packageId(), hostile.packageId());
        PackageMods memory mods;
        mods.passport = address(passport);
        mods.reputation = address(hostile);
        bytes32 id = _activateWith(terms, mods, 1, 1);
        hostile.setRevertGetters(true);
        _markFiat(id);
        vm.prank(holder);
        escrow.release(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.RELEASED));
        assertEq(token.balanceOf(provider), PRINCIPAL + BOND);
        assertEq(token.balanceOf(feeRecipient), 0);
    }

    /// @dev KERNEL-04, the load-bearing case: `_close` calls `disposeBond` on *every* terminal, so a vault whose
    ///      `sink` getter reverts used to brick all eleven exits including `CANCELLED` — the one with
    ///      `providerBps == 0`, which never reaches `completionInvoice`. The Holder must still get its refund.
    function test_vaultSinkReverts_cancelStillRefundsHolder() public {
        RevertingSinkVault hostile = new RevertingSinkVault(address(escrow), sink, passport);
        DealTerms memory terms = _p2pTerms();
        terms.packageIds = _sorted3(passport.packageId(), reputation.packageId(), hostile.packageId());
        PackageMods memory mods;
        mods.passport = address(passport);
        mods.reputation = address(reputation);
        mods.bonds = address(hostile);
        bytes32 id = _activateWith(terms, mods, 1, 1);
        hostile.setRevertSink(true);
        vm.prank(provider);
        escrow.cancelByProvider(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.CANCELLED));
        assertEq(token.balanceOf(holder), PRINCIPAL + BOND);
        assertTrue(hostile.lockOf(SUB_H, id) != 0);
    }

    /// `PROTECTION.md` §8 promises that when a post-terminal package call reverts, the escrow stays intact and
    /// the call is retried permissionlessly. There is no retry path: `_close` is one-shot, so once `d.status`
    /// is terminal every verb reverts `WrongStatus`. This measures what is actually lost when a module is
    /// briefly unreachable -- a proxy mid-upgrade, a paused implementation, a hostile one.
    function test_postTerminalPackageFailure_leaksInFlightAndBondLockForever() public {
        _fundBonds();
        bytes32 id = _activateTrio(1, 1);
        assertEq(reputation.inFlight(SUB_H, address(token)), PRINCIPAL, "capacity reserved at activation");
        assertEq(vault.lockOf(SUB_H, id), BOND, "bond locked at activation");
        assertEq(vault.available(SUB_H, address(token)), 0, "BOND deposited, BOND locked");

        vm.mockCallRevert(
            address(reputation), abi.encodeWithSelector(IReputation.notifyTerminal.selector), "module down"
        );
        vm.mockCallRevert(address(vault), abi.encodeWithSelector(IBondVault.unlock.selector), "vault down");

        _markFiat(id);
        vm.prank(holder);
        escrow.release(id);

        // KERNEL-04 holds: the Core terminal completed and the principal moved.
        assertEq(uint8(escrow.status(id)), uint8(Status.RELEASED));
        // `_fundBonds` moved both bonds into the vault, so the provider holds only the released principal
        // minus the completion fee. Its own bond is still locked in there.
        assertEq(token.balanceOf(provider), PRINCIPAL - COMP_FEE);
        assertEq(token.balanceOf(holder), 0, "the holder's whole position is the bond stuck in the vault");

        // ...and everything the packages owed is silently lost.
        assertEq(reputation.inFlight(SUB_H, address(token)), PRINCIPAL, "inFlight never released");
        assertEq(reputation.inFlight(SUB_P, address(token)), PRINCIPAL, "inFlight never released");
        assertEq(vault.lockOf(SUB_H, id), BOND, "the lock was never disposed");
        assertEq(vault.available(SUB_H, address(token)), 0, "so the bond is still not withdrawable");

        // The holder owns that bond outright and cannot recover it.
        vm.prank(holder);
        vm.expectRevert(BondVault.InsufficientAvailable.selector);
        vault.withdraw(SUB_H, address(token), BOND);

        // And nothing can repair it: every verb rejects a terminal deal.
        vm.prank(holder);
        vm.expectRevert(Escrow.WrongStatus.selector);
        escrow.release(id);
    }

    function _fundBonds() internal {
        vm.prank(holder);
        vault.deposit(SUB_H, address(token), BOND);
        vm.prank(provider);
        vault.deposit(SUB_P, address(token), BOND);
    }

    function _trioTerms() internal view returns (DealTerms memory terms) {
        terms = _p2pTerms();
        terms.packageIds = _sorted3(passport.packageId(), reputation.packageId(), vault.packageId());
    }

    function _activateTrio(uint256 hNonce, uint256 pNonce) internal returns (bytes32) {
        return _activateWith(_trioTerms(), _trioMods(), hNonce, pNonce);
    }

    function _activateWith(DealTerms memory terms, PackageMods memory mods, uint256 hNonce, uint256 pNonce)
        internal
        returns (bytes32)
    {
        HolderAuthorization memory ha = _holderAuth(terms, hNonce);
        ProviderAgreement memory pa = _providerAuth(terms, pNonce);
        ControllerAcceptance memory ca;
        return escrow.activate(ha, _signHolder(ha), pa, _signProvider(pa), ca, "", mods);
    }

    function _trioMods() internal view returns (PackageMods memory m) {
        m.passport = address(passport);
        m.reputation = address(reputation);
        m.bonds = address(vault);
    }

    function _zkMods() internal view returns (PackageMods memory m) {
        m.zk = address(zkMod);
    }

    function _courtMods() internal view returns (PackageMods memory m) {
        m.court = address(court);
    }

    function test_communityReputation_sameEscrow() public {
        Reputation free = new Reputation(passport, address(0xBEEF), 0, 0, address(escrow));
        DealTerms memory terms = _p2pTerms();
        terms.packageIds = _sorted2(passport.packageId(), free.packageId());
        PackageMods memory mods;
        mods.passport = address(passport);
        mods.reputation = address(free);
        bytes32 id = _activateWith(terms, mods, 9, 9);
        assertEq(uint8(escrow.status(id)), uint8(Status.FUNDED));
        assertEq(escrow.modules(id).reputation, address(free));
        assertEq(token.balanceOf(address(0xBEEF)), 0);
        _markFiat(id);
        vm.prank(holder);
        escrow.release(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.RELEASED));
        assertEq(token.balanceOf(provider), PRINCIPAL + BOND);
        token.mint(holder, PRINCIPAL);
        bytes32 core = _activateP2P(10, 10);
        assertEq(uint8(escrow.status(core)), uint8(Status.FUNDED));
    }

    function test_reputationPassportMismatch_reverts() public {
        PassportMock other = new PassportMock();
        other.setHuman(holder, SUB_H);
        other.setHuman(provider, SUB_P);
        Reputation alien = new Reputation(other, feeRecipient, 0, 0, address(escrow));
        DealTerms memory terms = _p2pTerms();
        terms.packageIds = _sorted2(passport.packageId(), alien.packageId());
        PackageMods memory mods;
        mods.passport = address(passport);
        mods.reputation = address(alien);
        HolderAuthorization memory ha = _holderAuth(terms, 1);
        ProviderAgreement memory pa = _providerAuth(terms, 1);
        ControllerAcceptance memory ca;
        bytes memory hs = _signHolder(ha);
        bytes memory ps = _signProvider(pa);
        vm.expectRevert(Packages.PeerMismatch.selector);
        escrow.activate(ha, hs, pa, ps, ca, "", mods);
    }

    function test_bondsPassportMismatch_reverts() public {
        PassportMock other = new PassportMock();
        BondVault alien = new BondVault(address(escrow), sink, other);
        DealTerms memory terms = _p2pTerms();
        terms.packageIds = _sorted3(passport.packageId(), reputation.packageId(), alien.packageId());
        PackageMods memory mods;
        mods.passport = address(passport);
        mods.reputation = address(reputation);
        mods.bonds = address(alien);
        HolderAuthorization memory ha = _holderAuth(terms, 1);
        ProviderAgreement memory pa = _providerAuth(terms, 1);
        ControllerAcceptance memory ca;
        bytes memory hs = _signHolder(ha);
        bytes memory ps = _signProvider(pa);
        vm.expectRevert(Packages.PeerMismatch.selector);
        escrow.activate(ha, hs, pa, ps, ca, "", mods);
    }

    function test_zkWrapperSwap_unknownPackage() public {
        VerifierMock v = new VerifierMock();
        ZkMock official = new ZkMock(v, feeRecipient, ZK_FEE, address(escrow));
        ZkMock decoy = new ZkMock(v, feeRecipient, ZK_FEE, address(escrow));
        assertTrue(official.packageId() != decoy.packageId());
        DealTerms memory terms = _p2pTerms();
        terms.packageIds = _one(official.packageId());
        PackageMods memory mods;
        mods.zk = address(decoy);
        HolderAuthorization memory ha = _holderAuth(terms, 1);
        ProviderAgreement memory pa = _providerAuth(terms, 1);
        ControllerAcceptance memory ca;
        bytes memory hs = _signHolder(ha);
        bytes memory ps = _signProvider(pa);
        vm.expectRevert(Packages.UnknownPackage.selector);
        escrow.activate(ha, hs, pa, ps, ca, "", mods);
    }

    function test_completionFeeExceedsPrincipal_releaseStillPays() public {
        Reputation fat = new Reputation(passport, feeRecipient, 0, PRINCIPAL + 1, address(escrow));
        DealTerms memory terms = _p2pTerms();
        terms.packageIds = _sorted2(passport.packageId(), fat.packageId());
        PackageMods memory mods;
        mods.passport = address(passport);
        mods.reputation = address(fat);
        bytes32 id = _activateWith(terms, mods, 1, 1);
        _markFiat(id);
        vm.prank(holder);
        escrow.release(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.RELEASED));
        assertEq(token.balanceOf(feeRecipient), 0);
        assertEq(token.balanceOf(provider), BOND + PRINCIPAL);
    }

    function test_zkFeeExceedsPrincipal_verifyStillReleases() public {
        ZkMock fat = new ZkMock(new VerifierMock(), feeRecipient, PRINCIPAL + 1, address(escrow));
        DealTerms memory terms = _p2pTerms();
        terms.packageIds = _one(fat.packageId());
        PackageMods memory mods;
        mods.zk = address(fat);
        bytes32 id = _activateWith(terms, mods, 1, 1);
        escrow.verifyProof(id, abi.encode(id, keccak256("receipt-fat")));
        assertEq(uint8(escrow.status(id)), uint8(Status.RELEASED));
        assertEq(token.balanceOf(feeRecipient), 0);
        assertEq(token.balanceOf(provider), BOND + PRINCIPAL);
    }

    function test_zkFitsCompletionDoesNot_chargesOnlyZk() public {
        Reputation fat = new Reputation(passport, feeRecipient, 0, PRINCIPAL, address(escrow));
        ZkMock zk = new ZkMock(new VerifierMock(), feeRecipient, ZK_FEE, address(escrow));
        DealTerms memory terms = _p2pTerms();
        terms.packageIds = _sorted3(passport.packageId(), fat.packageId(), zk.packageId());
        PackageMods memory mods;
        mods.passport = address(passport);
        mods.reputation = address(fat);
        mods.zk = address(zk);
        bytes32 id = _activateWith(terms, mods, 1, 1);
        escrow.verifyProof(id, abi.encode(id, keccak256("receipt-stack")));
        assertEq(uint8(escrow.status(id)), uint8(Status.RELEASED));
        assertEq(token.balanceOf(feeRecipient), ZK_FEE);
        assertEq(token.balanceOf(provider), BOND + PRINCIPAL - ZK_FEE);
    }

    function test_invoiceLie_kernelChargesHashedFee() public {
        LyingReputation liar = new LyingReputation(passport, feeRecipient, 0, COMP_FEE, address(escrow));
        DealTerms memory terms = _p2pTerms();
        terms.packageIds = _sorted2(passport.packageId(), liar.packageId());
        PackageMods memory mods;
        mods.passport = address(passport);
        mods.reputation = address(liar);
        bytes32 id = _activateWith(terms, mods, 1, 1);
        _markFiat(id);
        vm.prank(holder);
        escrow.release(id);
        assertEq(token.balanceOf(feeRecipient), COMP_FEE);
        assertEq(token.balanceOf(provider), BOND + PRINCIPAL - COMP_FEE);
    }

    function _one(bytes32 a) internal pure returns (bytes32[] memory ids) {
        ids = new bytes32[](1);
        ids[0] = a;
    }

    function _sorted2(bytes32 a, bytes32 b) internal pure returns (bytes32[] memory ids) {
        ids = new bytes32[](2);
        if (a < b) {
            ids[0] = a;
            ids[1] = b;
        } else {
            ids[0] = b;
            ids[1] = a;
        }
    }

    function _sorted3(bytes32 a, bytes32 b, bytes32 c) internal pure returns (bytes32[] memory ids) {
        bytes32[3] memory xs = [a, b, c];
        for (uint256 i; i < 3; i++) {
            for (uint256 j = i + 1; j < 3; j++) {
                if (xs[j] < xs[i]) (xs[i], xs[j]) = (xs[j], xs[i]);
            }
        }
        ids = new bytes32[](3);
        ids[0] = xs[0];
        ids[1] = xs[1];
        ids[2] = xs[2];
    }

    function _sorted4(bytes32 a, bytes32 b, bytes32 c, bytes32 d) internal pure returns (bytes32[] memory ids) {
        bytes32[4] memory xs = [a, b, c, d];
        for (uint256 i; i < 4; i++) {
            for (uint256 j = i + 1; j < 4; j++) {
                if (xs[j] < xs[i]) (xs[i], xs[j]) = (xs[j], xs[i]);
            }
        }
        ids = new bytes32[](4);
        ids[0] = xs[0];
        ids[1] = xs[1];
        ids[2] = xs[2];
        ids[3] = xs[3];
    }
}

contract DriftReputation is IReputation {
    /// @dev Mutable completionFee: simulates a proxy that changes policy mid-deal.
    error Unauthorized();

    IPassport public immutable passport;
    address public immutable operator;
    address public immutable feeRecipient;
    uint256 public immutable activationFee;
    uint256 public completionFee;
    bytes32 public packageId;

    constructor(
        IPassport passport_,
        address feeRecipient_,
        uint256 activationFee_,
        uint256 completionFee_,
        address operator_
    ) {
        passport = passport_;
        feeRecipient = feeRecipient_;
        activationFee = activationFee_;
        completionFee = completionFee_;
        operator = operator_;
        packageId = PackageId.reputation(address(this), feeRecipient_, activationFee_, completionFee_);
    }

    function setCompletionFee(uint256 fee) external {
        completionFee = fee;
        packageId = PackageId.reputation(address(this), feeRecipient, activationFee, fee);
    }

    function invoiceActivation() external view returns (uint256 amount, address recipient) {
        return (activationFee, feeRecipient);
    }

    function invoiceCompletion() external view returns (uint256 amount, address recipient) {
        return (completionFee, feeRecipient);
    }

    function admit(address wallet, address, uint256, address) external returns (bytes32 subject) {
        if (msg.sender != operator) revert Unauthorized();
        subject = passport.identify(wallet);
    }

    function notifyTerminal(bytes32, address, uint256, IReputation.Close) external {
        if (msg.sender != operator) revert Unauthorized();
    }
}

contract DriftZk is IPaymentProof {
    /// @dev Mutable verifier: simulates a proxy that swaps circuit V mid-deal.
    error Unauthorized();
    error WrongDealId();
    error NullifierUsed();

    IVerifier public verifier;
    address public immutable operator;
    address public immutable feeRecipient;
    uint256 public immutable verifyFee;
    bytes32 public packageId;

    mapping(bytes32 paymentNullifier => bool) public used;

    constructor(IVerifier verifier_, address feeRecipient_, uint256 verifyFee_, address operator_) {
        verifier = verifier_;
        feeRecipient = feeRecipient_;
        verifyFee = verifyFee_;
        operator = operator_;
        packageId = PackageId.zk(address(this), address(verifier_), feeRecipient_, verifyFee_);
    }

    function setVerifier(IVerifier v) external {
        verifier = v;
        packageId = PackageId.zk(address(this), address(v), feeRecipient, verifyFee);
    }

    function invoiceVerify() external view returns (uint256 amount, address recipient) {
        return (verifyFee, feeRecipient);
    }

    function verifyProof(bytes32 dealId, bytes calldata proof) external returns (bytes32 paymentNullifier) {
        if (msg.sender != operator) revert Unauthorized();
        bytes32 proofDealId;
        (proofDealId, paymentNullifier) = verifier.verify(proof);
        if (proofDealId != dealId) revert WrongDealId();
        if (used[paymentNullifier]) revert NullifierUsed();
        used[paymentNullifier] = true;
    }
}

contract DriftSinkVault is IBondVault {
    /// @dev Mutable sink: simulates a proxy that changes the burn sink mid-deal.
    error Hostile();

    address public immutable operator;
    IPassport public immutable passport;
    address public sink;
    bytes32 public packageId;

    mapping(bytes32 subject => mapping(bytes32 dealId => uint256)) public lockOf;

    constructor(address operator_, address sink_, IPassport passport_) {
        operator = operator_;
        sink = sink_;
        passport = passport_;
        packageId = PackageId.bonds(address(this), sink_);
    }

    function setSink(address s) external {
        sink = s;
        packageId = PackageId.bonds(address(this), s);
    }

    function available(bytes32, address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function locked(bytes32, address) external pure returns (uint256) {
        return 0;
    }

    function reserve(bytes32 subject, address, bytes32 dealId, uint256 principal) external {
        if (msg.sender != operator) revert Hostile();
        lockOf[subject][dealId] = (principal + 9) / 10;
    }

    function unlock(bytes32 subject, address, bytes32 dealId) external {
        if (msg.sender != operator) revert Hostile();
        delete lockOf[subject][dealId];
    }

    function slash(bytes32, bytes32, address, bytes32, address) external pure {}

    function burn(bytes32 subjectA, bytes32 subjectB, address token, bytes32 dealId) external {
        if (msg.sender != operator) revert Hostile();
        uint256 amount = lockOf[subjectA][dealId] + lockOf[subjectB][dealId];
        delete lockOf[subjectA][dealId];
        delete lockOf[subjectB][dealId];
        IERC20(token).transfer(sink, amount);
    }
}

contract UnlockRevertingVault is IBondVault {
    error Hostile();

    address public immutable operator;
    address public immutable sink;
    IPassport public immutable passport;
    bytes32 public immutable packageId;

    constructor(address operator_, address sink_, IPassport passport_) {
        operator = operator_;
        sink = sink_;
        passport = passport_;
        packageId = PackageId.bonds(address(this), sink_);
    }

    function available(bytes32, address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function locked(bytes32, address) external pure returns (uint256) {
        return 0;
    }

    function reserve(bytes32, address, bytes32, uint256) external view {
        if (msg.sender != operator) revert Hostile();
    }

    function unlock(bytes32, address, bytes32) external pure {
        revert Hostile();
    }

    function slash(bytes32, bytes32, address, bytes32, address) external pure {
        revert Hostile();
    }

    function burn(bytes32, bytes32, address, bytes32) external pure {
        revert Hostile();
    }
}

/// @dev invoiceCompletion lies; hashed completionFee is the honest amount.
contract LyingReputation is IReputation {
    error Unauthorized();

    IPassport public immutable passport;
    address public immutable operator;
    address public immutable feeRecipient;
    uint256 public immutable activationFee;
    uint256 public immutable completionFee;
    bytes32 public immutable packageId;

    constructor(
        IPassport passport_,
        address feeRecipient_,
        uint256 activationFee_,
        uint256 completionFee_,
        address operator_
    ) {
        passport = passport_;
        feeRecipient = feeRecipient_;
        activationFee = activationFee_;
        completionFee = completionFee_;
        operator = operator_;
        packageId = PackageId.reputation(address(this), feeRecipient_, activationFee_, completionFee_);
    }

    function invoiceActivation() external view returns (uint256 amount, address recipient) {
        return (activationFee, feeRecipient);
    }

    function invoiceCompletion() external pure returns (uint256 amount, address recipient) {
        return (type(uint256).max, address(0xBAD));
    }

    function admit(address wallet, address, uint256, address) external returns (bytes32 subject) {
        if (msg.sender != operator) revert Unauthorized();
        subject = passport.identify(wallet);
    }

    function notifyTerminal(bytes32, address, uint256, IReputation.Close) external {
        if (msg.sender != operator) revert Unauthorized();
    }
}

contract RevertingGettersReputation is IReputation {
    /// @dev Simulates a proxy whose implementation was upgraded, paused or self-destructed after activation: the
    ///      policy getters the kernel needs to evaluate drift stop answering. `passport` and `packageId` stay live
    ///      so resolution and peer binding still succeed and the fault is isolated to the invoice reads.
    error Unauthorized();
    error Unavailable();

    IPassport public immutable passport;
    address public immutable operator;
    bytes32 public immutable packageId;
    address internal _feeRecipient;
    uint256 internal _activationFee;
    uint256 internal _completionFee;
    bool public revertGetters;

    constructor(
        IPassport passport_,
        address feeRecipient_,
        uint256 activationFee_,
        uint256 completionFee_,
        address operator_
    ) {
        passport = passport_;
        operator = operator_;
        _feeRecipient = feeRecipient_;
        _activationFee = activationFee_;
        _completionFee = completionFee_;
        packageId = PackageId.reputation(address(this), feeRecipient_, activationFee_, completionFee_);
    }

    function setRevertGetters(bool on) external {
        revertGetters = on;
    }

    function feeRecipient() external view returns (address) {
        if (revertGetters) revert Unavailable();
        return _feeRecipient;
    }

    function activationFee() external view returns (uint256) {
        if (revertGetters) revert Unavailable();
        return _activationFee;
    }

    function completionFee() external view returns (uint256) {
        if (revertGetters) revert Unavailable();
        return _completionFee;
    }

    function invoiceActivation() external view returns (uint256 amount, address recipient) {
        if (revertGetters) revert Unavailable();
        return (_activationFee, _feeRecipient);
    }

    function invoiceCompletion() external view returns (uint256 amount, address recipient) {
        if (revertGetters) revert Unavailable();
        return (_completionFee, _feeRecipient);
    }

    function admit(address wallet, address, uint256, address) external returns (bytes32 subject) {
        if (msg.sender != operator) revert Unauthorized();
        subject = passport.identify(wallet);
    }

    function notifyTerminal(bytes32, address, uint256, IReputation.Close) external {
        if (msg.sender != operator) revert Unauthorized();
    }
}

contract RevertingSinkVault is IBondVault {
    /// @dev Simulates a vault behind a proxy that stops answering `sink()`. `disposeBond` reads it on every
    ///      terminal to evaluate drift, so this is the getter that used to be able to brick all eleven exits.
    error Hostile();
    error Unavailable();

    address public immutable operator;
    IPassport public immutable passport;
    bytes32 public immutable packageId;
    address internal _sink;
    bool public revertSink;

    mapping(bytes32 subject => mapping(bytes32 dealId => uint256)) public lockOf;

    constructor(address operator_, address sink_, IPassport passport_) {
        operator = operator_;
        passport = passport_;
        _sink = sink_;
        packageId = PackageId.bonds(address(this), sink_);
    }

    function setRevertSink(bool on) external {
        revertSink = on;
    }

    function sink() external view returns (address) {
        if (revertSink) revert Unavailable();
        return _sink;
    }

    function available(bytes32, address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function locked(bytes32, address) external pure returns (uint256) {
        return 0;
    }

    function reserve(bytes32 subject, address, bytes32 dealId, uint256 principal) external {
        if (msg.sender != operator) revert Hostile();
        lockOf[subject][dealId] = (principal + 9) / 10;
    }

    function unlock(bytes32 subject, address, bytes32 dealId) external {
        if (msg.sender != operator) revert Hostile();
        delete lockOf[subject][dealId];
    }

    function slash(bytes32, bytes32, address, bytes32, address) external pure {}

    function burn(bytes32, bytes32, address, bytes32) external pure {}
}
