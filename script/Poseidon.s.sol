// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Poseidon} from "../src/packages/libraries/Poseidon.sol";

/// @title EnsurePoseidon
/// @notice Puts the pinned poseidon-solidity singletons on a chain that does not have them yet
///         (PLURISWAP.md §5.1). Idempotent: a singleton that already has code is left alone.
/// @dev The private layer hashes through fixed addresses, never through a library linked into this
///      tree — our own build of `PoseidonT3` is 29,315 B, past EIP-170. Those addresses are the
///      CREATE2 of upstream's pre-signed initcode through Arachnid's deterministic-deployment-proxy,
///      so ensuring them is exactly: send `salt || initcode` to the proxy and check where it landed.
///
///      On Arbitrum One and Arbitrum Sepolia `PoseidonT3` is already live; `PoseidonT2` is not, so
///      this runs once per chain before anything in the private layer is deployed. Deploying the
///      proxy itself is deliberately NOT this script's job: it is a keyless Nick's-method deployment
///      with its own pre-signed transaction, so a missing proxy fails loudly here rather than being
///      papered over with a different factory — which would mean different addresses.
///
///      Inherit it (`is EnsurePoseidon`) from the private-layer deploy scripts, or run it alone:
///      `forge script script/Poseidon.s.sol:EnsurePoseidon --rpc-url $RPC --broadcast`
contract EnsurePoseidon is Script {
    using stdJson for string;

    string internal constant FIXTURE = "test/fixtures/poseidon.json";

    error DeterministicProxyMissing(address proxy);
    error SingletonDeployFailed(string name);
    error SingletonWrongAddress(string name, address expected, address got);

    function run() external {
        vm.startBroadcast(_key());
        ensurePoseidon();
        vm.stopBroadcast();
    }

    /// @notice Deploys whichever singletons are absent. Must run inside a broadcast.
    function ensurePoseidon() internal {
        string memory json = vm.readFile(FIXTURE);
        address proxy = json.readAddress(".deployer");
        if (proxy.code.length == 0) revert DeterministicProxyMissing(proxy);
        _ensure(json, proxy, "PoseidonT2");
        _ensure(json, proxy, "PoseidonT3");
    }

    function _ensure(string memory json, address proxy, string memory name) private {
        string memory key = string.concat(".singletons.", name);
        address expected = json.readAddress(string.concat(key, ".address"));
        if (expected.code.length != 0) {
            console.log("poseidon: %s already live at %s", name, expected);
            return;
        }
        bytes32 salt = json.readBytes32(string.concat(key, ".salt"));
        bytes memory initcode = json.readBytes(string.concat(key, ".initcode"));
        (bool ok, bytes memory ret) = proxy.call(bytes.concat(salt, initcode));
        if (!ok || ret.length != 20) revert SingletonDeployFailed(name);
        address got = address(uint160(bytes20(ret)));
        if (got != expected) revert SingletonWrongAddress(name, expected, got);
        console.log("poseidon: deployed %s at %s", name, got);
    }

    function _key() internal view returns (uint256) {
        return vm.envUint("PRIVATE_KEY");
    }
}
