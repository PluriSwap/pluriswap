// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    Deal,
    DealState,
    DealTerms,
    ModuleIdentity,
    ModuleRole,
    ResolutionAction,
    ResolutionAuth
} from "../libraries/DealTypes.sol";

interface ICoreEscrow {
    function activate(
        DealTerms calldata terms,
        bytes calldata holderSignature,
        bytes calldata providerSignature,
        bytes calldata activationData
    ) external returns (bytes32 dealId);

    function markFiatSent(bytes32 dealId) external;
    function providerCancel(bytes32 dealId) external;
    function fiatTimeoutCancel(bytes32 dealId) external;
    function holderRelease(bytes32 dealId) external;
    function claim(bytes32 dealId) external;
    function openDispute(bytes32 dealId, bytes calldata openData) external;
    function disputeTimeout(bytes32 dealId) external;

    function mutualResolve(
        bytes32 dealId,
        ResolutionAuth calldata auth,
        bytes calldata holderSignature,
        bytes calldata providerSignature
    ) external;

    function submitPaymentProof(bytes32 dealId, bytes calldata proofData) external;
    function openArbitration(bytes32 dealId, bytes calldata openData) external payable;
    function submitArbitrationRuling(bytes32 dealId, bytes calldata rulingData) external;
    function arbitrationTimeout(bytes32 dealId) external;

    function getDeal(bytes32 dealId) external view returns (Deal memory);
    function dealState(bytes32 dealId) external view returns (DealState);
    function termsHashOf(bytes32 dealId) external view returns (bytes32);
    function moduleOf(bytes32 dealId, ModuleRole role)
        external
        view
        returns (ModuleIdentity memory);

    function usedHolderNonce(address holder, uint256 nonce) external view returns (bool);
    function usedResolutionNonce(bytes32 dealId, ResolutionAction action, uint256 nonce)
        external
        view
        returns (bool);

    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function charterHash() external view returns (bytes32);
    function techSpecHash() external view returns (bytes32);
}
