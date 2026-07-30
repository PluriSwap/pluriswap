// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ──────────────────────────────────────────────────────────────────────────────
// Deal states — fixed uint8 wire/storage IDs per MANDATORY_CORE.md §2.3
// Terminal states at 16-21; ordinal comparison is forbidden.
// ──────────────────────────────────────────────────────────────────────────────

library DealState {
    uint8 constant None = 0;
    uint8 constant Funded = 1;
    uint8 constant FiatSent = 2;
    uint8 constant Disputed = 3;
    uint8 constant ArbitrationActive = 4;
    // 5-15 reserved
    uint8 constant Released = 16;
    uint8 constant ResolvedSplit = 17;
    uint8 constant ResolvedByDisputeTimeout = 18;
    uint8 constant Cancelled = 19;
    uint8 constant ResolvedByArbitration = 20;
    uint8 constant Stalemate = 21;
}

// ──────────────────────────────────────────────────────────────────────────────
// Outcomes — fixed uint8 IDs per MANDATORY_CORE.md §2.4
// ──────────────────────────────────────────────────────────────────────────────

library Outcome {
    uint8 constant Invalid = 0;
    uint8 constant VoluntaryRelease = 1;
    uint8 constant CosignedRelease = 2;
    uint8 constant PaymentProofRelease = 3;
    uint8 constant TimeoutClaim = 4;
    uint8 constant ProviderCancel = 5;
    uint8 constant FiatTimeoutCancel = 6;
    uint8 constant MutualCancel = 7;
    uint8 constant MutualSplit = 8;
    uint8 constant ArbitrationHolderWin = 9;
    uint8 constant ArbitrationProviderWin = 10;
    uint8 constant ArbitrationRefused = 11;
    uint8 constant ArbitrationTimeout = 12;
    uint8 constant DisputeTimeout = 13;
}

// ──────────────────────────────────────────────────────────────────────────────
// Module roles — contiguous 0-7 per MANDATORY_CORE.md §2.5
// ──────────────────────────────────────────────────────────────────────────────

enum ModuleRole {
    PaymentProofVerifier, // 0
    ArbitrationAdapter, // 1
    BondVault, // 2
    Pool, // 3
    HumanityVerifier, // 4
    ReputationPolicy, // 5
    RatePolicy, // 6
    PackagePolicy // 7
}

// ──────────────────────────────────────────────────────────────────────────────
// Resolution actions — fixed wire IDs 1-3 per MANDATORY_CORE.md §6.6.
// ──────────────────────────────────────────────────────────────────────────────

enum ResolutionAction {
    Invalid, // 0
    MutualCancel, // 1
    CosignedRelease, // 2
    Split // 3
}

// ──────────────────────────────────────────────────────────────────────────────
// Pool kind — contiguous 0-3 per MANDATORY_CORE.md §2.5
// ──────────────────────────────────────────────────────────────────────────────

enum PoolKind {
    None, // 0
    Owned, // 1
    Custom, // 2
    Crowdfunded // 3
}

// ──────────────────────────────────────────────────────────────────────────────
// Funding purpose / source mode — start at 1 per MANDATORY_CORE.md §6.4
// ──────────────────────────────────────────────────────────────────────────────

library FundingPurpose {
    uint8 constant Principal = 1;
    uint8 constant ActivationFee = 2;
}

library FundingSourceMode {
    uint8 constant WalletPull = 1;
    uint8 constant LedgerPosition = 2;
}

// ──────────────────────────────────────────────────────────────────────────────
// Position kinds — start at 1 per MANDATORY_CORE.md §3.3
// ──────────────────────────────────────────────────────────────────────────────

library PositionKind {
    uint8 constant Deal = 1;
    uint8 constant ActivationFee = 2;
    uint8 constant DealTerminal = 3;
    uint8 constant Reservation = 4;
    uint8 constant ReservationTerminal = 5;
}

// ──────────────────────────────────────────────────────────────────────────────
// Profile flags — uint32 bitfield per MANDATORY_CORE.md §2.5
// ──────────────────────────────────────────────────────────────────────────────

