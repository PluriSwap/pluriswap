// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {CoreDeployer} from "../src/CoreDeployer.sol";
import {CoreEscrow} from "../src/CoreEscrow.sol";
import {CreditLedger} from "../src/CreditLedger.sol";
import {Coordinator} from "../src/Coordinator.sol";
import {CoreManifestOffchain} from "../src/libraries/DealTypes.sol";

/// @notice CREATE2-deploys `CoreDeployer`, then atomically creates the Core triad.
/// @dev Child addresses are deterministic from CoreDeployer (CREATE nonces 1..3).
///      Factory address is deterministic from `SALT_CORE` via Foundry's CREATE2 factory.
contract DeployCore is Script {
    uint32 internal constant PROTOCOL_VERSION = 2;
    uint8 internal constant DEPLOYMENT_METHOD = 2;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        bytes32 charterHash = vm.envBytes32("CHARTER_HASH");
        bytes32 techSpecHash = vm.envBytes32("TECH_SPEC_HASH");
        address owner = vm.envAddress("COORDINATOR_OWNER");
        address deploymentOperator = vm.envAddress("DEPLOYMENT_OPERATOR");
        // ASCII "pluriswap.core.v2" left-aligned in bytes32 (matches deploy.toml.example).
        bytes32 salt = vm.envBytes32("SALT_CORE");

        CoreManifestOffchain memory offchain = CoreManifestOffchain({
            buildHash: vm.envBytes32("BUILD_HASH"),
            deploymentMethodHash: vm.envBytes32("DEPLOYMENT_METHOD_HASH"),
            coreDeployerArtifactHash: vm.envBytes32("DEPLOYER_ARTIFACT_HASH"),
            factoryArtifactHash: vm.envBytes32("FACTORY_ARTIFACT_HASH"),
            ledgerArtifactHash: vm.envBytes32("LEDGER_ARTIFACT_HASH"),
            coordinatorArtifactHash: vm.envBytes32("COORDINATOR_ARTIFACT_HASH"),
            escrowArtifactHash: vm.envBytes32("ESCROW_ARTIFACT_HASH"),
            capabilityHash: vm.envBytes32("CAPABILITY_HASH"),
            governanceHash: vm.envBytes32("GOVERNANCE_HASH"),
            verificationHash: vm.envBytes32("VERIFICATION_HASH"),
            predecessorManifestHash: bytes32(0)
        });

        bytes memory initCode = abi.encodePacked(
            type(CoreDeployer).creationCode,
            abi.encode(
                DEPLOYMENT_METHOD,
                PROTOCOL_VERSION,
                charterHash,
                techSpecHash,
                owner,
                deploymentOperator,
                offchain
            )
        );
        bytes32 initCodeHash = keccak256(initCode);

        // Default Foundry CREATE2 deployer (Nick's factory) — same on every chain that has it.
        address coreDeployerPredicted = vm.computeCreate2Address(salt, initCodeHash);
        address ledgerPredicted = vm.computeCreateAddress(coreDeployerPredicted, 1);
        address coordinatorPredicted = vm.computeCreateAddress(coreDeployerPredicted, 2);
        address escrowPredicted = vm.computeCreateAddress(coreDeployerPredicted, 3);

        console2.log("CREATE2 salt", vm.toString(salt));
        console2.log("Predicted CoreDeployer", coreDeployerPredicted);
        console2.log("Predicted CreditLedger", ledgerPredicted);
        console2.log("Predicted Coordinator", coordinatorPredicted);
        console2.log("Predicted CoreEscrow", escrowPredicted);

        vm.startBroadcast(pk);

        CoreDeployer deployed = new CoreDeployer{salt: salt}(
            DEPLOYMENT_METHOD,
            PROTOCOL_VERSION,
            charterHash,
            techSpecHash,
            owner,
            deploymentOperator,
            offchain
        );

        bytes memory ledgerInitCode = abi.encodePacked(
            type(CreditLedger).creationCode,
            abi.encode(address(deployed.escrow()), deployed.chainId())
        );
        bytes memory coordinatorInitCode = abi.encodePacked(
            type(Coordinator).creationCode,
            abi.encode(deployed.chainId(), address(deployed.escrow()), owner)
        );
        bytes memory escrowInitCode = abi.encodePacked(
            type(CoreEscrow).creationCode,
            abi.encode(
                deployed.chainId(),
                deployed.protocolVersion(),
                deployed.charterHash(),
                deployed.techSpecHash(),
                address(deployed.ledger()),
                address(deployed.coordinator()),
                deployed.manifestHash()
            )
        );
        deployed.deployTriad(ledgerInitCode, coordinatorInitCode, escrowInitCode);

        vm.stopBroadcast();

        require(address(deployed) == coreDeployerPredicted, "factory CREATE2 mismatch");
        require(address(deployed.ledger()) == ledgerPredicted, "ledger mismatch");
        require(address(deployed.coordinator()) == coordinatorPredicted, "coordinator mismatch");
        require(address(deployed.escrow()) == escrowPredicted, "escrow mismatch");
        require(deployed.triadDeployed(), "triad not finalized");
        require(address(deployed.ledger()).code.length > 0, "ledger has no code");
        require(address(deployed.coordinator()).code.length > 0, "coordinator has no code");
        require(address(deployed.escrow()).code.length > 0, "escrow has no code");
        require(
            deployed.ledger().escrow() == address(deployed.escrow()), "ledger reverse link mismatch"
        );
        require(
            deployed.coordinator().escrow() == address(deployed.escrow()),
            "coordinator reverse link mismatch"
        );
        require(
            address(deployed.escrow().ledger()) == address(deployed.ledger()),
            "escrow ledger link mismatch"
        );
        require(
            address(deployed.escrow().coordinator()) == address(deployed.coordinator()),
            "escrow coordinator link mismatch"
        );
        require(deployed.escrow().manifestHash() == deployed.manifestHash(), "manifest mismatch");

        console2.log("Deployed CoreDeployer", address(deployed));
        console2.log("Deployed CreditLedger", address(deployed.ledger()));
        console2.log("Deployed Coordinator", address(deployed.coordinator()));
        console2.log("Deployed CoreEscrow", address(deployed.escrow()));
        console2.log("Ledger initcode hash", vm.toString(keccak256(ledgerInitCode)));
        console2.log("Coordinator initcode hash", vm.toString(keccak256(coordinatorInitCode)));
        console2.log("Escrow initcode hash", vm.toString(keccak256(escrowInitCode)));
    }
}
