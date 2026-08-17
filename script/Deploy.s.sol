// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Escrow} from "../src/Escrow.sol";
import {TestToken} from "../src/TestToken.sol";

contract Deploy is Script {
    uint256 internal constant ARBITRUM_SEPOLIA = 421614;

    function run() external {
        vm.startBroadcast();
        TestToken token = new TestToken();
        Escrow escrow = new Escrow(address(0), address(0), address(0), address(0), address(0));
        vm.stopBroadcast();

        console.log("chainId", block.chainid);
        console.log("TestToken", address(token));
        console.log("Escrow", address(escrow));

        string memory obj = "deploy";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "testToken", address(token));
        string memory json = vm.serializeAddress(obj, "escrow", address(escrow));
        string memory path = _path();
        vm.writeJson(json, path);
        console.log("wrote", path);
    }

    function _path() internal view returns (string memory) {
        if (block.chainid == ARBITRUM_SEPOLIA) return "deployments/sepolia.json";
        return string.concat("deployments/", vm.toString(block.chainid), ".json");
    }
}