library ProfileFlags {
    uint32 constant PaymentProof = 1 << 0;
    uint32 constant Arbitration = 1 << 1;
    uint32 constant Bonds = 1 << 2;
    uint32 constant Pool = 1 << 3;
    uint32 constant Reputation = 1 << 4;
    uint32 constant Humanity = 1 << 5;
    uint32 constant RatePolicy = 1 << 6;
    uint32 constant CrowdfundedPool = 1 << 7;
}

// ──────────────────────────────────────────────────────────────────────────────
// Operator-fault classification per MANDATORY_CORE.md §2.6
// ──────────────────────────────────────────────────────────────────────────────

library OperatorFaultCode {
    uint8 constant NoFault = 0;
    uint8 constant MutualFault = 1;
    uint8 constant AuthenticatedFault = 2;
}

// ──────────────────────────────────────────────────────────────────────────────
// Reconciliation statuses per MANDATORY_CORE.md §4.2
// ──────────────────────────────────────────────────────────────────────────────

library ReconciliationStatus {
    uint8 constant Unchanged = 0;
    uint8 constant SurplusQuarantined = 1;
    uint8 constant ReservedInvalid = 2; // never returned; malformed
    uint8 constant QuarantineLossAbsorbed = 3;
    uint8 constant DeficitCheckpointed = 4;
}

// ──────────────────────────────────────────────────────────────────────────────
// Boundary mode per MANDATORY_CORE.md §3.2
// ──────────────────────────────────────────────────────────────────────────────

library BoundaryMode {
    uint8 constant Healthy = 0;
    uint8 constant Deficit = 1;
}

// ──────────────────────────────────────────────────────────────────────────────
// Payout result codes per MANDATORY_CORE.md §6.7
// ──────────────────────────────────────────────────────────────────────────────

library PayoutResultCode {
    uint8 constant HealthyPartial = 1;
    uint8 constant HealthyFull = 2;
    uint8 constant DeficitPaid = 3;
    uint8 constant ZeroPayable = 4;
    uint8 constant DeficitClaimRequired = 5;
    uint8 constant ReconciliationOnly = 6;
}

// ──────────────────────────────────────────────────────────────────────────────
// Structs
// ──────────────────────────────────────────────────────────────────────────────

/// @notice Module binding per MANDATORY_CORE.md §6.2 — 8 fields.
struct ModuleBinding {
    uint8 role;
    address module;
    bytes32 runtimeCodeHash;
    bytes32 policyHash;
    bytes32 manifestHash;
    bytes32 apiId;
    bytes32 moduleTermsHash;
    uint32 capabilityMask;
}

/// @notice Funding specification per MANDATORY_CORE.md §6.4.
struct FundingSpec {
    uint8 purpose; // FundingPurpose
    uint8 sourceMode; // FundingSourceMode
    address token;
    uint256 amount;
    address source;
    bytes32 sourcePositionId;
    address authority;
}

/// @notice Funding authorization per MANDATORY_CORE.md §6.4 — Ledger-domain.
struct FundingAuth {
    bytes32 termsHash;
    bytes32 fundingSpecHash;
    uint8 purpose; // FundingPurpose
    address authority;
    uint256 nonce;
    uint64 expiry;
}

/// @notice Deal terms per MANDATORY_CORE.md §6.4 — EIP-712 struct (all fixed-size).
struct DealTerms {
    address holder;
    address provider;
    address holderReceiver;
    address providerReceiver;
    address token;
    bytes32 principalFundingHash;
    bytes32 activationFeeFundingHash;
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
    bytes32 packageSelectionHash;
    bytes32 packageContestTermsHash;
    bytes32 poolAuthorityHash;
    bytes32 arbitrationTermsHash;
    bytes32 reservationsHash;
    bytes32 modulesHash;
    bytes32 extensionsHash;
}

