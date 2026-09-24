// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "./Base.t.sol";
import {Status} from "../src/libraries/Types.sol";

/// @title A dispute nobody resolves, in a deal nobody gave a tribunal
/// @notice The Core dispute equilibrium (PLURISWAP.md Parte IV, 2026-09-24, over 2026-09-22).
/// @dev Two parties who sign a deal without ARBITRATION have chosen, together, to have no tribunal. When
///      one of them freezes the trade and neither gives way before the clock, the kernel does not pretend
///      to know who was right — nobody asked anyone to decide. It splits the principal and marks both: a
///      stalemate (§3.11), a reasonable detriment to each side, whose purpose is to make an agreement
///      inside the window better than letting it run out.
///
///      The 2026-09-22 rule (abandoning a dispute loses it) survives exactly where its argument holds:
///      in a deal WITH a tribunal, the Controller who opened a fight had a court available and did not
///      use it. That case lives in `Packages.t.sol`.
///
///      In pure Core, with no packages, the stalemate is only the split: there is no reputation to mark
///      and no bond to burn. It does not make lying unprofitable there — it caps what it pays at half,
///      where the forfeit paid a Provider who never sent fiat the whole pot. The marks come with the
///      official packages (`Packages.t.sol`).
contract DisputeDeadlockTest is BaseTest {
    function test_withoutATribunal_theTimeoutIsAStalemate() public {
        bytes32 id = _activateP2P(1, 2);
        _markFiat(id);
        vm.prank(holder);
        escrow.openDisputed(id);

        vm.warp(block.timestamp + 7200);
        vm.prank(address(0xdead)); // permissionless, as every timeout is
        escrow.forceDisputeTimeout(id);

        (Status st, uint256 holderAmt, uint256 providerAmt) = escrow.settlementOf(id);
        assertEq(uint8(st), uint8(Status.STALEMATE), "nobody asked for a verdict, so there is none");
        assertEq(holderAmt, PRINCIPAL / 2);
        assertEq(providerAmt, PRINCIPAL - PRINCIPAL / 2);
        assertEq(token.balanceOf(holder), PRINCIPAL / 2);
        assertEq(token.balanceOf(provider), PRINCIPAL - PRINCIPAL / 2);
    }

    /// The case the forfeit got wrong: a Provider who never sent fiat, marks it sent, and refuses every
    /// settlement no longer walks away with the whole pot. Half is still a gain for a liar in pure Core —
    /// which is why the official set marks both sides and burns their bonds.
    function test_aProviderWhoNeverPaid_nolongerTakesTheWholePot() public {
        bytes32 id = _activateP2P(3, 4);
        _markFiat(id); // a lie: no fiat moved
        vm.prank(holder);
        escrow.openDisputed(id);
        vm.warp(block.timestamp + 7200);
        escrow.forceDisputeTimeout(id);
        assertEq(token.balanceOf(provider), PRINCIPAL - PRINCIPAL / 2, "half, not all");
    }

    /// The clock is still a clock.
    function test_beforeTheDeadline_thereIsNoStalemate() public {
        bytes32 id = _activateP2P(5, 6);
        _markFiat(id);
        vm.prank(holder);
        escrow.openDisputed(id);
        vm.expectRevert();
        escrow.forceDisputeTimeout(id);
    }

    /// Settling inside the window is the path the stalemate exists to make attractive, and it is untouched.
    function test_settlingInsideTheWindowStillWorks() public {
        bytes32 id = _activateP2P(7, 8);
        _markFiat(id);
        vm.prank(holder);
        escrow.openDisputed(id);
        _mutualSplit(id, 4000, 9, 10);
        (Status st, uint256 holderAmt, uint256 providerAmt) = escrow.settlementOf(id);
        assertEq(uint8(st), uint8(Status.RESOLVED_SPLIT));
        assertEq(providerAmt, PRINCIPAL * 4000 / 10_000);
        assertEq(holderAmt, PRINCIPAL - providerAmt);
    }
}
