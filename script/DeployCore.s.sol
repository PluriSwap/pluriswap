// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {CoreDeployer} from "../src/CoreDeployer.sol";

/// @notice CREATE2-deploys `CoreDeployer`, which creates Ledger + Coordinator + Escrow.
/// @dev Child addresses are deterministic from the factory address (CREATE nonces 1..3).
///      Factory address is deterministic from `SALT_CORE` via Foundry's CREATE2 factory.
contract DeployCore is Script {
    uint32 internal constant PROTOCOL_VERSION = 2;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address broadcaster = vm.addr(pk);
        bytes32 charterHash = vm.envOr("CHARTER_HASH", keccak256("charter"));
        bytes32 techSpecHash = vm.envOr("TECH_SPEC_HASH", keccak256("tech"));
        address owner = vm.envOr("COORDINATOR_OWNER", broadcaster);
        // ASCII "pluriswap.core.v2" left-aligned in bytes32 (matches deploy.toml.example).
        bytes32 salt = vm.envOr("SALT_CORE", bytes32("pluriswap.core.v2"));

        bytes memory initCode = abi.encodePacked(
            type(CoreDeployer).creationCode,
            abi.encode(PROTOCOL_VERSION, charterHash, techSpecHash, owner)
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
            PROTOCOL_VERSION, charterHash, techSpecHash, owner
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
