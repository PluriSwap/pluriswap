// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CreditLedger} from "../src/CreditLedger.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {DeficitActive, InsufficientCredit} from "../src/libraries/CoreErrors.sol";

contract CreditLedgerDeficitTest is Test {
    CreditLedger ledger;
    MockERC20 token;
    address escrow = address(this);
    address alice = address(0xA1);
    address bob = address(0xB2);

    function setUp() public {
        ledger = new CreditLedger(escrow, uint64(block.chainid));
        token = new MockERC20();
    }

    function test_burn_triggersDeficit_ordinaryWithdrawBlocked() public {
        token.mint(address(ledger), 100e18);
        ledger.credit(bytes32(uint256(1)), address(token), alice, 60e18);
        ledger.credit(bytes32(uint256(1)), address(token), bob, 40e18);

        token.burn(address(ledger), 50e18);

        // Withdraw observes undercollateralization (does not persist DEFICIT by itself).
        vm.expectRevert(DeficitActive.selector);
        ledger.withdraw(address(token), alice);

        // Persist DEFICIT, then ordinary withdraw remains blocked.
        ledger.syncDeficit(address(token));
        assertTrue(ledger.inDeficit(address(token)));

        vm.expectRevert(DeficitActive.selector);
        ledger.withdraw(address(token), alice);
    }

    function test_claimRecovery_proRata() public {
        token.mint(address(ledger), 100e18);
        ledger.credit(bytes32(uint256(1)), address(token), alice, 60e18);
        ledger.credit(bytes32(uint256(1)), address(token), bob, 40e18);
        token.burn(address(ledger), 50e18); // 50 assets left for 100 liabilities

        ledger.claimRecovery(address(token), alice);
        // alice units 60 / 100 * 50 = 30
        assertEq(token.balanceOf(alice), 30e18);
        assertTrue(ledger.inDeficit(address(token)));

        ledger.claimRecovery(address(token), bob);
        // bob units 40 / 100 * 50 = 20
        assertEq(token.balanceOf(bob), 20e18);

        vm.expectRevert(InsufficientCredit.selector);
        ledger.claimRecovery(address(token), alice);
    }

    function test_claimRecovery_withoutPriorWithdraw() public {
        token.mint(address(ledger), 100e18);
        ledger.credit(bytes32(uint256(1)), address(token), alice, 100e18);
        token.burn(address(ledger), 75e18);

        ledger.claimRecovery(address(token), alice);
        assertEq(token.balanceOf(alice), 25e18);
        assertTrue(ledger.inDeficit(address(token)));
    }

    function test_newCredit_rejectedInDeficit() public {
        token.mint(address(ledger), 100e18);
        ledger.credit(bytes32(uint256(1)), address(token), alice, 100e18);
        token.burn(address(ledger), 50e18);
        ledger.claimRecovery(address(token), alice);

        token.mint(address(ledger), 10e18);
        vm.expectRevert(DeficitActive.selector);
        ledger.credit(bytes32(uint256(2)), address(token), bob, 10e18);
    }
}
