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
import {Terms} from "../src/libraries/Terms.sol";
import {Settlement} from "../src/libraries/Settlement.sol";
import {FeeOnTransferToken} from "../src/mocks/FeeOnTransferToken.sol";
import {Escrow} from "../src/Escrow.sol";
import {BaseTest} from "./Base.t.sol";

contract ActivateTest is BaseTest {
    function test_activate_p2p_fundedPullsExact() public {
        HolderAuthorization memory ha = _holderAuth(_p2pTerms(), 1);
        ProviderAgreement memory pa = _providerAuth(_p2pTerms(), 1);
        ControllerAcceptance memory ca;

        bytes32 id = escrow.activate(ha, _signHolder(ha), pa, _signProvider(pa), ca, "");

        bytes32 expected = Consent.dealId(escrow.domainSeparator(), ha.terms, ha.nonce, pa.nonce, 0);
        assertEq(id, expected);
        assertEq(uint8(escrow.status(id)), uint8(Status.FUNDED));
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.balanceOf(address(escrow)), PRINCIPAL);
        assertTrue(escrow.used(holder, ha.nonce));
        assertTrue(escrow.used(provider, pa.nonce));
    }

    function test_activate_revertsIfHolderSigBad() public {
        HolderAuthorization memory ha = _holderAuth(_p2pTerms(), 1);
        ProviderAgreement memory pa = _providerAuth(_p2pTerms(), 1);
        bytes memory holderSig = _signProvider(pa);
        bytes memory providerSig = _signProvider(pa);
        ControllerAcceptance memory ca;
        vm.expectRevert(Escrow.InvalidHolderSignature.selector);
        escrow.activate(ha, holderSig, pa, providerSig, ca, "");
    }

    function test_activate_revertsIfProviderSigBad() public {
        HolderAuthorization memory ha = _holderAuth(_p2pTerms(), 1);
        ProviderAgreement memory pa = _providerAuth(_p2pTerms(), 1);
        bytes memory holderSig = _signHolder(ha);
        bytes memory providerSig = _signHolder(ha);
        ControllerAcceptance memory ca;
        vm.expectRevert(Escrow.InvalidProviderSignature.selector);
        escrow.activate(ha, holderSig, pa, providerSig, ca, "");
    }

    function test_activate_revertsIfMissingControllerAcceptance() public {
        DealTerms memory terms = _poolTerms();
        HolderAuthorization memory ha = _holderAuth(terms, 1);
        ProviderAgreement memory pa = _providerAuth(terms, 1);
        bytes memory holderSig = _signHolder(ha);
        bytes memory providerSig = _signProvider(pa);
        ControllerAcceptance memory ca;
        vm.expectRevert(Escrow.ControllerAcceptanceRequired.selector);
        escrow.activate(ha, holderSig, pa, providerSig, ca, "");
    }

    function test_activate_revertsIfNonceReplay() public {
        _activateP2P(1, 1);
        token.mint(holder, PRINCIPAL);
        HolderAuthorization memory ha = _holderAuth(_p2pTerms(), 1);
        ProviderAgreement memory pa = _providerAuth(_p2pTerms(), 2);
        bytes memory holderSig = _signHolder(ha);
        bytes memory providerSig = _signProvider(pa);
        ControllerAcceptance memory ca;
        vm.expectRevert(Escrow.NonceUsed.selector);
        escrow.activate(ha, holderSig, pa, providerSig, ca, "");
    }

    function test_activate_revertsIfProviderNonceReplay() public {
        _activateP2P(1, 1);
        token.mint(holder, PRINCIPAL);
        HolderAuthorization memory ha = _holderAuth(_p2pTerms(), 2);
        ProviderAgreement memory pa = _providerAuth(_p2pTerms(), 1);
        bytes memory holderSig = _signHolder(ha);
        bytes memory providerSig = _signProvider(pa);
        ControllerAcceptance memory ca;
        vm.expectRevert(Escrow.NonceUsed.selector);
        escrow.activate(ha, holderSig, pa, providerSig, ca, "");
    }

    function test_activate_failedPull_doesNotConsumeNonce() public {
        FeeOnTransferToken feeToken = new FeeOnTransferToken();
        feeToken.mint(holder, PRINCIPAL);
        vm.prank(holder);
        feeToken.approve(address(escrow), PRINCIPAL);

        DealTerms memory terms = _p2pTerms();
        terms.token = address(feeToken);
        HolderAuthorization memory ha = _holderAuth(terms, 1);
        ProviderAgreement memory pa = _providerAuth(terms, 1);
        bytes memory holderSig = _signHolder(ha);
        bytes memory providerSig = _signProvider(pa);
        ControllerAcceptance memory ca;

        vm.expectRevert(Settlement.InexactPull.selector);
        escrow.activate(ha, holderSig, pa, providerSig, ca, "");

        assertFalse(escrow.used(holder, ha.nonce));
        assertFalse(escrow.used(provider, pa.nonce));
    }

    function test_activate_revertsIfDeadlinePassed() public {
        HolderAuthorization memory ha = _holderAuth(_p2pTerms(), 1);
        ProviderAgreement memory pa = _providerAuth(_p2pTerms(), 1);
        bytes memory holderSig = _signHolder(ha);
        bytes memory providerSig = _signProvider(pa);
        ControllerAcceptance memory ca;
        vm.warp(ha.deadline + 1);
        vm.expectRevert(Escrow.DeadlinePassed.selector);
        escrow.activate(ha, holderSig, pa, providerSig, ca, "");
    }

    function test_activate_twoConcurrentDealsDifferentNonces() public {
        token.mint(holder, PRINCIPAL);
        bytes32 id1 = _activateP2P(1, 1);
        bytes32 id2 = _activateP2P(2, 2);
        assertTrue(id1 != id2);
        assertEq(uint8(escrow.status(id1)), uint8(Status.FUNDED));
        assertEq(uint8(escrow.status(id2)), uint8(Status.FUNDED));
        assertEq(token.balanceOf(address(escrow)), PRINCIPAL * 2);
    }

    function test_cancelNonce_blocksActivate() public {
        vm.prank(holder);
        escrow.cancelNonce(1);

        HolderAuthorization memory ha = _holderAuth(_p2pTerms(), 1);
        ProviderAgreement memory pa = _providerAuth(_p2pTerms(), 1);
        bytes memory holderSig = _signHolder(ha);
        bytes memory providerSig = _signProvider(pa);
        ControllerAcceptance memory ca;

        vm.expectRevert(Escrow.NonceUsed.selector);
        escrow.activate(ha, holderSig, pa, providerSig, ca, "");
    }

    function test_activate_revertsIfHolderEqualsProvider() public {
        DealTerms memory terms = _p2pTerms();
        terms.provider = holder;
        HolderAuthorization memory ha = _holderAuth(terms, 1);
        ProviderAgreement memory pa = _providerAuth(terms, 1);
        ControllerAcceptance memory ca;
        vm.expectRevert(Terms.HolderEqualsProvider.selector);
        escrow.activate(ha, hex"", pa, hex"", ca, "");
    }
}
