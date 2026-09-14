// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Script.sol";
import {ChainIds} from "./ChainIds.s.sol";

/// @dev Kleros V2 wiring per chain. Every value has an env override; unknown chains must set them all.
///
///      | env                       | default                                   |
///      | ------------------------- | ----------------------------------------- |
///      | `KLEROS_CORE`             | KlerosCore proxy of the chain             |
///      | `KLEROS_TEMPLATE_REGISTRY`| DisputeTemplateRegistry proxy of the chain|
///      | `KLEROS_COURT`            | 1 (General Court)                         |
///      | `KLEROS_JURORS`           | 3                                         |
///      | `KLEROS_DISPUTE_KIT`      | 1 (Classic)                               |
///      | `KLEROS_POLICY_URI`       | placeholder; **required** on Arbitrum One |
///
///      Addresses from kleros/kleros-v2 `contracts/README.md` (proxies, upgradeable by Kleros governance).
abstract contract KlerosConfig is ChainIds {
    address internal constant KLEROS_CORE_ARBITRUM = 0x991d2df165670b9cac3B022f4B68D65b664222ea;
    address internal constant TEMPLATE_REGISTRY_ARBITRUM = 0x0cFBaCA5C72e7Ca5fFABE768E135654fB3F2a5A2;
    address internal constant KLEROS_CORE_SEPOLIA = 0xE8442307d36e9bf6aB27F1A009F95CE8E11C3479;
    address internal constant TEMPLATE_REGISTRY_SEPOLIA = 0xe763d31Cb096B4bc7294012B78FC7F148324ebcb;

    /// @dev Valid multiaddr so the Court UI still renders on testnets. Pin docs/KLEROS_POLICY.md and override.
    string internal constant POLICY_PLACEHOLDER = "/ipfs/PLACEHOLDER-pin-KLEROS_POLICY.md-and-set-KLEROS_POLICY_URI";

    struct Kleros {
        address core;
        address registry;
        bytes extraData;
        string policyUri;
    }

    function _kleros() internal view returns (Kleros memory k) {
        (address core, address registry) = _defaults();
        k.core = vm.envOr("KLEROS_CORE", core);
        k.registry = vm.envOr("KLEROS_TEMPLATE_REGISTRY", registry);
        require(k.core != address(0), "KLEROS_CORE unset for this chain");
        require(k.registry != address(0), "KLEROS_TEMPLATE_REGISTRY unset for this chain");
        require(k.core.code.length > 0, "KLEROS_CORE has no code");
        require(k.registry.code.length > 0, "KLEROS_TEMPLATE_REGISTRY has no code");
        k.extraData = abi.encode(
            vm.envOr("KLEROS_COURT", uint256(1)),
            vm.envOr("KLEROS_JURORS", uint256(3)),
            vm.envOr("KLEROS_DISPUTE_KIT", uint256(1))
        );
        k.policyUri = vm.envOr("KLEROS_POLICY_URI", POLICY_PLACEHOLDER);
        if (block.chainid == ARBITRUM_ONE) {
            require(
                keccak256(bytes(k.policyUri)) != keccak256(bytes(POLICY_PLACEHOLDER)),
                "KLEROS_POLICY_URI required on Arbitrum One"
            );
        }
    }

    /// @dev `known` is false when the core has no `arbitrableWhitelist(address)` (no whitelist in that build).
    function _whitelisted(address core, address arbitrable) internal view returns (bool known, bool allowed) {
        (bool ok, bytes memory ret) =
            core.staticcall(abi.encodeWithSignature("arbitrableWhitelist(address)", arbitrable));
        if (!ok || ret.length != 32) return (false, false);
        return (true, abi.decode(ret, (bool)));
    }

    function _logWhitelist(address core, address arbitrable) internal view {
        (bool known, bool allowed) = _whitelisted(core, arbitrable);
        if (!known) {
            console.log("kleros whitelist: core exposes none");
        } else if (allowed) {
            console.log("kleros whitelist: adapter allowed");
        } else {
            console.log("kleros whitelist: adapter NOT listed. openCourt reverts ArbitrableNotWhitelisted()");
            console.log("  ask Kleros governance to changeArbitrableWhitelist(adapter, true)");
        }
    }

    function _defaults() private view returns (address core, address registry) {
        if (block.chainid == ARBITRUM_ONE) return (KLEROS_CORE_ARBITRUM, TEMPLATE_REGISTRY_ARBITRUM);
        if (block.chainid == ARBITRUM_SEPOLIA) return (KLEROS_CORE_SEPOLIA, TEMPLATE_REGISTRY_SEPOLIA);
        return (address(0), address(0));
    }
}
