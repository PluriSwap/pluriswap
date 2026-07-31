// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DealHashing} from "../src/libraries/DealHashing.sol";
import {
    FundingAuth,
    FundingSpec,
    ResolutionAuth,
    TerminalRecord
} from "../src/libraries/DealTypes.sol";
import {
    CoreDeploymentEvidenceOffchain,
    CoreDeploymentIntentOffchain,
    EVIDENCE_SCHEMA_ID,
    INTENT_SCHEMA_ID
} from "../src/libraries/ManifestTypes.sol";
import {ManifestHashing} from "../src/libraries/ManifestHashing.sol";
import {HashVectors} from "./vectors/HashVectors.sol";

contract HashVectorsTest is Test {
    function test_externalVectorsMatchFundingSpecAuthResolutionTerminalIntentAndEvidence()
        public
        pure
    {
        assertEq(DealHashing.FUNDING_SPEC_TYPEHASH, HashVectors.fundingSpecTypehash);
        assertEq(DealHashing.FUNDING_AUTH_TYPEHASH, HashVectors.fundingAuthTypehash);
        assertEq(DealHashing.RESOLUTION_TYPEHASH, HashVectors.resolutionTypehash);
        assertEq(DealHashing.TERMINAL_RECORD_TYPEHASH, HashVectors.terminalTypehash);
        assertEq(ManifestHashing.CORE_DEPLOYMENT_INTENT_V1_TYPEHASH, HashVectors.intentTypehash);
        assertEq(ManifestHashing.CORE_DEPLOYMENT_EVIDENCE_V1_TYPEHASH, HashVectors.evidenceTypehash);
        assertEq(INTENT_SCHEMA_ID, HashVectors.intentSchemaId);
        assertEq(EVIDENCE_SCHEMA_ID, HashVectors.evidenceSchemaId);

        FundingSpec memory fundingSpec = FundingSpec({
            purpose: 1,
            sourceMode: 1,
            token: address(5),
            amount: 100e18,
            source: address(1),
            sourcePositionId: bytes32(0),
            authority: address(1)
        });
        assertEq(DealHashing.hashFundingSpec(fundingSpec), HashVectors.fundingSpecHash);

        FundingAuth memory fundingAuth = FundingAuth({
            termsHash: bytes32(uint256(1)),
            fundingSpecHash: bytes32(uint256(2)),
            purpose: 1,
            authority: address(1),
            nonce: 1,
            expiry: 1_700_000_000
        });
        assertEq(DealHashing.hashFundingAuth(fundingAuth), HashVectors.fundingAuthHash);

        ResolutionAuth memory resolution = ResolutionAuth({
            dealId: bytes32(uint256(1)),
            action: 0,
            resolutionNonce: 1,
            expiry: 1_700_000_000,
            providerShareBps: 0,
            operatorFaultCode: 0,
            operatorFaultEvidenceHash: bytes32(0),
            reservationDispositionsHash: bytes32(0),
            extensionsHash: bytes32(0)
        });
        assertEq(DealHashing.hashResolution(resolution), HashVectors.resolutionHash);

        TerminalRecord memory terminal = TerminalRecord({
            chainId: 1,
            protocolVersion: 2,
            escrow: address(0xE5C1),
            ledger: address(0x1ED),
            dealId: bytes32(uint256(1)),
            terminalState: 16,
            outcome: 1,
            operatorFaultCode: 0,
            operatorFaultEvidenceHash: bytes32(0),
            token: address(0x70C),
            principal: 100e18,
            holderSideReturn: 0,
            providerGross: 100e18,
            providerNet: 97e18,
            completionCollected: 3e18,
            operatorFeePaid: 0,
            operatorFeeUnlocked: 0,
            holderReceiver: address(0x1111),
            providerReceiver: address(0x2222),
            completionFeeRecipient: address(0xFEE),
            operatorFeeRecipient: address(0),
            operatorFeeReturnReceiver: address(0),
            termsHash: bytes32(uint256(1)),
            modulesHash: bytes32(0),
            evidenceHash: bytes32(0),
            reservationsHash: bytes32(0),
            reservationDispositionsHash: bytes32(0),
            terminatedAt: 1_700_000_000
        });
        assertEq(DealHashing.hashTerminalRecord(terminal), HashVectors.terminalHash);

        CoreDeploymentIntentOffchain memory offchain = CoreDeploymentIntentOffchain({
            buildHash: bytes32(uint256(21)),
            plannedDeploymentMethodHash: bytes32(uint256(22)),
            coreDeployerCreationCodeHash: bytes32(uint256(23)),
            factoryCreationCodeHash: bytes32(uint256(24)),
            ledgerCreationCodeHash: bytes32(uint256(25)),
            coordinatorCreationCodeHash: bytes32(uint256(26)),
            escrowCreationCodeHash: bytes32(uint256(27)),
            capabilityHash: bytes32(uint256(31)),
            governanceHash: bytes32(uint256(32)),
            predecessorIntentHash: bytes32(0)
        });
        assertEq(
            ManifestHashing.hashDeploymentIntent(
                42_161,
                2,
                bytes32(uint256(11)),
                bytes32(uint256(12)),
                address(0xD01),
                address(0x1ED),
                address(0xC001),
                address(0xE5C1),
                offchain
            ),
            HashVectors.intentHash
        );

        CoreDeploymentEvidenceOffchain memory evidence = CoreDeploymentEvidenceOffchain({
            intentHash: HashVectors.intentHash,
            coreDeployerArtifactHash: bytes32(uint256(41)),
            factoryArtifactHash: bytes32(uint256(42)),
            ledgerArtifactHash: bytes32(uint256(43)),
            coordinatorArtifactHash: bytes32(uint256(44)),
            escrowArtifactHash: bytes32(uint256(45)),
            deploymentMethodHash: bytes32(uint256(46)),
            verificationHash: bytes32(uint256(47))
        });
        assertEq(ManifestHashing.hashDeploymentEvidence(evidence), HashVectors.evidenceHash);
    }

    function test_evidenceHash_requiresNonzeroIntentInPreimage() public pure {
        CoreDeploymentEvidenceOffchain memory evidence = CoreDeploymentEvidenceOffchain({
            intentHash: bytes32(0),
            coreDeployerArtifactHash: bytes32(uint256(41)),
            factoryArtifactHash: bytes32(uint256(42)),
            ledgerArtifactHash: bytes32(uint256(43)),
            coordinatorArtifactHash: bytes32(uint256(44)),
            escrowArtifactHash: bytes32(uint256(45)),
            deploymentMethodHash: bytes32(uint256(46)),
            verificationHash: bytes32(uint256(47))
        });
        assertTrue(ManifestHashing.hashDeploymentEvidence(evidence) != HashVectors.evidenceHash);
    }
}
