// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "./Base.t.sol";
import {Escrow} from "../src/Escrow.sol";
import {Status} from "../src/libraries/Types.sol";

/// @title Dispute incentives, as decided
/// @notice The shape of a fight after the Parte IV decision of 2026-09-22, including its price.
/// @dev Three things hold together and none of them is an accident:
///
///      1. Only the Controller opens a fight, and only the Controller escalates one. Settled: the
///         Provider does not need to dispute, because when the Controller is absent the release
///         deadline pays them in full without anyone's permission.
///      2. Opening a fight and abandoning it loses it. That is what makes (1) safe. Before, a
///         Controller could freeze a trade it had lost and take half by doing nothing; now doing
///         nothing hands over everything, which is the same outcome as never having frozen.
///      3. So the freeze is worth exactly what it is for: time to settle, or to escalate.
///
///      The price, asserted here rather than left implicit: in a Core-only deal a Provider who
///      never sent fiat and refuses every settlement now takes 100% instead of 50%. Core has no
///      tribunal by construction (II.2), so it cannot tell the two stories apart, and the decision
///      is to stop pretending a 50/50 was a judgement. That is the argument for ARBITRATION.
contract DisputeIncentivesTest is BaseTest {
    /// Settled and not reopened: the Provider's protection is the clock, not a verb of their own.
    function test_providerNeedsNoDispute_whenTheControllerIsAbsent() public {
        bytes32 id = _activateP2P(1, 2);
        _markFiat(id);
        vm.warp(block.timestamp + 1800);
        vm.prank(provider);
        escrow.claim(id);
        (Status st,, uint256 providerAmt) = escrow.settlementOf(id);
        assertEq(uint8(st), uint8(Status.CLAIMED));
        assertEq(providerAmt, PRINCIPAL, "absence pays the Provider in full, with nobody's permission");
    }

    function test_providerHasNoDisputeVerbOfItsOwn() public {
        bytes32 id = _activateP2P(3, 4);
        _markFiat(id);
        vm.prank(provider);
        vm.expectRevert(Escrow.Unauthorized.selector);
        escrow.openDisputed(id);
        vm.prank(provider);
        vm.expectRevert(Escrow.PackageNotSelected.selector); // Core has no court at all
        escrow.openCourt(id);
    }

    /// What makes that safe: freezing and waiting is now the same as never freezing.
    function test_freezingAndAbandoningEqualsNotFreezing() public {
        bytes32 frozen = _activateP2P(5, 6);
        _markFiat(frozen);
        vm.prank(holder);
        escrow.openDisputed(frozen);
        vm.warp(block.timestamp + 7200);
        escrow.forceDisputeTimeout(frozen);
        (, uint256 hFrozen, uint256 pFrozen) = escrow.settlementOf(frozen);

        token.mint(holder, PRINCIPAL);
        bytes32 left = _activateP2P(7, 8);
        _markFiat(left);
        vm.warp(block.timestamp + 1800);
        escrow.claim(left);
        (, uint256 hLeft, uint256 pLeft) = escrow.settlementOf(left);

        assertEq(pFrozen, pLeft, "the Provider ends in the same place either way");
        assertEq(hFrozen, hLeft, "and so does the Holder: the freeze bought nothing by itself");
    }

    /// The price of the decision, stated. Core cannot adjudicate, so it stops pretending to.
    function test_thePrice_coreCannotTellTheTwoStoriesApart() public {
        bytes32 id = _activateP2P(9, 10);
        _markFiat(id); // no fiat was sent; `markFiat` authenticates nothing (§3.11)
        vm.prank(holder);
        escrow.openDisputed(id);
        vm.warp(block.timestamp + 7200);
        escrow.forceDisputeTimeout(id);

        (, uint256 holderAmt, uint256 providerAmt) = escrow.settlementOf(id);
        assertEq(providerAmt, PRINCIPAL, "an unpaid Provider who refuses to settle takes everything");
        assertEq(holderAmt, 0, "this is why a deal that matters selects ARBITRATION");
    }

    /// Core charges nothing to open one. The official reputation package prices it (§3.14.6).
    function test_openingTheFightIsFreeInCore() public {
        bytes32 id = _activateP2P(11, 12);
        _markFiat(id);
        uint256 before = token.balanceOf(holder);
        vm.prank(holder);
        escrow.openDisputed(id);
        assertEq(token.balanceOf(holder), before, "no fee, no bond, no deposit");
        assertFalse(escrow.contestPaid(id), "Core-only charges nothing to contest");
    }
}
