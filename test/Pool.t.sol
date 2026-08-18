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
import {Pool} from "../src/pools/Pool.sol";
import {PoolFactory} from "../src/pools/PoolFactory.sol";
import {BaseTest} from "./Base.t.sol";

contract PoolTest is BaseTest {
    PoolFactory internal factory;
    Pool internal pool;

    function setUp() public override {
        super.setUp();
        factory = new PoolFactory();
        address[] memory cs = new address[](1);
        cs[0] = controller;
        pool = Pool(factory.createPool(holder, address(token), address(escrow), cs));
        token.mint(holder, PRINCIPAL);
        vm.startPrank(holder);
        token.approve(address(pool), type(uint256).max);
        pool.deposit(PRINCIPAL);
        vm.stopPrank();
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
        pool.withdraw(PRINCIPAL);
        HolderAuthorization memory ha = _holderAuth(_poolHolderTerms(), 1);
        vm.prank(controller);
        vm.expectRevert(Pool.InsufficientIdle.selector);
        pool.authorize(ha);
    }

    function test_twoConcurrentDealsDoNotOverAllocate() public {
        token.mint(holder, PRINCIPAL);
        vm.startPrank(holder);
        pool.deposit(PRINCIPAL);
        vm.stopPrank();

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
        vm.prank(controller);
        pool.reconcile(1, 1, 1, PRINCIPAL);
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
        vm.prank(controller);
        pool.reconcile(1, 1, 1, 0);
        assertEq(pool.idle(), 0);
        assertEq(pool.locked(), 0);
        assertEq(pool.consumed(), PRINCIPAL);
        assertEq(token.balanceOf(provider), PRINCIPAL);
    }

    function test_closing_rejectsNewAuthorize() public {
        vm.prank(holder);
        pool.close();
        HolderAuthorization memory ha = _holderAuth(_poolHolderTerms(), 1);
        vm.prank(controller);
        vm.expectRevert(Pool.WrongLife.selector);
        pool.authorize(ha);
    }

    function test_closing_liveDealThenFinalize() public {
        bytes32 id = _activatePool(1, 1, 1);
        vm.prank(holder);
        pool.close();
        vm.prank(holder);
        vm.expectRevert(Pool.StillLive.selector);
        pool.finalize();

        vm.prank(provider);
        escrow.cancelByProvider(id);
        vm.prank(controller);
        pool.reconcile(1, 1, 1, PRINCIPAL);
        vm.prank(holder);
        pool.finalize();
        assertEq(uint8(pool.life()), uint8(Pool.Life.CLOSED));
    }

    function test_withdraw_doesNotInvadeLocked() public {
        _activatePool(1, 1, 1);
        vm.prank(holder);
        vm.expectRevert(Pool.InsufficientIdle.selector);
        pool.withdraw(1);
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
}
