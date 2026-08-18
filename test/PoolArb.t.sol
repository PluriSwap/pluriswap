// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    Status,
    DealTerms,
    HolderAuthorization,
    ProviderAgreement,
    ControllerAcceptance
} from "../src/libraries/Types.sol";
import {Consent} from "../src/libraries/Consent.sol";
import {Escrow} from "../src/Escrow.sol";
import {TestToken} from "../src/TestToken.sol";
import {KlerosAdapter} from "../src/packages/KlerosAdapter.sol";
import {MockArbitratorV2} from "../src/mocks/MockArbitratorV2.sol";
import {Pool} from "../src/pools/Pool.sol";
import {PoolFactory} from "../src/pools/PoolFactory.sol";
import {BaseTest} from "./Base.t.sol";

contract PoolArbTest is BaseTest {
    uint256 internal constant COURT_ETH = 0.01 ether;
    uint16 internal constant FEE_BPS = 100;

    MockArbitratorV2 internal arbitrator;
    KlerosAdapter internal court;
    PoolFactory internal factory;
    Pool internal pool;
    uint256 internal fee;

    function setUp() public override {
        holder = vm.addr(holderPk);
        provider = vm.addr(providerPk);
        controller = vm.addr(controllerPk);
        token = new TestToken();
        bytes memory extraData = abi.encode(uint256(1), uint256(3), uint256(1));
        arbitrator = new MockArbitratorV2(COURT_ETH);
        uint64 n = vm.getNonce(address(this));
        address predicted = vm.computeCreateAddress(address(this), n + 1);
        court = new KlerosAdapter(address(arbitrator), extraData, 0, "", predicted, address(0));
        escrow = new Escrow(address(0), address(0), address(0), address(0), address(court));
        assertEq(address(escrow), predicted);

        factory = new PoolFactory();
        address[] memory sps = new address[](1);
        sps[0] = holder;
        address[] memory cs = new address[](1);
        cs[0] = controller;
        address[] memory deps = new address[](1);
        deps[0] = holder;
        pool = Pool(factory.createPool(sps, address(token), address(escrow), cs, false, deps, FEE_BPS));
        fee = PRINCIPAL * FEE_BPS / 10_000;

        token.mint(holder, PRINCIPAL + fee);
        vm.startPrank(holder);
        token.approve(address(pool), type(uint256).max);
        pool.deposit(PRINCIPAL + fee);
        vm.stopPrank();
        vm.deal(controller, 1 ether);
    }

    function test_arb_providerWin_paysFeeAndReadsSettlementOf() public {
        bytes32 id = _activateArb(1, 1, 1);
        vm.prank(provider);
        escrow.markFiat(id);
        vm.prank(controller);
        escrow.openCourt{value: COURT_ETH}(id);
        arbitrator.giveRuling(court.disputeOf(id), 2);
        escrow.readRuling(id);

        (Status st, uint256 holderAmt, uint256 providerAmt) = escrow.settlementOf(id);
        assertEq(uint8(st), uint8(Status.RESOLVED_BY_ARBITRATION));
        assertEq(holderAmt, 0);
        assertEq(providerAmt, PRINCIPAL);

        pool.reconcile(1, 1, 1);
        assertEq(pool.consumed(), PRINCIPAL + fee);
        assertEq(pool.idle(), 0);
        assertEq(pool.nav(), 0);
        assertEq(token.balanceOf(controller), fee);
        assertEq(token.balanceOf(provider), PRINCIPAL);
    }

    function test_arb_holderWin_returnsFee() public {
        bytes32 id = _activateArb(1, 1, 1);
        vm.prank(provider);
        escrow.markFiat(id);
        vm.prank(controller);
        escrow.openCourt{value: COURT_ETH}(id);
        arbitrator.giveRuling(court.disputeOf(id), 1);
        escrow.readRuling(id);

        (Status st, uint256 holderAmt,) = escrow.settlementOf(id);
        assertEq(uint8(st), uint8(Status.RESOLVED_BY_ARBITRATION));
        assertEq(holderAmt, PRINCIPAL);

        pool.reconcile(1, 1, 1);
        assertEq(pool.consumed(), 0);
        assertEq(pool.idle(), PRINCIPAL + fee);
        assertEq(pool.nav(), PRINCIPAL + fee);
        assertEq(token.balanceOf(controller), 0);
    }

    function _activateArb(uint256 holderNonce, uint256 providerNonce, uint256 controllerNonce)
        internal
        returns (bytes32)
    {
        DealTerms memory terms = _p2pTerms();
        terms.holder = address(pool);
        terms.controller = controller;
        terms.arbitrationDuration = 1 days;
        terms.packageIds = new bytes32[](1);
        terms.packageIds[0] = escrow.arbId();
        HolderAuthorization memory ha = _holderAuth(terms, holderNonce);
        ProviderAgreement memory pa = _providerAuth(terms, providerNonce);
        ControllerAcceptance memory ca = _controllerAuth(terms, controllerNonce);
        vm.prank(controller);
        pool.authorize(ha);
        return escrow.activate(ha, "", pa, _signProvider(pa), ca, _signController(ca));
    }
}
