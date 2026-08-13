// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {
    DealTerms,
    HolderAuthorization,
    ProviderAgreement,
    ControllerAcceptance
} from "../src/libraries/Types.sol";
import {Consent} from "../src/libraries/Consent.sol";
import {Escrow} from "../src/Escrow.sol";
import {TestToken} from "../src/TestToken.sol";

contract BaseTest is Test {
    uint256 internal constant PRINCIPAL = 1_000_000;

    uint256 internal holderPk = 0xA11CE;
    uint256 internal providerPk = 0xB0B;
    uint256 internal controllerPk = 0xC0;

    Escrow internal escrow;
    TestToken internal token;
    address internal holder;
    address internal provider;
    address internal controller;

    function setUp() public virtual {
        holder = vm.addr(holderPk);
        provider = vm.addr(providerPk);
        controller = vm.addr(controllerPk);
        token = new TestToken();
        escrow = new Escrow();
        token.mint(holder, PRINCIPAL);
        vm.prank(holder);
        token.approve(address(escrow), type(uint256).max);
    }

    function _p2pTerms() internal view returns (DealTerms memory t) {
        t.holder = holder;
        t.controller = holder;
        t.provider = provider;
        t.token = address(token);
        t.principal = PRINCIPAL;
        t.fiatDuration = 3600;
        t.releaseDuration = 1800;
        t.disputeDuration = 7200;
        t.packageIds = new bytes32[](0);
    }

    function _typed(bytes32 structHash) internal view returns (bytes32) {
        return MessageHashUtils.toTypedDataHash(escrow.domainSeparator(), structHash);
    }

    function _sign(bytes32 digest, uint256 pk) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _holderAuth(DealTerms memory terms, uint256 nonce)
        internal
        view
        returns (HolderAuthorization memory a)
    {
        a.terms = terms;
        a.nonce = nonce;
        a.deadline = block.timestamp + 1 days;
    }

    function _providerAuth(DealTerms memory terms, uint256 nonce)
        internal
        view
        returns (ProviderAgreement memory a)
    {
        a.terms = terms;
        a.nonce = nonce;
        a.deadline = block.timestamp + 1 days;
    }

    function _controllerAuth(DealTerms memory terms, uint256 nonce)
        internal
        view
        returns (ControllerAcceptance memory a)
    {
        a.terms = terms;
        a.nonce = nonce;
        a.deadline = block.timestamp + 1 days;
    }

    function _signHolder(HolderAuthorization memory a) internal view returns (bytes memory) {
        return _sign(_typed(Consent.hashHolderAuthorization(a)), holderPk);
    }

    function _signProvider(ProviderAgreement memory a) internal view returns (bytes memory) {
        return _sign(_typed(Consent.hashProviderAgreement(a)), providerPk);
    }

    function _signController(ControllerAcceptance memory a) internal view returns (bytes memory) {
        return _sign(_typed(Consent.hashControllerAcceptance(a)), controllerPk);
    }

    function _poolTerms() internal view returns (DealTerms memory t) {
        t = _p2pTerms();
        t.controller = controller;
    }

    function _activateP2P(uint256 holderNonce, uint256 providerNonce) internal returns (bytes32) {
        HolderAuthorization memory ha = _holderAuth(_p2pTerms(), holderNonce);
        ProviderAgreement memory pa = _providerAuth(_p2pTerms(), providerNonce);
        ControllerAcceptance memory ca;
        return escrow.activate(ha, _signHolder(ha), pa, _signProvider(pa), ca, "");
    }

    function _activateP2PWith(DealTerms memory terms, uint256 holderNonce, uint256 providerNonce)
        internal
        returns (bytes32)
    {
        HolderAuthorization memory ha = _holderAuth(terms, holderNonce);
        ProviderAgreement memory pa = _providerAuth(terms, providerNonce);
        ControllerAcceptance memory ca;
        return escrow.activate(ha, _signHolder(ha), pa, _signProvider(pa), ca, "");
    }

    function _activateDistinctController(uint256 holderNonce, uint256 providerNonce, uint256 controllerNonce)
        internal
        returns (bytes32)
    {
        DealTerms memory terms = _poolTerms();
        HolderAuthorization memory ha = _holderAuth(terms, holderNonce);
        ProviderAgreement memory pa = _providerAuth(terms, providerNonce);
        ControllerAcceptance memory ca = _controllerAuth(terms, controllerNonce);
        return escrow.activate(ha, _signHolder(ha), pa, _signProvider(pa), ca, _signController(ca));
    }
}
