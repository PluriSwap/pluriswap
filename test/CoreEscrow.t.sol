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
    NonceUsed,
    ProfileDisabled,
    TerminalDeal,
    Unauthorized
} from "../src/libraries/CoreErrors.sol";
import {ProfileFlags} from "../src/libraries/DealTypes.sol";

contract CoreEscrowTest is CoreTestBase {
    function test_activate_funded() public {
        DealTerms memory t = _baseTerms(100e18, 1);
        bytes32 dealId = _activate(t);
        assertEq(uint8(escrow.dealState(dealId)), uint8(DealState.Funded));
        assertEq(token.balanceOf(address(escrow)), 100e18);
        assertTrue(escrow.usedHolderNonce(holder, 1));
    }

    function test_activate_nonceReplay_reverts() public {
        DealTerms memory t = _baseTerms(100e18, 1);
        _activate(t);
        token.mint(holder, 100e18);
        vm.prank(holder);
        token.approve(address(escrow), type(uint256).max);
        bytes memory holderSig = DealSigUtils.signDeal(holderPk, domainSep, t);
        bytes memory providerSig = DealSigUtils.signDeal(providerPk, domainSep, t);
        vm.expectRevert(NonceUsed.selector);
        escrow.activate(t, holderSig, providerSig, "");
    }

    function test_activate_expired_reverts() public {
        DealTerms memory t = _baseTerms(100e18, 1);
        t.createExpiry = uint64(block.timestamp - 1);
        token.mint(holder, 100e18);
        vm.prank(holder);
        token.approve(address(escrow), type(uint256).max);
        bytes memory holderSig = DealSigUtils.signDeal(holderPk, domainSep, t);
        bytes memory providerSig = DealSigUtils.signDeal(providerPk, domainSep, t);
        vm.expectRevert(Expired.selector);
        escrow.activate(t, holderSig, providerSig, "");
    }

    function test_activate_profileFlags_reverts() public {
        DealTerms memory t = _baseTerms(100e18, 1);
        t.profileFlags = ProfileFlags.PAYMENT_PROOF;
        token.mint(holder, 100e18);
        vm.prank(holder);
        token.approve(address(escrow), type(uint256).max);
        bytes memory holderSig = DealSigUtils.signDeal(holderPk, domainSep, t);
        bytes memory providerSig = DealSigUtils.signDeal(providerPk, domainSep, t);
        vm.expectRevert(InvalidTerms.selector);
        escrow.activate(t, holderSig, providerSig, "");
    }

    function test_markFiat_and_holderRelease() public {
        bytes32 dealId = _activate(_baseTerms(100e18, 1));
        vm.prank(provider);
        escrow.markFiatSent(dealId);
        assertEq(uint8(escrow.dealState(dealId)), uint8(DealState.FiatSent));

        vm.prank(holder);
        escrow.holderRelease(dealId);
        assertEq(uint8(escrow.dealState(dealId)), uint8(DealState.Released));
        assertEq(ledger.creditOf(address(token), providerReceiver), 100e18);
    }

    function test_activationFee_and_completionFee() public {
        DealTerms memory t = _baseTerms(100e18, 1);
        t.activationFee = 1e18;
        t.activationFeeRecipient = feeRecipient;
        t.completionFee = 2e18;
        t.completionFeeRecipient = feeRecipient;
        bytes32 dealId = _activate(t);

        vm.prank(provider);
        escrow.markFiatSent(dealId);
        vm.prank(holder);
        escrow.holderRelease(dealId);

        assertEq(ledger.creditOf(address(token), feeRecipient), 1e18 + 2e18);
        assertEq(ledger.creditOf(address(token), providerReceiver), 98e18);
    }

    function test_providerCancel() public {
        bytes32 dealId = _activate(_baseTerms(100e18, 1));
        vm.prank(provider);
        escrow.providerCancel(dealId);
        assertEq(ledger.creditOf(address(token), holderReceiver), 100e18);
        assertEq(uint8(escrow.getDeal(dealId).outcome), uint8(Outcome.ProviderCancel));
    }

    function test_fiatTimeout() public {
        bytes32 dealId = _activate(_baseTerms(100e18, 1));
        vm.warp(block.timestamp + 1 hours);
        escrow.fiatTimeoutCancel(dealId);
        assertEq(ledger.creditOf(address(token), holderReceiver), 100e18);
        assertEq(uint8(escrow.getDeal(dealId).outcome), uint8(Outcome.FiatTimeoutCancel));
    }

    function test_fiatTimeout_beforeDeadline_reverts() public {
        bytes32 dealId = _activate(_baseTerms(100e18, 1));
        vm.expectRevert(InvalidTiming.selector);
        escrow.fiatTimeoutCancel(dealId);
    }

    function test_claim_afterReleaseDeadline() public {
        bytes32 dealId = _activate(_baseTerms(100e18, 1));
        vm.prank(provider);
        escrow.markFiatSent(dealId);
        vm.warp(block.timestamp + 1 hours);
        escrow.claim(dealId);
        assertEq(uint8(escrow.getDeal(dealId).outcome), uint8(Outcome.TimeoutClaim));
        assertEq(ledger.creditOf(address(token), providerReceiver), 100e18);
    }

    function test_openDispute_blocksClaim() public {
        bytes32 dealId = _activate(_baseTerms(100e18, 1));
        vm.prank(provider);
        escrow.markFiatSent(dealId);
        vm.prank(holder);
        escrow.openDispute(dealId, "");
        assertEq(uint8(escrow.dealState(dealId)), uint8(DealState.Disputed));

        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert(InvalidState.selector);
        escrow.claim(dealId);

        vm.prank(holder);
        vm.expectRevert(InvalidState.selector);
        escrow.holderRelease(dealId);
    }

    function test_disputeTimeout_residual() public {
        bytes32 dealId = _activate(_baseTerms(100e18, 1));
        vm.prank(provider);
        escrow.markFiatSent(dealId);
        vm.prank(holder);
        escrow.openDispute(dealId, "");
        vm.warp(block.timestamp + 1 hours);
        escrow.disputeTimeout(dealId);
        assertEq(ledger.creditOf(address(token), providerReceiver), 50e18);
        assertEq(ledger.creditOf(address(token), holderReceiver), 50e18);
        assertEq(uint8(escrow.getDeal(dealId).outcome), uint8(Outcome.DisputeTimeout));
    }

    function test_mutualCancel() public {
        bytes32 dealId = _activate(_baseTerms(100e18, 1));
        ResolutionAuth memory auth;
        auth.dealId = dealId;
        auth.action = ResolutionAction.MutualCancel;
        auth.resolutionNonce = 1;
        auth.expiry = uint64(block.timestamp + 1 days);
        bytes memory hSig = DealSigUtils.signResolution(holderPk, domainSep, auth);
        bytes memory pSig = DealSigUtils.signResolution(providerPk, domainSep, auth);
        escrow.mutualResolve(dealId, auth, hSig, pSig);
        assertEq(ledger.creditOf(address(token), holderReceiver), 100e18);
    }

    function test_mutualSplit() public {
        bytes32 dealId = _activate(_baseTerms(100e18, 1));
        vm.prank(provider);
        escrow.markFiatSent(dealId);

        ResolutionAuth memory auth;
        auth.dealId = dealId;
        auth.action = ResolutionAction.Split;
        auth.resolutionNonce = 1;
        auth.expiry = uint64(block.timestamp + 1 days);
        auth.providerShareBps = 2500;
        bytes memory hSig = DealSigUtils.signResolution(holderPk, domainSep, auth);
        bytes memory pSig = DealSigUtils.signResolution(providerPk, domainSep, auth);
        escrow.mutualResolve(dealId, auth, hSig, pSig);

        assertEq(ledger.creditOf(address(token), providerReceiver), 25e18);
        assertEq(ledger.creditOf(address(token), holderReceiver), 75e18);
    }

    function test_extensionStubs_revert() public {
        bytes32 dealId = _activate(_baseTerms(100e18, 1));
        vm.expectRevert(ProfileDisabled.selector);
        escrow.submitPaymentProof(dealId, "");
        vm.expectRevert(ProfileDisabled.selector);
        escrow.openArbitration(dealId, "");
        vm.expectRevert(ProfileDisabled.selector);
        escrow.submitArbitrationRuling(dealId, "");
        vm.expectRevert(ProfileDisabled.selector);
        escrow.arbitrationTimeout(dealId);
    }

    function test_markFiat_nonProvider_reverts() public {
        bytes32 dealId = _activate(_baseTerms(100e18, 1));
        vm.expectRevert(Unauthorized.selector);
        escrow.markFiatSent(dealId);
    }

    function test_terminal_rejectsLaterAction() public {
        bytes32 dealId = _activate(_baseTerms(100e18, 1));
        vm.prank(provider);
        escrow.providerCancel(dealId);
        vm.prank(provider);
        vm.expectRevert(TerminalDeal.selector);
        escrow.providerCancel(dealId);
    }
}