/// @notice Resolution authorization per MANDATORY_CORE.md §6.6 — EIP-712 struct.
struct ResolutionAuth {
    bytes32 dealId;
    uint8 action; // ResolutionAction
    uint256 resolutionNonce;
    uint64 expiry;
    uint16 providerShareBps;
    uint8 operatorFaultCode;
    bytes32 operatorFaultEvidenceHash;
    bytes32 reservationDispositionsHash;
    bytes32 extensionsHash;
}

/// @notice Terminal record per MANDATORY_CORE.md §11.1 — 27 fields.
struct TerminalRecord {
    uint64 chainId;
    uint32 protocolVersion;
    address escrow;
    address ledger;
    bytes32 dealId;
    uint8 terminalState;
    uint8 outcome;
    uint8 operatorFaultCode;
    bytes32 operatorFaultEvidenceHash;
    address token;
    uint256 principal;
    uint256 holderSideReturn;
    uint256 providerGross;
    uint256 providerNet;
    uint256 completionCollected;
    uint256 operatorFeePaid;
    uint256 operatorFeeUnlocked;
    address holderReceiver;
    address providerReceiver;
    address completionFeeRecipient;
    address operatorFeeRecipient;
    address operatorFeeReturnReceiver;
    bytes32 termsHash;
    bytes32 modulesHash;
    bytes32 evidenceHash;
    bytes32 reservationsHash;
    bytes32 reservationDispositionsHash;
    uint64 terminatedAt;
}

/// @notice Deal storage — runtime state machine + snapshotted fields.
struct Deal {
    uint8 state; // DealState
    uint8 outcome; // Outcome
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
    bytes32 termsHash;
    bytes32 custodyBoundaryId;
    bytes32 modulesHash;
    bytes32 terminalHash;
}

/// @notice Position payout authorization per MANDATORY_CORE.md §6.7 — Ledger-domain.
struct PositionPayoutAuth {
    uint8 action;
    address token;
    bytes32 positionId;
    address beneficiary;
    address to;
    uint256 maxAmount; // type(uint256).max = sentinel (all payable)
    uint256 nonce;
    uint64 expiry;
}

/// @notice Position payout result per MANDATORY_CORE.md §6.7.
struct PositionPayoutResult {
    uint8 code;
    uint8 reconciliationStatus;
    bytes32 positionId;
    address receiver;
    uint256 paidAmount;
    uint256 nominalRemaining;
}

/// @notice Terminal allocation — coalesced output for settlement.
struct TerminalAllocation {
    address beneficiary;
    uint256 amount;
    bytes32 positionId;
}

// ──────────────────────────────────────────────────────────────────────────────
// Deployment manifest per MANDATORY_CORE.md §13
// ──────────────────────────────────────────────────────────────────────────────

bytes32 constant MANIFEST_SCHEMA_ID = keccak256("pluriswap.mandatory-core.manifest.v1");
uint16 constant MANIFEST_SCHEMA_VERSION = 1;
uint8 constant DEPLOYMENT_KIND_MANDATORY_CORE = 1;

/// @notice Off-chain manifest fields that cannot be computed on-chain.
struct CoreManifestOffchain {
    bytes32 buildHash;
    bytes32 deploymentMethodHash;
    bytes32 coreDeployerArtifactHash;
    bytes32 factoryArtifactHash;
    bytes32 ledgerArtifactHash;
    bytes32 coordinatorArtifactHash;
    bytes32 escrowArtifactHash;
    bytes32 capabilityHash;
    bytes32 governanceHash;
    bytes32 verificationHash;
    bytes32 predecessorManifestHash;
}

// ──────────────────────────────────────────────────────────────────────────────
// Predicates
// ──────────────────────────────────────────────────────────────────────────────

/// @dev Explicit membership check — never ordinal comparison (MANDATORY_CORE.md §2.3).
function isTerminal(uint8 state) pure returns (bool) {
    return state == DealState.Released || state == DealState.ResolvedSplit
        || state == DealState.ResolvedByDisputeTimeout || state == DealState.Cancelled
        || state == DealState.ResolvedByArbitration || state == DealState.Stalemate;
}
