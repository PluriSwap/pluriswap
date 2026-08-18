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
import {Pool} from "../src/pools/Pool.sol";
import {PoolFactory} from "../src/pools/PoolFactory.sol";
import {BaseTest} from "./Base.t.sol";

contract PoolTest is BaseTest {
    PoolFactory internal factory;
    Pool internal pool;

    function setUp() public override {
        super.setUp();
        factory = new PoolFactory();
        pool = _privatePool(0);
        token.mint(holder, PRINCIPAL);
        vm.startPrank(holder);
        token.approve(address(pool), type(uint256).max);
        pool.deposit(PRINCIPAL);
        vm.stopPrank();
    }

    function test_private_onlyDepositors() public {
        address outsider = address(0xBEEF);
        token.mint(outsider, PRINCIPAL);
        vm.startPrank(outsider);
        token.approve(address(pool), PRINCIPAL);
        vm.expectRevert(Pool.Unauthorized.selector);
        pool.deposit(PRINCIPAL);
        vm.stopPrank();
    }

    function test_private_sponsorNotDepositorCannotDeposit() public {
        address extraSponsor = address(0x51);
        address[] memory sps = new address[](2);
        sps[0] = holder;
        sps[1] = extraSponsor;
        address[] memory cs = new address[](0);
        address[] memory deps = new address[](1);
        deps[0] = holder;
        Pool p = Pool(factory.createPool(sps, address(token), address(escrow), cs, false, deps, 0));
        token.mint(extraSponsor, PRINCIPAL);
        vm.startPrank(extraSponsor);
        token.approve(address(p), PRINCIPAL);
        vm.expectRevert(Pool.Unauthorized.selector);
        p.deposit(PRINCIPAL);
        vm.stopPrank();
        assertTrue(p.isAgent(extraSponsor));
    }

    function test_open_anyoneDeposits() public {
        address[] memory sps = new address[](1);
        sps[0] = holder;
        address[] memory none = new address[](0);
        Pool p = Pool(factory.createPool(sps, address(token), address(escrow), none, true, none, 0));
        address lp = address(0x11);
        token.mint(lp, PRINCIPAL);
        vm.startPrank(lp);
        token.approve(address(p), PRINCIPAL);
        p.deposit(PRINCIPAL);
        vm.stopPrank();
        assertEq(p.sharesOf(lp), PRINCIPAL);
        assertEq(p.idle(), PRINCIPAL);
    }

    function test_secondMint_proportionalToNav() public {
        address[] memory sps = new address[](1);
        sps[0] = holder;
        address[] memory none = new address[](0);
        Pool p = Pool(factory.createPool(sps, address(token), address(escrow), none, true, none, 0));
        token.mint(holder, PRINCIPAL * 2);
        vm.startPrank(holder);
        token.approve(address(p), type(uint256).max);
        p.deposit(PRINCIPAL);
        p.deposit(PRINCIPAL);
        vm.stopPrank();
        assertEq(p.sharesOf(holder), PRINCIPAL * 2);
        assertEq(p.totalShares(), PRINCIPAL * 2);
    }

    function test_redeem_burnsShares() public {
        uint256 before = token.balanceOf(holder);
        vm.prank(holder);
        pool.redeem(PRINCIPAL);
        assertEq(pool.sharesOf(holder), 0);
        assertEq(pool.idle(), 0);
        assertEq(token.balanceOf(holder), before + PRINCIPAL);
    }

    function test_firstDeposit_floor() public {
        address[] memory sps = new address[](1);
        sps[0] = holder;
        address[] memory none = new address[](0);
        Pool p = Pool(factory.createPool(sps, address(token), address(escrow), none, true, none, 0));
        token.mint(holder, 1);
        vm.startPrank(holder);
        token.approve(address(p), 1);
        vm.expectRevert(Pool.FirstDepositTooSmall.selector);
        p.deposit(1);
        vm.stopPrank();
    }

    function test_setController_cannotUnsetSponsor() public {
        vm.prank(holder);
        vm.expectRevert(Pool.IsSponsor.selector);
        pool.setController(holder, false);
        assertTrue(pool.isAgent(holder));
    }

    function test_designated_isAgent_lpIsNot() public {
        address lp = address(0x11);
        assertTrue(pool.isAgent(controller));
        assertFalse(pool.isAgent(lp));
        vm.prank(holder);
        pool.setController(lp, true);
        assertTrue(pool.isAgent(lp));
    }

    function test_deficient_recap() public {
        deal(address(token), address(pool), 0);
        pool.sync();
        assertEq(uint8(pool.life()), uint8(Pool.Life.DEFICIENT));
        token.mint(holder, PRINCIPAL);
        vm.prank(holder);
        pool.deposit(PRINCIPAL);
        assertEq(uint8(pool.life()), uint8(Pool.Life.ACTIVE));
    }

    function test_authorize_activateSameTypedData() public {
        bytes32 id = _activatePool(1, 1, 1);
        assertEq(uint8(escrow.status(id)), uint8(Status.FUNDED));
        assertEq(token.balanceOf(address(pool)), 0);
        assertEq(token.balanceOf(address(escrow)), PRINCIPAL);
        assertEq(pool.idle(), 0);
        assertEq(pool.locked(), PRINCIPAL);
        assertTrue(escrow.used(address(pool), 1));
    }

    function test_authorize_rejectsUnknownController() public {
        DealTerms memory terms = _poolHolderTerms();
        terms.controller = address(0xBEEF);
        HolderAuthorization memory ha = _holderAuth(terms, 1);
        vm.prank(address(0xBEEF));
        vm.expectRevert(Pool.Unauthorized.selector);
        pool.authorize(ha);
    }

    function test_authorize_rejectsWhenIdleShort() public {
        vm.prank(holder);
        pool.redeem(PRINCIPAL);
        HolderAuthorization memory ha = _holderAuth(_poolHolderTerms(), 1);
        vm.prank(controller);
        vm.expectRevert(Pool.InsufficientIdle.selector);
        pool.authorize(ha);
    }

    function test_authorize_sponsorCanBeController() public {
        address[] memory sps = new address[](1);
        sps[0] = holder;
        address[] memory none = new address[](0);
        address[] memory deps = new address[](1);
        deps[0] = holder;
        Pool p = Pool(factory.createPool(sps, address(token), address(escrow), none, false, deps, 0));
        token.mint(holder, PRINCIPAL);
        vm.startPrank(holder);
        token.approve(address(p), PRINCIPAL);
        p.deposit(PRINCIPAL);
        vm.stopPrank();

        DealTerms memory terms = _p2pTerms();
        terms.holder = address(p);
        terms.controller = holder;
        HolderAuthorization memory ha = _holderAuth(terms, 1);
        ProviderAgreement memory pa = _providerAuth(terms, 1);
        ControllerAcceptance memory ca = _controllerAuth(terms, 1);
        vm.prank(holder);
        p.authorize(ha);
        bytes32 id = escrow.activate(ha, "", pa, _signProvider(pa), ca, _signHolderAsController(ca));
        assertEq(uint8(escrow.status(id)), uint8(Status.FUNDED));
    }

    function test_twoConcurrentDealsDoNotOverAllocate() public {
        token.mint(holder, PRINCIPAL);
        vm.prank(holder);
        pool.deposit(PRINCIPAL);

        _activatePool(1, 1, 1);
        _activatePool(2, 2, 2);
        assertEq(pool.idle(), 0);
        assertEq(pool.locked(), PRINCIPAL * 2);
        assertEq(token.balanceOf(address(escrow)), PRINCIPAL * 2);

        HolderAuthorization memory ha = _holderAuth(_poolHolderTerms(), 3);
        vm.prank(controller);
        vm.expectRevert(Pool.InsufficientIdle.selector);
        pool.authorize(ha);
    }

    function test_kickController_futureOnly() public {
        bytes32 id = _activatePool(1, 1, 1);
        vm.prank(holder);
        pool.setController(controller, false);

        HolderAuthorization memory ha = _holderAuth(_poolHolderTerms(), 2);
        vm.prank(controller);
        vm.expectRevert(Pool.Unauthorized.selector);
        pool.authorize(ha);

        vm.prank(provider);
        escrow.cancelByProvider(id);
        assertEq(token.balanceOf(address(pool)), PRINCIPAL);
        assertEq(token.balanceOf(controller), 0);
    }

    function test_unlock_afterDeadlineIfNonceUnused() public {
        HolderAuthorization memory ha = _holderAuth(_poolHolderTerms(), 1);
        vm.prank(controller);
        pool.authorize(ha);
        assertEq(pool.locked(), PRINCIPAL);

        vm.expectRevert(Pool.DeadlineActive.selector);
        pool.unlock(1);

        vm.warp(ha.deadline + 1);
        pool.unlock(1);
        assertEq(pool.idle(), PRINCIPAL);
        assertEq(pool.locked(), 0);
        assertEq(pool.isValidSignature(_typed(Consent.hashHolderAuthorization(ha)), ""), bytes4(0));
    }

    function test_unlock_revertsIfActivated() public {
        _activatePool(1, 1, 1);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(Pool.NonceConsumed.selector);
        pool.unlock(1);
    }

    function test_reconcile_cancelReturnsIdle() public {
        bytes32 id = _activatePool(1, 1, 1);
        vm.prank(provider);
        escrow.cancelByProvider(id);
        pool.reconcile(1, 1, 1);
        assertEq(pool.idle(), PRINCIPAL);
        assertEq(pool.locked(), 0);
        assertEq(pool.consumed(), 0);
        assertEq(uint8(pool.life()), uint8(Pool.Life.ACTIVE));
    }

    function test_reconcile_releaseConsumes() public {
        bytes32 id = _activatePool(1, 1, 1);
        vm.prank(provider);
        escrow.markFiat(id);
        vm.prank(controller);
        escrow.release(id);
        pool.reconcile(1, 1, 1);
        assertEq(pool.idle(), 0);
        assertEq(pool.locked(), 0);
        assertEq(pool.consumed(), PRINCIPAL);
        assertEq(token.balanceOf(provider), PRINCIPAL);
    }

    function test_fee_reservedAndPaidOnRelease() public {
        uint16 bps = 100;
        uint256 fee = PRINCIPAL * bps / 10_000;
        Pool p = _privatePool(bps);
        token.mint(holder, PRINCIPAL + fee);
        vm.startPrank(holder);
        token.approve(address(p), type(uint256).max);
        p.deposit(PRINCIPAL + fee);
        vm.stopPrank();

        DealTerms memory terms = _p2pTerms();
        terms.holder = address(p);
        terms.controller = controller;
        HolderAuthorization memory ha = _holderAuth(terms, 1);
        ProviderAgreement memory pa = _providerAuth(terms, 1);
        ControllerAcceptance memory ca = _controllerAuth(terms, 1);
        vm.prank(controller);
        p.authorize(ha);
        assertEq(p.locked(), PRINCIPAL + fee);
        assertEq(p.idle(), 0);
        assertEq(token.balanceOf(address(p)), PRINCIPAL + fee);

        bytes32 id = escrow.activate(ha, "", pa, _signProvider(pa), ca, _signController(ca));
        assertEq(token.balanceOf(address(escrow)), PRINCIPAL);
        assertEq(token.balanceOf(address(p)), fee);

        vm.prank(provider);
        escrow.markFiat(id);
        vm.prank(controller);
        escrow.release(id);
        p.reconcile(1, 1, 1);
        assertEq(p.consumed(), PRINCIPAL + fee);
        assertEq(p.idle(), 0);
        assertEq(token.balanceOf(controller), fee);
        assertEq(token.balanceOf(provider), PRINCIPAL);
    }

    function test_fee_returnedOnFullRefund() public {
        uint16 bps = 100;
        uint256 fee = PRINCIPAL * bps / 10_000;
        Pool p = _privatePool(bps);
        token.mint(holder, PRINCIPAL + fee);
        vm.startPrank(holder);
        token.approve(address(p), type(uint256).max);
        p.deposit(PRINCIPAL + fee);
        vm.stopPrank();

        DealTerms memory terms = _p2pTerms();
        terms.holder = address(p);
        terms.controller = controller;
        HolderAuthorization memory ha = _holderAuth(terms, 1);
        ProviderAgreement memory pa = _providerAuth(terms, 1);
        ControllerAcceptance memory ca = _controllerAuth(terms, 1);
        vm.prank(controller);
        p.authorize(ha);
        bytes32 id = escrow.activate(ha, "", pa, _signProvider(pa), ca, _signController(ca));
        vm.prank(provider);
        escrow.cancelByProvider(id);
        p.reconcile(1, 1, 1);
        assertEq(p.idle(), PRINCIPAL + fee);
        assertEq(p.consumed(), 0);
        assertEq(token.balanceOf(controller), 0);
    }

    function test_feeBpsChange_doesNotAffectOpenAuth() public {
        uint16 bps = 100;
        uint256 fee = PRINCIPAL * bps / 10_000;
        Pool p = _privatePool(bps);
        token.mint(holder, PRINCIPAL + fee);
        vm.startPrank(holder);
        token.approve(address(p), type(uint256).max);
        p.deposit(PRINCIPAL + fee);
        vm.stopPrank();

        DealTerms memory terms = _p2pTerms();
        terms.holder = address(p);
        terms.controller = controller;
        HolderAuthorization memory ha = _holderAuth(terms, 1);
        vm.prank(controller);
        p.authorize(ha);
        vm.prank(holder);
        p.setControllerFeeBps(500);
        vm.warp(ha.deadline + 1);
        p.unlock(1);
        assertEq(p.idle(), PRINCIPAL + fee);
        assertEq(p.locked(), 0);
    }

    function test_windDown_rejectsNewAuthorize() public {
        vm.prank(holder);
        pool.windDown();
        HolderAuthorization memory ha = _holderAuth(_poolHolderTerms(), 1);
        vm.prank(controller);
        vm.expectRevert(Pool.WrongLife.selector);
        pool.authorize(ha);
    }

    function test_windDown_liveDealThenRedeemCloses() public {
        bytes32 id = _activatePool(1, 1, 1);
        vm.prank(holder);
        pool.windDown();
        vm.prank(holder);
        vm.expectRevert(Pool.RedeemExceedsIdle.selector);
        pool.redeem(PRINCIPAL);

        vm.prank(provider);
        escrow.cancelByProvider(id);
        pool.reconcile(1, 1, 1);
        vm.prank(holder);
        pool.redeem(PRINCIPAL);
        assertEq(uint8(pool.life()), uint8(Pool.Life.CLOSED));
    }

    function test_runoff_blocksAuthorize_endRunoffWhenIdle() public {
        vm.prank(holder);
        pool.startRunoff();
        HolderAuthorization memory ha = _holderAuth(_poolHolderTerms(), 1);
        vm.prank(controller);
        vm.expectRevert(Pool.WrongLife.selector);
        pool.authorize(ha);
        vm.prank(holder);
        pool.endRunoff();
        assertEq(uint8(pool.life()), uint8(Pool.Life.ACTIVE));
    }

    function test_redeem_doesNotInvadeLocked() public {
        _activatePool(1, 1, 1);
        vm.prank(holder);
        vm.expectRevert(Pool.RedeemExceedsIdle.selector);
        pool.redeem(PRINCIPAL);
        assertEq(pool.locked(), PRINCIPAL);
    }

    function test_1271_rejectsUnknownDigest() public view {
        assertEq(pool.isValidSignature(bytes32(uint256(1)), ""), bytes4(0));
    }

    function test_deficient_blocksAuthorize() public {
        deal(address(token), address(pool), 0);
        pool.sync();
        assertEq(uint8(pool.life()), uint8(Pool.Life.DEFICIENT));
        HolderAuthorization memory ha = _holderAuth(_poolHolderTerms(), 1);
        vm.prank(controller);
        vm.expectRevert(Pool.WrongLife.selector);
        pool.authorize(ha);
    }

    function _privatePool(uint16 feeBps) internal returns (Pool) {
        address[] memory sps = new address[](1);
        sps[0] = holder;
        address[] memory cs = new address[](1);
        cs[0] = controller;
        address[] memory deps = new address[](1);
        deps[0] = holder;
        return Pool(factory.createPool(sps, address(token), address(escrow), cs, false, deps, feeBps));
    }

    function _poolHolderTerms() internal view returns (DealTerms memory t) {
        t = _p2pTerms();
        t.holder = address(pool);
        t.controller = controller;
    }

    function _activatePool(uint256 holderNonce, uint256 providerNonce, uint256 controllerNonce)
        internal
        returns (bytes32)
    {
        DealTerms memory terms = _poolHolderTerms();
        HolderAuthorization memory ha = _holderAuth(terms, holderNonce);
        ProviderAgreement memory pa = _providerAuth(terms, providerNonce);
        ControllerAcceptance memory ca = _controllerAuth(terms, controllerNonce);
        vm.prank(controller);
        pool.authorize(ha);
        return escrow.activate(ha, "", pa, _signProvider(pa), ca, _signController(ca));
    }

    function _signHolderAsController(ControllerAcceptance memory a) internal view returns (bytes memory) {
        return _sign(_typed(Consent.hashControllerAcceptance(a)), holderPk);
    }
}
