// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {CoreDeployer} from "../src/CoreDeployer.sol";
import {CoreManifestOffchain} from "../src/libraries/DealTypes.sol";

/// @notice CREATE2-deploys `CoreDeployer`, which creates Ledger + Coordinator + Escrow.
/// @dev Child addresses are deterministic from the factory address (CREATE nonces 1..3).
///      Factory address is deterministic from `SALT_CORE` via Foundry's CREATE2 factory.
contract DeployCore is Script {
    uint32 internal constant PROTOCOL_VERSION = 2;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address broadcaster = vm.addr(pk);
        bytes32 charterHash = vm.envBytes32("CHARTER_HASH");
        bytes32 techSpecHash = vm.envBytes32("TECH_SPEC_HASH");
        address owner = vm.envOr("COORDINATOR_OWNER", broadcaster);
        // ASCII "pluriswap.core.v2" left-aligned in bytes32 (matches deploy.toml.example).
        bytes32 salt = vm.envOr("SALT_CORE", bytes32("pluriswap.core.v2"));

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
            abi.encode(PROTOCOL_VERSION, charterHash, techSpecHash, owner, offchain)
        );
        bytes32 initCodeHash = keccak256(initCode);

        // Default Foundry CREATE2 deployer (Nick's factory) — same on every chain that has it.
        address factoryPredicted = vm.computeCreate2Address(salt, initCodeHash);
        address ledgerPredicted = vm.computeCreateAddress(factoryPredicted, 1);
        address coordinatorPredicted = vm.computeCreateAddress(factoryPredicted, 2);
        address escrowPredicted = vm.computeCreateAddress(factoryPredicted, 3);

        console2.log("CREATE2 salt", vm.toString(salt));
        console2.log("Predicted CoreDeployer", factoryPredicted);
        console2.log("Predicted CreditLedger", ledgerPredicted);
        console2.log("Predicted Coordinator", coordinatorPredicted);
        console2.log("Predicted CoreEscrow", escrowPredicted);

        vm.startBroadcast(pk);

        CoreDeployer deployed = new CoreDeployer{salt: salt}(
            PROTOCOL_VERSION, charterHash, techSpecHash, owner, offchain
        );

        vm.stopBroadcast();

        require(address(deployed) == factoryPredicted, "factory CREATE2 mismatch");
        require(address(deployed.ledger()) == ledgerPredicted, "ledger mismatch");
        require(address(deployed.coordinator()) == coordinatorPredicted, "coordinator mismatch");
        require(address(deployed.escrow()) == escrowPredicted, "escrow mismatch");

        console2.log("Deployed CoreDeployer", address(deployed));
        console2.log("Deployed CreditLedger", address(deployed.ledger()));
        console2.log("Deployed Coordinator", address(deployed.coordinator()));
        console2.log("Deployed CoreEscrow", address(deployed.escrow()));
    }
}
