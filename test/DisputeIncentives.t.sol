// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "./Base.t.sol";
import {Escrow} from "../src/Escrow.sol";
import {Status} from "../src/libraries/Types.sol";

/// @title Dispute incentives, as decided
/// @notice The shape of a fight after the Parte IV decision of 2026-09-24 (over 2026-09-22).
/// @dev What holds together:
///
///      1. Only the Controller opens a fight, and only the Controller escalates one. Settled: the
///         Provider does not need to dispute, because when the Controller is absent the release
///         deadline pays them in full without anyone's permission.
///      2. In a deal WITH a tribunal, opening a fight and abandoning it loses it (`Packages.t.sol`):
///         the Controller had a court and did not use it.
///      3. In a deal WITHOUT one — Core included — nobody can escalate, because the two parties chose
///         not to have a tribunal. A fight nobody settles is a deadlock, and a deadlock costs both:
///         the principal split, and with the official packages both scores marked and both bonds
///         burned. The freeze is worth what it is for: time to settle.
///
///      Stated rather than hidden: in pure Core, with no packages, a deadlock is only the split. Core
///      cannot tell the two stories apart and does not pretend to; the split caps what either lie
///      pays at half, where the 2026-09-22 forfeit paid an unpaid Provider the whole pot.
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

    /// Freezing is not free and not a win: a frozen trade that nobody settles ends split, where leaving it
    /// alone would have paid the Provider in full. Both sides end worse than if they had agreed.
    function test_aFreezeNobodySettles_costsBothSides() public {
        bytes32 frozen = _activateP2P(5, 6);
        _markFiat(frozen);
        vm.prank(holder);
        escrow.openDisputed(frozen);
        vm.warp(block.timestamp + 7200);
        escrow.forceDisputeTimeout(frozen);
        (Status st, uint256 hFrozen, uint256 pFrozen) = escrow.settlementOf(frozen);

        assertEq(uint8(st), uint8(Status.STALEMATE));
        assertEq(hFrozen, PRINCIPAL / 2, "the Holder recovers half, not all");
        assertEq(pFrozen, PRINCIPAL - PRINCIPAL / 2, "the Provider collects half, not all");
    }

    /// Core cannot tell the two stories apart, so it does not pick one: a Provider who never paid and
    /// refuses every settlement takes half — not the whole pot, and not nothing.
    function test_coreCannotTellTheTwoStoriesApart_andSplits() public {
        bytes32 id = _activateP2P(9, 10);
        _markFiat(id); // no fiat was sent; `markFiat` authenticates nothing (§3.11)
        vm.prank(holder);
        escrow.openDisputed(id);
        vm.warp(block.timestamp + 7200);
        escrow.forceDisputeTimeout(id);

        (, uint256 holderAmt, uint256 providerAmt) = escrow.settlementOf(id);
        assertEq(providerAmt, PRINCIPAL - PRINCIPAL / 2, "a lie pays at most half in pure Core");
        assertEq(holderAmt, PRINCIPAL / 2, "a deal that must not lose half selects ARBITRATION");
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
