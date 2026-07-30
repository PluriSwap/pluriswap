// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {CoreEscrow} from "../src/CoreEscrow.sol";
import {CreditLedger} from "../src/CreditLedger.sol";
import {Coordinator} from "../src/Coordinator.sol";

/// @notice Deploys Ledger + Coordinator + Escrow with nonce-predicted Escrow address.
contract DeployCore is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        bytes32 charterHash = vm.envOr("CHARTER_HASH", keccak256("charter"));
        bytes32 techSpecHash = vm.envOr("TECH_SPEC_HASH", keccak256("tech"));
        address owner = vm.envOr("COORDINATOR_OWNER", deployer);

        vm.startBroadcast(pk);

        uint64 chainId_ = uint64(block.chainid);
        uint64 nonce = uint64(vm.getNonce(deployer));
        address escrowPredicted = vm.computeCreateAddress(deployer, nonce + 2);

        CreditLedger ledger = new CreditLedger(escrowPredicted, chainId_);
        Coordinator coordinator = new Coordinator(chainId_, escrowPredicted, owner);
        CoreEscrow escrow = new CoreEscrow(
            chainId_, 2, charterHash, techSpecHash, address(ledger), address(coordinator)
        );
        require(address(escrow) == escrowPredicted, "escrow prediction mismatch");

        vm.stopBroadcast();

        console2.log("CreditLedger", address(ledger));
        console2.log("Coordinator", address(coordinator));
        console2.log("CoreEscrow", address(escrow));
    }
}
