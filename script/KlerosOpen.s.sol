// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Script.sol";
import {IArbitratorV2} from "../src/packages/interfaces/IKlerosV2.sol";
import {KlerosAdapter} from "../src/packages/KlerosAdapter.sol";
import {KlerosConfig} from "./KlerosConfig.s.sol";

/// @dev Isolated open against the live KlerosCore of the chain. Does not touch the packaged escrow: the
///      broadcaster plays kernel, so `caseOf` (and the Court UI template) will not resolve for this case.
///      Smoke test for "does this core accept our arbitrable?" — on Arbitrum One it answers the whitelist question.
contract KlerosOpen is KlerosConfig {
    bytes32 internal constant DEAL = keccak256("kleros-open-smoke");

    function run() external {
        uint256 holderPk = _holderKey();
        address holder = vm.addr(holderPk);
        Kleros memory k = _kleros();
        IArbitratorV2 core = IArbitratorV2(k.core);
        uint256 cost = core.arbitrationCost(k.extraData);
        require(cost > 0, "cost");
        require(holder.balance >= cost, "eth");

        vm.startBroadcast(holderPk);
        KlerosAdapter adapter =
            new KlerosAdapter(k.core, k.extraData, 0, "", holder, k.registry, k.policyUri, 0, address(0xFEE));
        _logWhitelist(k.core, address(adapter));
        adapter.openCourt{value: cost}(DEAL, holder);
        vm.stopBroadcast();

        uint256 disputeId = adapter.disputeOf(DEAL);
        require(adapter.opened(DEAL), "opened");
        require(adapter.readRuling(DEAL) == 0, "unruled");

        console.log("adapter", address(adapter));
        console.log("disputeId", disputeId);
        console.log("templateId", adapter.templateId());
        console.log("cost", cost);
        console.log("dealId", vm.toString(DEAL));

        string memory obj = "kleros";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "klerosCore", k.core);
        vm.serializeAddress(obj, "templateRegistry", k.registry);
        vm.serializeUint(obj, "templateId", adapter.templateId());
        vm.serializeAddress(obj, "adapter", address(adapter));
        vm.serializeUint(obj, "disputeId", disputeId);
        vm.serializeUint(obj, "cost", cost);
        string memory json = vm.serializeBytes32(obj, "dealId", DEAL);
        vm.writeJson(json, _out());
        console.log("wrote", _out());
    }

    function _out() internal view returns (string memory) {
        if (block.chainid == ARBITRUM_SEPOLIA) return "deployments/sepolia-kleros.json";
        return string.concat("deployments/", vm.toString(block.chainid), "-kleros.json");
    }

    function _holderKey() internal view returns (uint256 pk) {
        if (block.chainid == ANVIL) {
            return 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        }
        pk = vm.envUint("HOLDER_PRIVATE_KEY");
    }
}
