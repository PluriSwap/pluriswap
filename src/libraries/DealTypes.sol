// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

enum DealState {
    None,
    Funded,
    FiatSent,
    Disputed,
    Released,
    ResolvedSplit,
    ResolvedByDisputeTimeout,
    Cancelled,
    ArbitrationActive,
    ResolvedByArbitration,
    Stalemate
}

enum Outcome {
    None,
    VoluntaryRelease,
    CosignedRelease,
    PaymentProofRelease,
    TimeoutClaim,
    ProviderCancel,
    FiatTimeoutCancel,
    MutualCancel,
    MutualSplit,
    ArbitrationHolderWin,
    ArbitrationProviderWin,
    ArbitrationRefused,
    ArbitrationTimeout,
    DisputeTimeout
}

enum ModuleRole {
    PaymentProofVerifier,
    ArbitrationAdapter,
    BondVault,
    Pool,
    HumanityVerifier,
    ReputationPolicy,
    RatePolicy,
    PackagePolicy
}

enum ResolutionAction {
    MutualCancel,
    CosignedRelease,
    Split
}

library ProfileFlags {
    uint32 internal constant PAYMENT_PROOF = 1 << 0;
    uint32 internal constant ARBITRATION = 1 << 1;
    uint32 internal constant BONDS = 1 << 2;
    uint32 internal constant POOL = 1 << 3;
    uint32 internal constant REPUTATION = 1 << 4;
    uint32 internal constant HUMANITY = 1 << 5;
    uint32 internal constant RATE_POLICY = 1 << 6;
    uint32 internal constant CROWDFUNDED_POOL = 1 << 7;
}

struct ModuleIdentity {
    ModuleRole role;
    address module;
    bytes32 codehash;
    bytes32 policyHash;
}

struct DealTerms {
    address holder;
    address provider;
    address holderReceiver;
    address providerReceiver;
    address token;
    bytes32 tokenRiskHash;
    bytes32 custodyBoundaryId;
    uint256 principal;
    uint256 activationFee;
    address activationFeeRecipient;
    uint256 completionFee;
    address completionFeeRecipient;
    uint256 nonce;
    uint64 createExpiry;
    uint64 fiatDuration;
    uint64 releaseDuration;
    uint64 disputeDuration;
    uint16 disputeTimeoutProviderBps;
    bytes32 fiatCurrency;
    uint256 fiatAmount;
    bytes32 paymentMethod;
    bytes32 payeeCommitment;
    bytes32 paymentReferenceCommitment;
    uint32 profileFlags;
    bytes32 packageId;
    bytes32 packageHash;
    ModuleIdentity[] modules;
    bytes extensions;
}

struct Deal {
    DealState state;
    Outcome outcome;
    address holder;
    address provider;
    address holderReceiver;
    address providerReceiver;
    address token;
    uint256 principal;
    uint256 activationFee;
    address activationFeeRecipient;
    uint256 completionFee;
    address completionFeeRecipient;
    uint16 disputeTimeoutProviderBps;
    uint64 activatedAt;
    uint64 fiatDeadline;
    uint64 releaseDuration;
    uint64 releaseDeadline;
    uint64 disputeDuration;
    uint64 disputeDeadline;
    uint32 profileFlags;
    bytes32 packageId;
    bytes32 packageHash;
    bytes32 termsHash;
    bytes32 custodyBoundaryId;
    bytes32 tokenRiskHash;
    bytes32 extensionsHash;
    ModuleIdentity[8] modules;
}

struct ResolutionAuth {
    bytes32 dealId;
    ResolutionAction action;
    uint256 resolutionNonce;
    uint64 expiry;
    uint16 providerShareBps;
    bytes extensions;
}

function isTerminal(DealState s) pure returns (bool) {
    return uint8(s) >= uint8(DealState.Released);
}
