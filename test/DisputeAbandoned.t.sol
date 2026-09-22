// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "./Base.t.sol";
import {Escrow} from "../src/Escrow.sol";
import {Status} from "../src/libraries/Types.sol";

/// @title Abandoning a dispute loses it
/// @notice The Core dispute equilibrium, decided (PLURISWAP.md Parte IV, 2026-09-22).
/// @dev Only the Controller opens a fight -- that is settled and not reopened here. What changes is
///      what happens when they open one and then do nothing with it. It used to time out to a 50/50
///      stalemate, which made `openDisputed` a free option on half of somebody else's principal: the
///      Holder side could freeze a trade it had lost and walk away with half.
///
///      Now the clock reads abandonment as the answer. Whoever opened the fight and neither settled
///      it nor escalated it has forfeited: the principal goes to the Provider in full, exactly as if
///      the freeze had never happened. `STALEMATE` keeps its old meaning and its 50/50 for the two
///      cases where nobody abandoned anything -- the tribunal refused, or the tribunal never answered.
///
///      The price of this, stated rather than hidden: in a Core-only deal the freeze stops being a
///      haircut and becomes only a negotiation window. A Provider who never sent fiat and refuses
///      every settlement now takes 100% instead of 50%. That is the cost of removing the option, and
///      it is the argument for selecting ARBITRATION, where the Holder who is right gets a verdict.
contract DisputeAbandonedTest is BaseTest {
    function test_abandonedDispute_paysTheProviderInFull() public {
        bytes32 id = _activateP2P(1, 2);
        _markFiat(id);
        vm.prank(holder);
        escrow.openDisputed(id);

        vm.warp(block.timestamp + 7200);
        vm.prank(address(0xdead)); // permissionless, as every timeout is
        escrow.forceDisputeTimeout(id);

        (Status st, uint256 holderAmt, uint256 providerAmt) = escrow.settlementOf(id);
        assertEq(uint8(st), uint8(Status.ABANDONED), "its own terminal: not a stalemate, there was a loser");
        assertEq(providerAmt, PRINCIPAL, "the side that did not abandon takes the whole pot");
        assertEq(holderAmt, 0);
    }

    /// The attack this closes: freezing a trade you lost is no longer worth anything.
    function test_freezingAndWaitingIsNoLongerWorthHalf() public {
        bytes32 id = _activateP2P(3, 4);
        _markFiat(id);
        uint256 before = token.balanceOf(holder);

        vm.prank(holder);
        escrow.openDisputed(id);
        vm.warp(block.timestamp + 7200);
        escrow.forceDisputeTimeout(id);

        assertEq(token.balanceOf(holder), before, "freezing bought the Holder nothing");
        assertEq(token.balanceOf(provider), PRINCIPAL, "the same outcome as never freezing at all");
    }

    /// The clock is still a clock: before it, abandonment has not happened yet.
    function test_beforeTheDeadline_thereIsNoAbandonment() public {
        bytes32 id = _activateP2P(5, 6);
        _markFiat(id);
        vm.prank(holder);
        escrow.openDisputed(id);
        vm.expectRevert();
        escrow.forceDisputeTimeout(id);
    }

    /// Settling inside the window is still the good path, and it is untouched.
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

    /// `STALEMATE` survives, with its meaning intact: the two cases where nobody abandoned anything
    /// are the tribunal refusing and the tribunal never answering (§3.11 OUT-11/OUT-12).
    function test_stalemateStillMeansNobodyAbandonedAnything() public {
        bytes32 id = _activateP2P(11, 12);
        _markFiat(id);
        vm.prank(holder);
        escrow.openDisputed(id);
        vm.warp(block.timestamp + 7200);
        escrow.forceDisputeTimeout(id);
        (Status st,,) = escrow.settlementOf(id);
        assertTrue(st != Status.STALEMATE, "an abandoned dispute is no longer called a stalemate");
    }
}
