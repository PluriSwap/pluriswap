// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TestToken} from "../src/TestToken.sol";
import {BondVault} from "../src/packages/BondVault.sol";
import {PackageId} from "../src/packages/PackageId.sol";

contract BondVaultTest is Test {
    uint256 internal constant PRINCIPAL = 1_000_000;
    bytes32 internal constant SUBJECT = keccak256("subject-h");
    bytes32 internal constant SUBJECT_P = keccak256("subject-p");

    TestToken internal token;
    BondVault internal vault;
    address internal sink = address(0xdeaD);
    address internal holder = address(0xA11CE);
    address internal provider = address(0xB0B);
    address internal controller = address(0xC0);

    function setUp() public {
        token = new TestToken();
        vault = new BondVault(address(this), sink);
        token.mint(holder, PRINCIPAL);
        vm.prank(holder);
        token.approve(address(vault), type(uint256).max);
    }

    function test_packageId_bondsPreimageStable() public view {
        assertEq(vault.packageId(), PackageId.bonds(address(vault), sink));
        assertEq(PackageId.BOND_LOCK_BPS, 1000);
    }

    function test_deposit() public {
        vm.prank(holder);
        vault.deposit(SUBJECT, address(token), PRINCIPAL);
        assertEq(token.balanceOf(address(vault)), PRINCIPAL);
        assertEq(token.balanceOf(holder), 0);
        assertEq(vault.deposited(SUBJECT, address(token)), PRINCIPAL);
        assertEq(vault.available(SUBJECT, address(token)), PRINCIPAL);
        assertEq(vault.locked(SUBJECT, address(token)), 0);
    }

    function test_withdrawAvailable() public {
        vm.prank(holder);
        vault.deposit(SUBJECT, address(token), PRINCIPAL);
        vm.prank(holder);
        vault.withdraw(SUBJECT, address(token), PRINCIPAL);
        assertEq(token.balanceOf(holder), PRINCIPAL);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(vault.deposited(SUBJECT, address(token)), 0);
        assertEq(vault.available(SUBJECT, address(token)), 0);
    }

    function test_lockTenPercent() public {
        vm.prank(holder);
        vault.deposit(SUBJECT, address(token), PRINCIPAL);
        bytes32 dealId = keccak256("deal-1");
        vault.reserve(SUBJECT, address(token), dealId, PRINCIPAL);
        uint256 lockAmount = PRINCIPAL / 10;
        assertEq(vault.lockOf(SUBJECT, dealId), lockAmount);
        assertEq(vault.locked(SUBJECT, address(token)), lockAmount);
        assertEq(vault.available(SUBJECT, address(token)), PRINCIPAL - lockAmount);
        assertTrue(vault.locked(SUBJECT, address(token)) * 10 >= PRINCIPAL);
    }

    function test_withdrawLockedReverts() public {
        vm.prank(holder);
        vault.deposit(SUBJECT, address(token), PRINCIPAL);
        vault.reserve(SUBJECT, address(token), keccak256("deal-1"), PRINCIPAL);
        vm.prank(holder);
        vm.expectRevert(BondVault.InsufficientAvailable.selector);
        vault.withdraw(SUBJECT, address(token), PRINCIPAL);
        assertEq(token.balanceOf(address(vault)), PRINCIPAL);
        uint256 avail = PRINCIPAL - PRINCIPAL / 10;
        vm.prank(holder);
        vault.withdraw(SUBJECT, address(token), avail);
        assertEq(vault.available(SUBJECT, address(token)), 0);
        assertEq(vault.locked(SUBJECT, address(token)), PRINCIPAL / 10);
    }

    function test_slashToWinnerSigningAddress() public {
        bytes32 dealId = keccak256("deal-slash");
        _lockBoth(dealId);
        uint256 lockAmount = PRINCIPAL / 10;
        vault.slash(SUBJECT_P, SUBJECT, address(token), dealId, holder, controller);
        assertEq(token.balanceOf(holder), lockAmount);
        assertEq(token.balanceOf(controller), 0);
        assertEq(token.balanceOf(provider), 0);
        assertEq(vault.lockOf(SUBJECT_P, dealId), 0);
        assertEq(vault.lockOf(SUBJECT, dealId), 0);
        assertEq(vault.locked(SUBJECT_P, address(token)), 0);
        assertEq(vault.locked(SUBJECT, address(token)), 0);
        assertEq(vault.deposited(SUBJECT_P, address(token)), PRINCIPAL - lockAmount);
        assertEq(vault.available(SUBJECT, address(token)), PRINCIPAL);
        assertEq(token.balanceOf(address(vault)), PRINCIPAL * 2 - lockAmount);
    }

    function test_neverToController() public {
        bytes32 dealId = keccak256("deal-ctrl");
        _lockBoth(dealId);
        vm.expectRevert(BondVault.ControllerIsNotWinner.selector);
        vault.slash(SUBJECT_P, SUBJECT, address(token), dealId, controller, controller);
        assertEq(token.balanceOf(controller), 0);
        assertEq(vault.lockOf(SUBJECT, dealId), PRINCIPAL / 10);
    }

    function test_stalemateBurnsBoth() public {
        bytes32 dealId = keccak256("deal-burn");
        _lockBoth(dealId);
        uint256 lockAmount = PRINCIPAL / 10;
        vault.burn(SUBJECT, SUBJECT_P, address(token), dealId);
        assertEq(token.balanceOf(sink), lockAmount * 2);
        assertEq(vault.lockOf(SUBJECT, dealId), 0);
        assertEq(vault.lockOf(SUBJECT_P, dealId), 0);
        assertEq(vault.locked(SUBJECT, address(token)), 0);
        assertEq(vault.locked(SUBJECT_P, address(token)), 0);
        assertEq(vault.deposited(SUBJECT, address(token)), PRINCIPAL - lockAmount);
        assertEq(vault.deposited(SUBJECT_P, address(token)), PRINCIPAL - lockAmount);
        assertEq(token.balanceOf(controller), 0);
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.balanceOf(provider), 0);
    }

    function _lockBoth(bytes32 dealId) internal {
        vm.prank(holder);
        vault.deposit(SUBJECT, address(token), PRINCIPAL);
        token.mint(provider, PRINCIPAL);
        vm.prank(provider);
        token.approve(address(vault), type(uint256).max);
        vm.prank(provider);
        vault.deposit(SUBJECT_P, address(token), PRINCIPAL);
        vault.reserve(SUBJECT, address(token), dealId, PRINCIPAL);
        vault.reserve(SUBJECT_P, address(token), dealId, PRINCIPAL);
    }
}
