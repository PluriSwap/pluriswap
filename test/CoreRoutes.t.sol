// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CoreTestBase} from "./helpers/CoreTestBase.sol";
import {DealSigUtils} from "./helpers/DealSigUtils.sol";
import {
    DealState,
    DealTerms,
    Outcome,
    ResolutionAction,
    ResolutionAuth
} from "../src/libraries/DealTypes.sol";
import {
    Expired,
    InvalidState,
    InvalidTerms,
    InvalidTiming,
    TerminalDeal,
    Unauthorized
} from "../src/libraries/CoreErrors.sol";

/// @notice Exhaustive Core-only route coverage (no optional profiles).
/// Maps 1:1 to PROTOCOL.md CASE-CORE-* success and reject edges.
contract CoreRoutesTest is CoreTestBase {
    uint256 internal _nonce = 1;

    function _nextDeal(uint256 principal) internal returns (bytes32) {
        DealTerms memory t = _baseTerms(principal, _nonce++);
        return _activate(t);
    }

    function _nextDealWithFees(uint256 principal, uint256 activationFee, uint256 completionFee)
        internal
        returns (bytes32)
    {
        DealTerms memory t = _baseTerms(principal, _nonce++);
        t.activationFee = activationFee;
        t.activationFeeRecipient = feeRecipient;
        t.completionFee = completionFee;
        t.completionFeeRecipient = feeRecipient;
        return _activate(t);
    }

    // ─── Success paths ───────────────────────────────────────────────────────

    /// CASE-CORE-001
    function test_CASE_CORE_001_activate() public {
        bytes32 dealId = _nextDeal(100e18);
        assertEq(uint8(escrow.dealState(dealId)), uint8(DealState.Funded));
        assertEq(token.balanceOf(address(escrow)), 100e18);
    }

    /// CASE-CORE-002
    function test_CASE_CORE_002_markFiatSent() public {
        bytes32 dealId = _nextDeal(100e18);
        _markFiat(dealId);
        assertEq(uint8(escrow.dealState(dealId)), uint8(DealState.FiatSent));
        assertGt(escrow.getDeal(dealId).releaseDeadline, 0);
    }

    /// CASE-CORE-004
    function test_CASE_CORE_004_providerCancel() public {
        bytes32 dealId = _nextDeal(100e18);
        vm.prank(provider);
        escrow.providerCancel(dealId);
        assertEq(uint8(escrow.getDeal(dealId).outcome), uint8(Outcome.ProviderCancel));
        assertEq(ledger.creditOf(address(token), holderReceiver), 100e18);
    }

    /// CASE-CORE-005
    function test_CASE_CORE_005_fiatTimeout() public {
        bytes32 dealId = _nextDeal(100e18);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(address(0x99));
        escrow.fiatTimeoutCancel(dealId);
        assertEq(uint8(escrow.getDeal(dealId).outcome), uint8(Outcome.FiatTimeoutCancel));
        assertEq(ledger.creditOf(address(token), holderReceiver), 100e18);
    }

    /// CASE-CORE-006
    function test_CASE_CORE_006_mutualCancel_fromFunded() public {
        bytes32 dealId = _nextDeal(100e18);
        _mutualResolve(dealId, ResolutionAction.MutualCancel, 1, 0);
        assertEq(uint8(escrow.getDeal(dealId).outcome), uint8(Outcome.MutualCancel));
        assertEq(ledger.creditOf(address(token), holderReceiver), 100e18);
    }

    /// CASE-CORE-007
    function test_CASE_CORE_007_holderRelease() public {
        bytes32 dealId = _nextDeal(100e18);
        _markFiat(dealId);
        vm.prank(holder);
        escrow.holderRelease(dealId);
        assertEq(uint8(escrow.getDeal(dealId).outcome), uint8(Outcome.VoluntaryRelease));
        assertEq(ledger.creditOf(address(token), providerReceiver), 100e18);
    }

    /// CASE-CORE-009
    function test_CASE_CORE_009_claim() public {
        bytes32 dealId = _nextDeal(100e18);
        _markFiat(dealId);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(address(0x99));
        escrow.claim(dealId);
        assertEq(uint8(escrow.getDeal(dealId).outcome), uint8(Outcome.TimeoutClaim));
        assertEq(ledger.creditOf(address(token), providerReceiver), 100e18);
    }

    /// CASE-CORE-011
    function test_CASE_CORE_011_mutualCancel_fromFiatSent() public {
        bytes32 dealId = _nextDeal(100e18);
        _markFiat(dealId);
        _mutualResolve(dealId, ResolutionAction.MutualCancel, 1, 0);
        assertEq(uint8(escrow.getDeal(dealId).outcome), uint8(Outcome.MutualCancel));
        assertEq(ledger.creditOf(address(token), holderReceiver), 100e18);
    }

    /// CASE-CORE-012
    function test_CASE_CORE_012_split_fromFiatSent() public {
        bytes32 dealId = _nextDeal(100e18);
        _markFiat(dealId);
        _mutualResolve(dealId, ResolutionAction.Split, 1, 2500);
        assertEq(uint8(escrow.getDeal(dealId).outcome), uint8(Outcome.MutualSplit));
        assertEq(ledger.creditOf(address(token), providerReceiver), 25e18);
        assertEq(ledger.creditOf(address(token), holderReceiver), 75e18);
    }

    /// CASE-CORE-021
    function test_CASE_CORE_021_openDispute() public {
        bytes32 dealId = _nextDeal(100e18);
        _markFiat(dealId);
        _openDispute(dealId);
        assertEq(uint8(escrow.dealState(dealId)), uint8(DealState.Disputed));
        assertGt(escrow.getDeal(dealId).disputeDeadline, 0);
    }

    /// CASE-CORE-022
    function test_CASE_CORE_022_mutualCancel_fromDisputed() public {
        bytes32 dealId = _nextDeal(100e18);
        _markFiat(dealId);
        _openDispute(dealId);
        _mutualResolve(dealId, ResolutionAction.MutualCancel, 1, 0);
        assertEq(uint8(escrow.getDeal(dealId).outcome), uint8(Outcome.MutualCancel));
        assertEq(ledger.creditOf(address(token), holderReceiver), 100e18);
    }

    /// CASE-CORE-023
    function test_CASE_CORE_023_cosignedRelease_fromDisputed() public {
        bytes32 dealId = _nextDeal(100e18);
        _markFiat(dealId);
        _openDispute(dealId);
        _mutualResolve(dealId, ResolutionAction.CosignedRelease, 1, 0);
        assertEq(uint8(escrow.getDeal(dealId).outcome), uint8(Outcome.CosignedRelease));
        assertEq(ledger.creditOf(address(token), providerReceiver), 100e18);
    }

    /// CASE-CORE-024
    function test_CASE_CORE_024_split_fromDisputed() public {
        bytes32 dealId = _nextDeal(100e18);
        _markFiat(dealId);
        _openDispute(dealId);
        _mutualResolve(dealId, ResolutionAction.Split, 1, 4000);
        assertEq(uint8(escrow.getDeal(dealId).outcome), uint8(Outcome.MutualSplit));
        assertEq(ledger.creditOf(address(token), providerReceiver), 40e18);
        assertEq(ledger.creditOf(address(token), holderReceiver), 60e18);
    }

    /// CASE-CORE-025
    function test_CASE_CORE_025_disputeTimeout() public {
        bytes32 dealId = _nextDeal(100e18);
        _markFiat(dealId);
        _openDispute(dealId);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(address(0x99));
        escrow.disputeTimeout(dealId);
        assertEq(uint8(escrow.getDeal(dealId).outcome), uint8(Outcome.DisputeTimeout));
        assertEq(ledger.creditOf(address(token), providerReceiver), 50e18);
        assertEq(ledger.creditOf(address(token), holderReceiver), 50e18);
    }

    /// CASE-CORE-026
    function test_CASE_CORE_026_cosignedRelease_fromFiatSent() public {
        bytes32 dealId = _nextDeal(100e18);
        _markFiat(dealId);
        _mutualResolve(dealId, ResolutionAction.CosignedRelease, 1, 0);
        assertEq(uint8(escrow.getDeal(dealId).outcome), uint8(Outcome.CosignedRelease));
        assertEq(ledger.creditOf(address(token), providerReceiver), 100e18);
    }

    // ─── Reject edges ────────────────────────────────────────────────────────

    /// CASE-CORE-027
    function test_CASE_CORE_027_disputed_blocksClaimAndRelease() public {
        bytes32 dealId = _nextDeal(100e18);
        _markFiat(dealId);
        _openDispute(dealId);

        vm.expectRevert(InvalidState.selector);
        escrow.claim(dealId);

        vm.prank(holder);
        vm.expectRevert(InvalidState.selector);
        escrow.holderRelease(dealId);
    }

    /// CASE-CORE-020
    function test_CASE_CORE_020_terminal_rejectsLaterAction() public {
        bytes32 dealId = _nextDeal(100e18);
        vm.prank(provider);
        escrow.providerCancel(dealId);

        vm.prank(provider);
        vm.expectRevert(TerminalDeal.selector);
        escrow.providerCancel(dealId);

        vm.expectRevert(TerminalDeal.selector);
        escrow.fiatTimeoutCancel(dealId);
    }

    function test_reject_claim_beforeReleaseDeadline() public {
        bytes32 dealId = _nextDeal(100e18);
        _markFiat(dealId);
        vm.expectRevert(InvalidTiming.selector);
        escrow.claim(dealId);
    }

    function test_reject_openDispute_atReleaseDeadline() public {
        bytes32 dealId = _nextDeal(100e18);
        _markFiat(dealId);
        vm.warp(escrow.getDeal(dealId).releaseDeadline);
        vm.prank(holder);
        vm.expectRevert(InvalidTiming.selector);
        escrow.openDispute(dealId, "");
    }

    function test_reject_openDispute_afterReleaseDeadline() public {
        bytes32 dealId = _nextDeal(100e18);
        _markFiat(dealId);
        vm.warp(escrow.getDeal(dealId).releaseDeadline + 1);
        vm.prank(holder);
        vm.expectRevert(InvalidTiming.selector);
        escrow.openDispute(dealId, "");
    }

    function test_reject_disputeTimeout_beforeDeadline() public {
        bytes32 dealId = _nextDeal(100e18);
        _markFiat(dealId);
        _openDispute(dealId);
        vm.expectRevert(InvalidTiming.selector);
        escrow.disputeTimeout(dealId);
    }

    function test_reject_fiatTimeout_beforeDeadline() public {
        bytes32 dealId = _nextDeal(100e18);
        vm.expectRevert(InvalidTiming.selector);
        escrow.fiatTimeoutCancel(dealId);
    }

    function test_reject_secondOpenDispute() public {
        bytes32 dealId = _nextDeal(100e18);
        _markFiat(dealId);
        _openDispute(dealId);
        vm.prank(holder);
        vm.expectRevert(InvalidState.selector);
        escrow.openDispute(dealId, "");
    }

    function test_reject_openDispute_nonHolder() public {
        bytes32 dealId = _nextDeal(100e18);
        _markFiat(dealId);
        vm.prank(provider);
        vm.expectRevert(Unauthorized.selector);
        escrow.openDispute(dealId, "");
    }

    function test_reject_markFiat_nonProvider() public {
        bytes32 dealId = _nextDeal(100e18);
        vm.prank(holder);
        vm.expectRevert(Unauthorized.selector);
        escrow.markFiatSent(dealId);
    }

    function test_reject_holderRelease_nonHolder() public {
        bytes32 dealId = _nextDeal(100e18);
        _markFiat(dealId);
        vm.prank(provider);
        vm.expectRevert(Unauthorized.selector);
        escrow.holderRelease(dealId);
    }

    function test_reject_providerCancel_nonProvider() public {
        bytes32 dealId = _nextDeal(100e18);
        vm.prank(holder);
        vm.expectRevert(Unauthorized.selector);
        escrow.providerCancel(dealId);
    }

    function test_reject_resolutionReplay_afterSuccess() public {
        bytes32 dealId = _nextDeal(100e18);
        ResolutionAuth memory auth;
        auth.dealId = dealId;
        auth.action = ResolutionAction.MutualCancel;
        auth.resolutionNonce = 7;
        auth.expiry = uint64(block.timestamp + 1 days);
        bytes memory hSig = DealSigUtils.signResolution(holderPk, domainSep, auth);
        bytes memory pSig = DealSigUtils.signResolution(providerPk, domainSep, auth);

        escrow.mutualResolve(dealId, auth, hSig, pSig);
        assertTrue(escrow.usedResolutionNonce(dealId, ResolutionAction.MutualCancel, 7));

        vm.expectRevert(TerminalDeal.selector);
        escrow.mutualResolve(dealId, auth, hSig, pSig);
    }

    function test_reject_resolutionExpired_doesNotConsumeNonce() public {
        bytes32 dealId = _nextDeal(100e18);
        ResolutionAuth memory auth;
        auth.dealId = dealId;
        auth.action = ResolutionAction.MutualCancel;
        auth.resolutionNonce = 1;
        auth.expiry = uint64(block.timestamp + 1 hours);
        bytes memory hSig = DealSigUtils.signResolution(holderPk, domainSep, auth);
        bytes memory pSig = DealSigUtils.signResolution(providerPk, domainSep, auth);

        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(Expired.selector);
        escrow.mutualResolve(dealId, auth, hSig, pSig);

        assertFalse(escrow.usedResolutionNonce(dealId, ResolutionAction.MutualCancel, 1));

        // Fresh non-expired auth with same nonce still works.
        auth.expiry = uint64(block.timestamp + 1 days);
        hSig = DealSigUtils.signResolution(holderPk, domainSep, auth);
        pSig = DealSigUtils.signResolution(providerPk, domainSep, auth);
        escrow.mutualResolve(dealId, auth, hSig, pSig);
        assertEq(uint8(escrow.getDeal(dealId).outcome), uint8(Outcome.MutualCancel));
    }

    function test_reject_mutualResolve_wrongDealIdInAuth() public {
        bytes32 dealId = _nextDeal(100e18);
        bytes32 other = _nextDeal(100e18);
        ResolutionAuth memory auth;
        auth.dealId = other;
        auth.action = ResolutionAction.MutualCancel;
        auth.resolutionNonce = 1;
        auth.expiry = uint64(block.timestamp + 1 days);
        bytes memory hSig = DealSigUtils.signResolution(holderPk, domainSep, auth);
        bytes memory pSig = DealSigUtils.signResolution(providerPk, domainSep, auth);
        vm.expectRevert(InvalidTerms.selector);
        escrow.mutualResolve(dealId, auth, hSig, pSig);
    }

    function test_reject_cosignedRelease_fromFunded() public {
        bytes32 dealId = _nextDeal(100e18);
        vm.expectRevert(InvalidState.selector);
        _mutualResolve(dealId, ResolutionAction.CosignedRelease, 1, 0);
    }

    function test_reject_split_fromFunded() public {
        bytes32 dealId = _nextDeal(100e18);
        vm.expectRevert(InvalidState.selector);
        _mutualResolve(dealId, ResolutionAction.Split, 1, 5000);
    }

    // ─── Races & fee retention ───────────────────────────────────────────────

    /// CASE-RACE-001: first successful tx wins between fiatTimeout and markFiat
    function test_CASE_RACE_001_fiatTimeout_winsOverMarkFiat() public {
        bytes32 dealId = _nextDeal(100e18);
        vm.warp(block.timestamp + 1 hours);
        escrow.fiatTimeoutCancel(dealId);
        vm.prank(provider);
        vm.expectRevert(TerminalDeal.selector);
        escrow.markFiatSent(dealId);
        assertEq(uint8(escrow.getDeal(dealId).outcome), uint8(Outcome.FiatTimeoutCancel));
    }

    function test_CASE_RACE_001_markFiat_winsOverFiatTimeout() public {
        bytes32 dealId = _nextDeal(100e18);
        vm.warp(block.timestamp + 1 hours);
        _markFiat(dealId);
        vm.expectRevert(InvalidState.selector);
        escrow.fiatTimeoutCancel(dealId);
        assertEq(uint8(escrow.dealState(dealId)), uint8(DealState.FiatSent));
    }

    function test_activationFee_retainedOnFiatTimeout() public {
        bytes32 dealId = _nextDealWithFees(100e18, 5e18, 0);
        assertEq(ledger.creditOf(address(token), feeRecipient), 5e18);
        vm.warp(block.timestamp + 1 hours);
        escrow.fiatTimeoutCancel(dealId);
        assertEq(ledger.creditOf(address(token), feeRecipient), 5e18);
        assertEq(ledger.creditOf(address(token), holderReceiver), 100e18);
    }

    function test_completionFee_onDisputeTimeout_whenProviderGrossPositive() public {
        DealTerms memory t = _baseTerms(100e18, _nonce++);
        t.completionFee = 4e18;
        t.completionFeeRecipient = feeRecipient;
        t.disputeTimeoutProviderBps = 5000;
        bytes32 dealId = _activate(t);
        _markFiat(dealId);
        _openDispute(dealId);
        vm.warp(block.timestamp + 1 hours);
        escrow.disputeTimeout(dealId);
        // providerGross=50, fee=min(4,50)=4 → provider net 46, holder 50
        assertEq(ledger.creditOf(address(token), feeRecipient), 4e18);
        assertEq(ledger.creditOf(address(token), providerReceiver), 46e18);
        assertEq(ledger.creditOf(address(token), holderReceiver), 50e18);
    }

    function test_noCompletionFee_onDisputeTimeout_whenProviderGrossZero() public {
        DealTerms memory t = _baseTerms(100e18, _nonce++);
        t.completionFee = 4e18;
        t.completionFeeRecipient = feeRecipient;
        t.disputeTimeoutProviderBps = 0;
        bytes32 dealId = _activate(t);
        _markFiat(dealId);
        _openDispute(dealId);
        vm.warp(block.timestamp + 1 hours);
        escrow.disputeTimeout(dealId);
        assertEq(ledger.creditOf(address(token), feeRecipient), 0);
        assertEq(ledger.creditOf(address(token), holderReceiver), 100e18);
    }

    function test_claim_atExactReleaseDeadline() public {
        bytes32 dealId = _nextDeal(100e18);
        _markFiat(dealId);
        vm.warp(escrow.getDeal(dealId).releaseDeadline);
        escrow.claim(dealId);
        assertEq(uint8(escrow.getDeal(dealId).outcome), uint8(Outcome.TimeoutClaim));
    }

    function test_disputeTimeout_atExactDisputeDeadline() public {
        bytes32 dealId = _nextDeal(100e18);
        _markFiat(dealId);
        _openDispute(dealId);
        vm.warp(escrow.getDeal(dealId).disputeDeadline);
        escrow.disputeTimeout(dealId);
        assertEq(uint8(escrow.getDeal(dealId).outcome), uint8(Outcome.DisputeTimeout));
    }

    function test_fiatTimeout_atExactFiatDeadline() public {
        bytes32 dealId = _nextDeal(100e18);
        vm.warp(escrow.getDeal(dealId).fiatDeadline);
        escrow.fiatTimeoutCancel(dealId);
        assertEq(uint8(escrow.getDeal(dealId).outcome), uint8(Outcome.FiatTimeoutCancel));
    }
}
