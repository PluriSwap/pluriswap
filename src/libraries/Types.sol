// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

enum Status {
    NONE,
    FUNDED,
    FIAT_SENT,
    DISPUTED,
    RELEASED,
    RESOLVED_SPLIT,
    STALEMATE,
    CANCELLED
}

struct DealTerms {
    address holder;
    address controller;
    address provider;
    address token;
    uint256 principal;
    uint256 fiatDuration;
    uint256 releaseDuration;
    uint256 disputeDuration;
    uint256 arbitrationDuration;
    bytes32[] packageIds;
}

struct HolderAuthorization {
    DealTerms terms;
    uint256 nonce;
    uint256 deadline;
}

struct ProviderAgreement {
    DealTerms terms;
    uint256 nonce;
    uint256 deadline;
}

struct ControllerAcceptance {
    DealTerms terms;
    uint256 nonce;
    uint256 deadline;
}

struct MutualCancel {
    bytes32 dealId;
    uint256 nonce;
    uint256 deadline;
}

struct CoSignedRelease {
    bytes32 dealId;
    uint256 nonce;
    uint256 deadline;
}

struct MutualSplit {
    bytes32 dealId;
    uint16 providerBps;
    uint256 nonce;
    uint256 deadline;
}
