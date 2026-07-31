// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Deployment intent / evidence types per MANDATORY_CORE.md §13.
// On-chain deployment identity is `intentHash` only. Evidence references
// that hash after deployment and is never constructor-bound.

bytes32 constant INTENT_SCHEMA_ID = keccak256("pluriswap.mandatory-core.intent.v1");
uint16 constant INTENT_SCHEMA_VERSION = 1;

bytes32 constant EVIDENCE_SCHEMA_ID = keccak256("pluriswap.mandatory-core.evidence.v1");
uint16 constant EVIDENCE_SCHEMA_VERSION = 1;

uint8 constant DEPLOYMENT_KIND_MANDATORY_CORE = 1;

/// @notice Off-chain Intent fields knowable before child CREATE.
/// @dev Creation-code hashes commit planned artifact identity without runtime
///      code hashes, transactions, or live readbacks.
struct CoreDeploymentIntentOffchain {
    bytes32 buildHash;
    bytes32 plannedDeploymentMethodHash;
    bytes32 coreDeployerCreationCodeHash;
    bytes32 factoryCreationCodeHash;
    bytes32 ledgerCreationCodeHash;
    bytes32 coordinatorCreationCodeHash;
    bytes32 escrowCreationCodeHash;
    bytes32 capabilityHash;
    bytes32 governanceHash;
    bytes32 predecessorIntentHash;
}

/// @notice Off-chain Evidence fields recorded after deployment.
/// @dev Requires a nonzero `intentHash`. Artifact hashes here are full ArtifactV1
///      commitments (including runtimeCodeHash).
struct CoreDeploymentEvidenceOffchain {
    bytes32 intentHash;
    bytes32 coreDeployerArtifactHash;
    bytes32 factoryArtifactHash;
    bytes32 ledgerArtifactHash;
    bytes32 coordinatorArtifactHash;
    bytes32 escrowArtifactHash;
    bytes32 deploymentMethodHash;
    bytes32 verificationHash;
}
