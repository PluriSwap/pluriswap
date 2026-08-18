// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {PoolFactory} from "../src/pools/PoolFactory.sol";

contract DeployPoolFactory is Script {
    uint256 internal constant ARBITRUM_SEPOLIA = 421614;

    function run() external {
        uint256 pk = _key();
        vm.startBroadcast(pk);
        PoolFactory factory = new PoolFactory();
        vm.stopBroadcast();

        console.log("chainId", block.chainid);
        console.log("factory", address(factory));
        console.log("implementation", factory.implementation());
        console.log("officialCodehash");
        console.logBytes32(factory.officialCodehash());

        string memory obj = "poolFactory";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "factory", address(factory));
        vm.serializeAddress(obj, "implementation", factory.implementation());
        string memory json = vm.serializeBytes32(obj, "officialCodehash", factory.officialCodehash());
        vm.writeJson(json, _path());
        console.log("wrote", _path());
    }

    function _path() internal view returns (string memory) {
        if (block.chainid == ARBITRUM_SEPOLIA) return "deployments/sepolia-pool-factory.json";
        return string.concat("deployments/", vm.toString(block.chainid), "-pool-factory.json");
    }

    function _key() internal view returns (uint256 pk) {
        if (block.chainid == 31337) {
            return 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        }
        pk = vm.envUint("HOLDER_PRIVATE_KEY");
    }
}
