// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {
    Status,
    DealTerms,
    HolderAuthorization,
    ProviderAgreement,
    ControllerAcceptance,
    MutualCancel,
    CoSignedRelease,
    MutualSplit
} from "./libraries/Types.sol";
import {Terms} from "./libraries/Terms.sol";
import {Consent} from "./libraries/Consent.sol";
import {Settlement} from "./libraries/Settlement.sol";
import {Clocks} from "./libraries/Clocks.sol";

contract Escrow is EIP712, ReentrancyGuardTransient {
    error TermsMismatch();
    error DeadlinePassed();
    error InvalidHolderSignature();
    error InvalidProviderSignature();
    error InvalidControllerSignature();
    error ControllerAcceptanceRequired();
    error NonceUsed();
    error DealExists();
    error Unauthorized();
    error WrongStatus();
    error DealIdMismatch();
    error DeadlineMismatch();
    error BpsMismatch();

    struct Deal {
        Status status;
        DealTerms terms;
        uint256 activatedAt;
        uint256 fiatSentAt;
        uint256 disputedAt;
    }

    mapping(address signer => mapping(uint256 nonce => bool consumed)) public used;
    mapping(bytes32 dealId => Deal) internal deals;
    Settlement.Store internal settlement;

    constructor() EIP712("PluriSwap", "1") {}

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function status(bytes32 dealId) external view returns (Status) {
        return deals[dealId].status;
    }

    function activate(
        HolderAuthorization calldata ha,
        bytes calldata holderSig,
        ProviderAgreement calldata pa,
        bytes calldata providerSig,
        ControllerAcceptance calldata ca,
        bytes calldata controllerSig
    ) external nonReentrant returns (bytes32 id) {
        DealTerms calldata terms = ha.terms;
        bytes32 termsHash = Terms.hashTerms(terms);
        if (termsHash != Terms.hashTerms(pa.terms)) revert TermsMismatch();

        if (block.timestamp > ha.deadline || block.timestamp > pa.deadline) revert DeadlinePassed();

        if (!Consent.isValid(terms.holder, _hashTypedDataV4(Consent.hashHolderAuthorization(ha)), holderSig)) {
            revert InvalidHolderSignature();
        }
        if (!Consent.isValid(terms.provider, _hashTypedDataV4(Consent.hashProviderAgreement(pa)), providerSig)) {
            revert InvalidProviderSignature();
        }

        uint256 controllerNonce;
        if (terms.holder != terms.controller) {
            if (ca.terms.controller != terms.controller) revert ControllerAcceptanceRequired();
            if (termsHash != Terms.hashTerms(ca.terms)) revert TermsMismatch();
            if (block.timestamp > ca.deadline) revert DeadlinePassed();
            if (!Consent.isValid(terms.controller, _hashTypedDataV4(Consent.hashControllerAcceptance(ca)), controllerSig))
            {
                revert InvalidControllerSignature();
            }
            if (used[terms.controller][ca.nonce]) revert NonceUsed();
            controllerNonce = ca.nonce;
        }

        if (used[terms.holder][ha.nonce] || used[terms.provider][pa.nonce]) revert NonceUsed();

        used[terms.holder][ha.nonce] = true;
        used[terms.provider][pa.nonce] = true;
        if (terms.holder != terms.controller) {
            used[terms.controller][ca.nonce] = true;
        }

        id = Consent.dealId(_domainSeparatorV4(), terms, ha.nonce, pa.nonce, controllerNonce);
        if (deals[id].status != Status.NONE) revert DealExists();

        Settlement.pullExact(terms.token, terms.holder, terms.principal);

        Deal storage d = deals[id];
        d.status = Status.FUNDED;
        d.terms = terms;
        d.activatedAt = block.timestamp;
    }

    function markFiat(bytes32 dealId) external nonReentrant {
        Deal storage d = deals[dealId];
        if (d.status != Status.FUNDED) revert WrongStatus();
        if (msg.sender != d.terms.provider) revert Unauthorized();
        d.status = Status.FIAT_SENT;
        d.fiatSentAt = block.timestamp;
    }

    function release(bytes32 dealId) external nonReentrant {
        Deal storage d = deals[dealId];
        if (d.status != Status.FIAT_SENT) revert WrongStatus();
        if (msg.sender != d.terms.controller) revert Unauthorized();
        d.status = Status.RELEASED;
        Settlement.creditThenTryPush(settlement, d.terms.token, d.terms.provider, d.terms.principal);
    }

    function cancelByProvider(bytes32 dealId) external nonReentrant {
        Deal storage d = deals[dealId];
        if (d.status != Status.FUNDED) revert WrongStatus();
        if (msg.sender != d.terms.provider) revert Unauthorized();
        d.status = Status.CANCELLED;
        Settlement.creditThenTryPush(settlement, d.terms.token, d.terms.holder, d.terms.principal);
    }

    function timeoutFiat(bytes32 dealId) external nonReentrant {
        Deal storage d = deals[dealId];
        if (d.status != Status.FUNDED) revert WrongStatus();
        Clocks.requireDue(d.activatedAt, d.terms.fiatDuration);
        d.status = Status.CANCELLED;
        Settlement.creditThenTryPush(settlement, d.terms.token, d.terms.holder, d.terms.principal);
    }

    function claim(bytes32 dealId) external nonReentrant {
        Deal storage d = deals[dealId];
        if (d.status != Status.FIAT_SENT) revert WrongStatus();
        Clocks.requireDue(d.fiatSentAt, d.terms.releaseDuration);
        d.status = Status.RELEASED;
        Settlement.creditThenTryPush(settlement, d.terms.token, d.terms.provider, d.terms.principal);
    }

    function openDisputed(bytes32 dealId) external nonReentrant {
        Deal storage d = deals[dealId];
        if (d.status != Status.FIAT_SENT) revert WrongStatus();
        if (msg.sender != d.terms.controller) revert Unauthorized();
        Clocks.requireStrictlyBefore(d.fiatSentAt, d.terms.releaseDuration);
        d.status = Status.DISPUTED;
        d.disputedAt = block.timestamp;
    }

    function forceStalemate(bytes32 dealId) external nonReentrant {
        Deal storage d = deals[dealId];
        if (d.status != Status.DISPUTED) revert WrongStatus();
        Clocks.requireDue(d.disputedAt, d.terms.disputeDuration);
        d.status = Status.STALEMATE;
        uint256 holderShare = d.terms.principal / 2;
        uint256 providerShare = d.terms.principal - holderShare;
        Settlement.creditThenTryPush(settlement, d.terms.token, d.terms.holder, holderShare);
        Settlement.creditThenTryPush(settlement, d.terms.token, d.terms.provider, providerShare);
    }

    function mutualCancel(
        MutualCancel calldata providerMsg,
        bytes calldata providerSig,
        MutualCancel calldata controllerMsg,
        bytes calldata controllerSig
    ) external nonReentrant {
        _assertDualSignEnvelope(providerMsg.dealId, providerMsg.deadline, controllerMsg.dealId, controllerMsg.deadline);
        Deal storage d = deals[providerMsg.dealId];
        _assertLiveForDualSign(d.status);
        _consumeDualSign(
            d.terms.provider,
            _hashTypedDataV4(Consent.hashMutualCancel(providerMsg)),
            providerSig,
            providerMsg.nonce,
            d.terms.controller,
            _hashTypedDataV4(Consent.hashMutualCancel(controllerMsg)),
            controllerSig,
            controllerMsg.nonce
        );
        d.status = Status.CANCELLED;
        Settlement.creditThenTryPush(settlement, d.terms.token, d.terms.holder, d.terms.principal);
    }

    function _assertDualSignEnvelope(bytes32 dealIdA, uint256 deadlineA, bytes32 dealIdB, uint256 deadlineB)
        private
        view
    {
        if (dealIdA != dealIdB) revert DealIdMismatch();
        if (deadlineA != deadlineB) revert DeadlineMismatch();
        if (block.timestamp > deadlineA) revert DeadlinePassed();
    }

    function _assertLiveForDualSign(Status s) private pure {
        if (s != Status.FUNDED && s != Status.FIAT_SENT && s != Status.DISPUTED) revert WrongStatus();
    }

    function _consumeDualSign(
        address provider,
        bytes32 providerDigest,
        bytes calldata providerSig,
        uint256 providerNonce,
        address controller,
        bytes32 controllerDigest,
        bytes calldata controllerSig,
        uint256 controllerNonce
    ) private {
        if (!Consent.isValid(provider, providerDigest, providerSig)) revert InvalidProviderSignature();
        if (!Consent.isValid(controller, controllerDigest, controllerSig)) revert InvalidControllerSignature();
        if (used[provider][providerNonce] || used[controller][controllerNonce]) revert NonceUsed();
        used[provider][providerNonce] = true;
        used[controller][controllerNonce] = true;
    }

    function _assertDualSignFromActive(Status s) private pure {
        if (s != Status.FIAT_SENT && s != Status.DISPUTED) revert WrongStatus();
    }

    function coSignedRelease(
        CoSignedRelease calldata providerMsg,
        bytes calldata providerSig,
        CoSignedRelease calldata controllerMsg,
        bytes calldata controllerSig
    ) external nonReentrant {
        _assertDualSignEnvelope(providerMsg.dealId, providerMsg.deadline, controllerMsg.dealId, controllerMsg.deadline);
        Deal storage d = deals[providerMsg.dealId];
        _assertDualSignFromActive(d.status);
        _consumeDualSign(
            d.terms.provider,
            _hashTypedDataV4(Consent.hashCoSignedRelease(providerMsg)),
            providerSig,
            providerMsg.nonce,
            d.terms.controller,
            _hashTypedDataV4(Consent.hashCoSignedRelease(controllerMsg)),
            controllerSig,
            controllerMsg.nonce
        );
        d.status = Status.RELEASED;
        Settlement.creditThenTryPush(settlement, d.terms.token, d.terms.provider, d.terms.principal);
    }

    function mutualSplit(
        MutualSplit calldata providerMsg,
        bytes calldata providerSig,
        MutualSplit calldata controllerMsg,
        bytes calldata controllerSig
    ) external nonReentrant {
        _assertDualSignEnvelope(providerMsg.dealId, providerMsg.deadline, controllerMsg.dealId, controllerMsg.deadline);
        if (providerMsg.providerBps != controllerMsg.providerBps) revert BpsMismatch();
        Deal storage d = deals[providerMsg.dealId];
        _assertDualSignFromActive(d.status);
        _consumeDualSign(
            d.terms.provider,
            _hashTypedDataV4(Consent.hashMutualSplit(providerMsg)),
            providerSig,
            providerMsg.nonce,
            d.terms.controller,
            _hashTypedDataV4(Consent.hashMutualSplit(controllerMsg)),
            controllerSig,
            controllerMsg.nonce
        );
        d.status = Status.RESOLVED_SPLIT;
        uint256 providerShare = d.terms.principal * uint256(providerMsg.providerBps) / 10_000;
        uint256 holderShare = d.terms.principal - providerShare;
        Settlement.creditThenTryPush(settlement, d.terms.token, d.terms.provider, providerShare);
        Settlement.creditThenTryPush(settlement, d.terms.token, d.terms.holder, holderShare);
    }

    function creditOf(address token, address beneficiary) external view returns (uint256) {
        return Settlement.creditOf(settlement, token, beneficiary);
    }

    function withdraw(address token) external nonReentrant {
        Settlement.withdraw(settlement, token, msg.sender);
    }

    function cancelNonce(uint256 nonce) external {
        used[msg.sender][nonce] = true;
    }
}
