// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "./Base.t.sol";
import {Escrow} from "../src/Escrow.sol";
import {Status} from "../src/libraries/Types.sol";

/// @title Dispute incentives
/// @notice What a fully-performing Provider can force, and what it costs the other side to stop them.
/// @dev This file asserts no bug. Every line here is the catalogue of §3.9 working as specified. It
///      exists because the specified behaviour has an economic consequence the spirit does not
///      acknowledge, and a consequence that large should be pinned in the suite rather than living
///      only in a document: if anyone changes it, these fail and the change is deliberate.
///
///      Principle II.6 justifies the 50/50 stalemate with "ambas partes tenían salida y ninguna la
///      tomó". For the Holder side that is true — release, co-sign, split, or escalate. For the
///      Provider it is not: every exit that pays them more than half needs the Controller's
///      signature, and the two that do not (`claim`, `forceStalemate`) are respectively killed by
///      `DISPUTED` and capped at half. So the Provider's best unilateral outcome, after performing
///      in full, is 50%.
///
///      The asymmetry is not neutral either. In Core the Holder puts up 100% of the principal and
///      the Provider puts up nothing on-chain, so a 50/50 default on a he-said-she-said moves value
///      from the side that escrowed to the side that claimed — in both directions, which is what
///      makes `openDisputed` an option rather than a defence.
///
///      PLURISWAP.md Parte IV (2026-09-22) records this as an OPEN decision, not a closed one.
contract DisputeIncentivesTest is BaseTest {
    /// The Controller freezes a completed trade and simply waits. Nothing here is out of catalogue.
    function test_controllerCanCapAPerformingProviderAtHalf() public {
        bytes32 id = _activateP2P(1, 2);
        _markFiat(id); // the Provider paid fiat off-chain and said so

        vm.prank(holder); // Holder == Controller: the P2P degenerate case of §3.5
        escrow.openDisputed(id);

        // Core has no court at all. And selecting ARBITRATION would not change the outcome, because
        // opening it is Controller-only too (§3.12.2) -- the same party holds the freeze and the
        // escalation. That leg is `test_providerCannotEscalateEvenWithArbitration` in Packages.t.sol,
        // where a court exists to be refused.
        vm.prank(provider);
        vm.expectRevert(Escrow.PackageNotSelected.selector);
        escrow.openCourt(id);

        // `DISPUTED` kills the one unilateral win the Provider had.
        vm.warp(block.timestamp + 10 days);
        vm.prank(provider);
        vm.expectRevert(Escrow.WrongStatus.selector);
        escrow.claim(id);

        // Everything else from `DISPUTED` needs the Controller's signature. This is all that is left.
        vm.prank(provider);
        escrow.forceStalemate(id);

        (Status st, uint256 holderAmt, uint256 providerAmt) = escrow.settlementOf(id);
        assertEq(uint8(st), uint8(Status.STALEMATE));
        assertEq(providerAmt, PRINCIPAL / 2, "a Provider who performed in full recovers half");
        assertEq(holderAmt, PRINCIPAL / 2, "and the Holder keeps half of a principal it owed in full");
    }

    /// The mirror, so the asymmetry is not mistaken for a bias against one seat: a Provider who never
    /// paid takes half too, and the Holder's only defence is the move that concedes it.
    function test_theMirror_aProviderWhoNeverPaidAlsoTakesHalf() public {
        bytes32 id = _activateP2P(3, 4);
        _markFiat(id); // no fiat was sent; `markFiat` authenticates nothing (§3.11)

        // The Holder's choice is to let the release deadline pay 100%, or freeze and settle for 50%.
        vm.prank(holder);
        escrow.openDisputed(id);
        vm.warp(block.timestamp + 10 days);
        escrow.forceStalemate(id);

        (, uint256 holderAmt, uint256 providerAmt) = escrow.settlementOf(id);
        assertEq(providerAmt, PRINCIPAL / 2, "half the principal for an off-chain payment never made");
        assertEq(holderAmt, PRINCIPAL / 2);
    }

    /// The Core cost of taking that option is zero. The official reputation package prices it at 1%
    /// of principal with a ~2 USDC floor (§3.14.6) and bonds burn 10% a side (§3.14.5) — neither is
    /// close to the 50% on the table, which is the shape of the open question.
    function test_openingTheFightIsFreeInCore() public {
        bytes32 id = _activateP2P(5, 6);
        _markFiat(id);
        uint256 before = token.balanceOf(holder);
        vm.prank(holder);
        escrow.openDisputed(id);
        assertEq(token.balanceOf(holder), before, "no fee, no bond, no deposit");
        assertFalse(escrow.contestPaid(id), "Core-only charges nothing to contest");
    }
}
