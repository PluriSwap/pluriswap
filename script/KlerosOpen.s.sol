// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IArbitratorV2} from "../src/packages/interfaces/IKlerosV2.sol";
import {KlerosAdapter} from "../src/packages/KlerosAdapter.sol";

/// @dev Isolated open against live KlerosCore. Does not touch the packaged escrow.
contract KlerosOpen is Script {
    uint256 internal constant ARBITRUM_SEPOLIA = 421614;
    address internal constant KLEROS_CORE = 0xE8442307d36e9bf6aB27F1A009F95CE8E11C3479;
    bytes32 internal constant DEAL = keccak256("sepolia-kleros-open");

    function run() external {
        uint256 holderPk = _holderKey();
        address holder = vm.addr(holderPk);
        bytes memory extraData = abi.encode(uint256(1), uint256(3), uint256(1));
        IArbitratorV2 core = IArbitratorV2(KLEROS_CORE);
        uint256 cost = core.arbitrationCost(extraData);
        require(cost > 0, "cost");
        require(holder.balance >= cost, "eth");

        vm.startBroadcast(holderPk);
        KlerosAdapter adapter = new KlerosAdapter(KLEROS_CORE, extraData, 0, "", address(0), address(0));
        adapter.openCourt{value: cost}(DEAL, holder);
        vm.stopBroadcast();

        uint256 disputeId = adapter.disputeOf(DEAL);
        require(adapter.opened(DEAL), "opened");
        require(adapter.readRuling(DEAL) == 0, "unruled");

        console.log("adapter", address(adapter));
        console.log("disputeId", disputeId);
        console.log("cost", cost);
        console.log("dealId", vm.toString(DEAL));

        string memory obj = "kleros";
        vm.serializeUint(obj, "chainId", ARBITRUM_SEPOLIA);
        vm.serializeAddress(obj, "klerosCore", KLEROS_CORE);
        vm.serializeAddress(obj, "adapter", address(adapter));
        vm.serializeUint(obj, "disputeId", disputeId);
        vm.serializeUint(obj, "cost", cost);
        string memory json = vm.serializeBytes32(obj, "dealId", DEAL);
        vm.writeJson(json, "deployments/sepolia-kleros.json");
        console.log("wrote deployments/sepolia-kleros.json");
    }

    function _holderKey() internal view returns (uint256 pk) {
        if (block.chainid == 31337) {
            return 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        }
        pk = vm.envUint("HOLDER_PRIVATE_KEY");
    }
}
