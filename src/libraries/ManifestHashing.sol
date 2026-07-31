// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    CoreDeploymentEvidenceOffchain,
    CoreDeploymentIntentOffchain,
    DEPLOYMENT_KIND_MANDATORY_CORE,
    EVIDENCE_SCHEMA_ID,
    EVIDENCE_SCHEMA_VERSION,
    INTENT_SCHEMA_ID,
    INTENT_SCHEMA_VERSION
} from "./ManifestTypes.sol";

/// @notice Typed hashing for CoreDeploymentIntentV1 / CoreDeploymentEvidenceV1.
library ManifestHashing {
    bytes32 constant CORE_DEPLOYMENT_INTENT_V1_TYPEHASH = keccak256(
        "CoreDeploymentIntentV1(bytes32 schemaId,uint16 schemaVersion,uint8 deploymentKind,uint64 chainId,uint32 protocolVersion,bytes32 charterHash,bytes32 techSpecHash,bytes32 buildHash,bytes32 plannedDeploymentMethodHash,bytes32 coreDeployerCreationCodeHash,bytes32 factoryCreationCodeHash,bytes32 ledgerCreationCodeHash,bytes32 coordinatorCreationCodeHash,bytes32 escrowCreationCodeHash,address coreDeployer,address ledger,address coordinator,address escrow,bytes32 capabilityHash,bytes32 governanceHash,bytes32 predecessorIntentHash)"
    );

    bytes32 constant CORE_DEPLOYMENT_EVIDENCE_V1_TYPEHASH = keccak256(
        "CoreDeploymentEvidenceV1(bytes32 schemaId,uint16 schemaVersion,bytes32 intentHash,bytes32 coreDeployerArtifactHash,bytes32 factoryArtifactHash,bytes32 ledgerArtifactHash,bytes32 coordinatorArtifactHash,bytes32 escrowArtifactHash,bytes32 deploymentMethodHash,bytes32 verificationHash)"
    );

    /// @dev Computes intentHash from predicted addresses + off-chain Intent fields.
    function hashDeploymentIntent(
        uint64 chainId_,
        uint32 protocolVersion_,
        bytes32 charterHash_,
        bytes32 techSpecHash_,
        address coreDeployer,
        address ledger_,
        address coordinator_,
        address escrow_,
        CoreDeploymentIntentOffchain memory offchain
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                CORE_DEPLOYMENT_INTENT_V1_TYPEHASH,
                INTENT_SCHEMA_ID,
                INTENT_SCHEMA_VERSION,
                DEPLOYMENT_KIND_MANDATORY_CORE,
                chainId_,
                protocolVersion_,
                charterHash_,
                techSpecHash_,
                offchain.buildHash,
                offchain.plannedDeploymentMethodHash,
                offchain.coreDeployerCreationCodeHash,
                offchain.factoryCreationCodeHash,
                offchain.ledgerCreationCodeHash,
                offchain.coordinatorCreationCodeHash,
                offchain.escrowCreationCodeHash,
                coreDeployer,
                ledger_,
                coordinator_,
                escrow_,
                offchain.capabilityHash,
                offchain.governanceHash,
                offchain.predecessorIntentHash
            )
        );
    }

    /// @dev Computes evidenceHash. Rejects absent intent (caller must check zero).
    function hashDeploymentEvidence(CoreDeploymentEvidenceOffchain memory evidence)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                CORE_DEPLOYMENT_EVIDENCE_V1_TYPEHASH,
                EVIDENCE_SCHEMA_ID,
                EVIDENCE_SCHEMA_VERSION,
                evidence.intentHash,
                evidence.coreDeployerArtifactHash,
                evidence.factoryArtifactHash,
                evidence.ledgerArtifactHash,
                evidence.coordinatorArtifactHash,
                evidence.escrowArtifactHash,
                evidence.deploymentMethodHash,
                evidence.verificationHash
            )
        );
    }
}
