// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Status, DealTerms, HolderAuthorization, ProviderAgreement, ControllerAcceptance} from "../src/libraries/Types.sol";
import {Escrow} from "../src/Escrow.sol";
import {TestToken} from "../src/TestToken.sol";
import {PassportMock} from "../src/packages/PassportMock.sol";
import {Reputation} from "../src/packages/Reputation.sol";
import {BondVault} from "../src/packages/BondVault.sol";
import {ZkMock} from "../src/packages/ZkMock.sol";
import {VerifierMock} from "../src/mocks/VerifierMock.sol";
import {ArbitrationMock} from "../src/packages/ArbitrationMock.sol";
import {IPassport} from "../src/packages/interfaces/IPassport.sol";
import {BaseTest} from "./Base.t.sol";

contract PackagesTest is BaseTest {
    uint256 internal constant ACT_FEE = 100_000;
    uint256 internal constant COMP_FEE = 50_000;
    uint256 internal constant ZK_FEE = 10_000;
    uint256 internal constant COURT_FEE = 1_000_000;
    uint256 internal constant BOND = PRINCIPAL / 10;
    bytes32 internal constant SUB_H = keccak256("human-h");
    bytes32 internal constant SUB_P = keccak256("human-p");

    PassportMock internal passport;
    Reputation internal reputation;
    BondVault internal vault;
    ZkMock internal zkMod;
    ArbitrationMock internal arb;
    address internal feeRecipient = address(0xFEE);
    address internal sink = address(0xdeaD);
    address internal tribunal = address(0x71B);

    function setUp() public override {
        holder = vm.addr(holderPk);
        provider = vm.addr(providerPk);
        controller = vm.addr(controllerPk);
        token = new TestToken();
        passport = new PassportMock();
        reputation = new Reputation(passport, feeRecipient, ACT_FEE, COMP_FEE);
        VerifierMock verifier = new VerifierMock();
        zkMod = new ZkMock(verifier, feeRecipient, ZK_FEE);
        uint64 n = vm.getNonce(address(this));
        address predicted = vm.computeCreateAddress(address(this), n + 2);
        vault = new BondVault(predicted, sink, passport);
        arb = new ArbitrationMock(tribunal, address(token), COURT_FEE, 1 days, predicted);
        escrow = new Escrow(address(passport), address(reputation), address(vault), address(zkMod), address(arb));
        assertEq(address(escrow), predicted);

        passport.setHuman(holder, SUB_H);
        passport.setHuman(provider, SUB_P);
        token.mint(holder, PRINCIPAL + ACT_FEE + BOND + COURT_FEE);
        token.mint(provider, BOND);
        vm.prank(holder);
        token.approve(address(escrow), type(uint256).max);
        vm.prank(holder);
        token.approve(address(vault), type(uint256).max);
        vm.prank(holder);
        token.approve(address(arb), type(uint256).max);
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
        vm.expectRevert(Escrow.UnknownPackage.selector);
        escrow.activate(ha, hs, pa, ps, ca, "");
        assertFalse(escrow.used(holder, 1));
    }

    function test_zkAndArbIncompatible() public {
        DealTerms memory terms = _p2pTerms();
        terms.packageIds = _sorted2(escrow.zkId(), escrow.arbId());
        HolderAuthorization memory ha = _holderAuth(terms, 1);
        ProviderAgreement memory pa = _providerAuth(terms, 1);
        ControllerAcceptance memory ca;
        bytes memory hs = _signHolder(ha);
        bytes memory ps = _signProvider(pa);
        vm.expectRevert(Escrow.IncompatiblePackages.selector);
        escrow.activate(ha, hs, pa, ps, ca, "");
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
        escrow.activate(ha, hs, pa, ps, ca, "");
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
        assertEq(token.balanceOf(holder), PRINCIPAL + COURT_FEE);
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

    function test_notifyRevert_stillReleased() public {
        _fundBonds();
        bytes32 id = _activateTrio(1, 1);
        _markFiat(id);
        passport.setHuman(holder, bytes32(0));
        vm.prank(holder);
        escrow.release(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.RELEASED));
        assertEq(token.balanceOf(provider), PRINCIPAL - COMP_FEE);
    }

    function test_verifyProof_fromFunded() public {
        DealTerms memory terms = _p2pTerms();
        terms.packageIds = _one(escrow.zkId());
        bytes32 id = _activateP2PWith(terms, 1, 1);
        vm.expectRevert(Escrow.EdgeOff.selector);
        _markFiat(id);
        escrow.verifyProof(id, abi.encode(id, keccak256("receipt")));
        assertEq(uint8(escrow.status(id)), uint8(Status.RELEASED));
        assertEq(token.balanceOf(provider), BOND + PRINCIPAL - ZK_FEE);
        assertEq(token.balanceOf(feeRecipient), ZK_FEE);
    }

    function test_openCourt_readRuling_holderWin() public {
        DealTerms memory terms = _p2pTerms();
        terms.packageIds = _one(escrow.arbId());
        terms.arbitrationDuration = 1 days;
        bytes32 id = _activateP2PWith(terms, 1, 1);
        _markFiat(id);
        vm.prank(holder);
        escrow.openCourt(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.ARBITRATION_ACTIVE));
        arb.submitRuling(id, ArbitrationMock.Ruling.HolderWin);
        escrow.readRuling(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.RESOLVED_BY_ARBITRATION));
        assertEq(token.balanceOf(holder), PRINCIPAL + ACT_FEE + BOND);
        assertEq(token.balanceOf(tribunal), COURT_FEE);
    }

    function _fundBonds() internal {
        vm.prank(holder);
        vault.deposit(SUB_H, address(token), BOND);
        vm.prank(provider);
        vault.deposit(SUB_P, address(token), BOND);
    }

    function _trioTerms() internal view returns (DealTerms memory terms) {
        terms = _p2pTerms();
        terms.packageIds = _sorted3(escrow.passportId(), escrow.reputationId(), escrow.bondsId());
    }

    function _activateTrio(uint256 hNonce, uint256 pNonce) internal returns (bytes32) {
        return _activateP2PWith(_trioTerms(), hNonce, pNonce);
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
}
