// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    Deal,
    DealTerms,
    FundingSpec,
    FundingAuth,
    ResolutionAction,
    ResolutionAuth,
    TerminalRecord
} from "../libraries/DealTypes.sol";

interface ICoreEscrow {
    // ── Activation ────────────────────────────────────────────────────────────

    /// @notice Activate a deal with typed funding specs and authorizations.
    /// @dev Core-only: profileFlags must be 0; all optional hash fields canonical zero.
    function activate(
        DealTerms calldata terms,
        FundingSpec calldata principalFunding,
        FundingSpec calldata activationFeeFunding,
        FundingAuth calldata principalFundingAuth,
        FundingAuth calldata activationFeeFundingAuth,
        bytes calldata principalFundingSig,
        bytes calldata activationFeeFundingSig,
        bytes calldata holderSig,
        bytes calldata providerSig
    ) external returns (bytes32 dealId, uint8 reconciliationStatus);

    // ── Core transitions ───────────────────────────────────────────────────────

    function markFiatSent(bytes32 dealId) external;
    function providerCancel(bytes32 dealId) external returns (uint8 reconciliationStatus);
    function fiatTimeoutCancel(bytes32 dealId) external returns (uint8 reconciliationStatus);
    function holderRelease(bytes32 dealId) external returns (uint8 reconciliationStatus);
    function claim(bytes32 dealId) external returns (uint8 reconciliationStatus);
    function openDispute(bytes32 dealId, bytes calldata openData) external;
    function disputeTimeout(bytes32 dealId) external returns (uint8 reconciliationStatus);

    function mutualResolve(
        bytes32 dealId,
        ResolutionAuth calldata auth,
        bytes calldata holderSig,
        bytes calldata providerSig
    ) external returns (uint8 reconciliationStatus);

    // ── Extension surfaces (reject when profile not selected) ──────────────────

    function submitPaymentProof(bytes32 dealId, bytes calldata proofData) external;
    function openArbitration(bytes32 dealId, bytes calldata openData) external payable;
    function submitArbitrationRuling(bytes32 dealId, bytes calldata rulingData) external;
    function arbitrationTimeout(bytes32 dealId) external;

    // ── Views ──────────────────────────────────────────────────────────────────

    function getDeal(bytes32 dealId) external view returns (Deal memory);
    function dealState(bytes32 dealId) external view returns (uint8);
    function termsHashOf(bytes32 dealId) external view returns (bytes32);
    function getTerminalRecord(bytes32 dealId) external view returns (TerminalRecord memory);
    function getTerminalHash(bytes32 dealId) external view returns (bytes32);
    function usedHolderNonce(address holder, uint256 nonce) external view returns (bool);
    function usedResolutionNonce(bytes32 dealId, ResolutionAction action, uint256 nonce)
        external
        view
        returns (bool);

    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function charterHash() external view returns (bytes32);
    function techSpecHash() external view returns (bytes32);
    function manifestHash() external view returns (bytes32);
}
