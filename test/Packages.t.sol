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
import {TestToken} from "../src/TestToken.sol";
import {PassportMock} from "../src/packages/PassportMock.sol";
import {Reputation} from "../src/packages/Reputation.sol";
import {BondVault} from "../src/packages/BondVault.sol";
import {ZkMock} from "../src/packages/ZkMock.sol";
import {VerifierMock} from "../src/mocks/VerifierMock.sol";
import {KlerosAdapter} from "../src/packages/KlerosAdapter.sol";
import {MockArbitratorV2} from "../src/mocks/MockArbitratorV2.sol";
import {IPassport} from "../src/packages/interfaces/IPassport.sol";
import {IBondVault} from "../src/packages/interfaces/IBondVault.sol";
import {PackageId} from "../src/packages/PackageId.sol";
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
        court = new KlerosAdapter(address(arbitrator), extraData, 0, "", predicted, address(0));
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
        vm.expectRevert(Escrow.UnknownPackage.selector);
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
        vm.expectRevert(Escrow.IncompatiblePackages.selector);
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

    function test_disposeBondRevert_stillReleased() public {
        UnlockRevertingVault hostile = new UnlockRevertingVault(address(escrow), sink);
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
        arbitrator.giveRuling(court.disputeOf(id), 1);
        escrow.readRuling(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.RESOLVED_BY_ARBITRATION));
        assertEq(token.balanceOf(holder), PRINCIPAL + ACT_FEE + BOND);
    }

    function test_p2p_holderWin_slashesBondToHolder() public {
        _fundBonds();
        DealTerms memory terms = _p2pTerms();
        terms.packageIds = _sorted4(
            passport.packageId(), reputation.packageId(), vault.packageId(), court.packageId()
        );
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
        assertEq(token.balanceOf(holder), PRINCIPAL - COMP_FEE + BOND);
        assertEq(token.balanceOf(feeRecipient), ACT_FEE + COMP_FEE);
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
        assertEq(uint8(escrow.status(id)), uint8(Status.RELEASED));
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

contract UnlockRevertingVault is IBondVault {
    error Hostile();

    address public immutable operator;
    address public immutable sink;
    bytes32 public immutable packageId;

    constructor(address operator_, address sink_) {
        operator = operator_;
        sink = sink_;
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

    function slash(bytes32, bytes32, address, bytes32, address, address) external pure {
        revert Hostile();
    }

    function burn(bytes32, bytes32, address, bytes32) external pure {
        revert Hostile();
    }
}
