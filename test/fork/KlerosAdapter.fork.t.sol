// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {KlerosAdapter} from "../../src/packages/KlerosAdapter.sol";
import {IArbitratorV2} from "../../src/packages/interfaces/IKlerosV2.sol";

/// @dev Shared shape for the two live Kleros V2 deployments PluriSwap targets. Each subclass forks one chain
///      (skipped without its RPC env), deploys the adapter against the real KlerosCore + DisputeTemplateRegistry
///      with a throwaway kernel, and checks what the deploy script relies on.
abstract contract KlerosForkBase is Test {
    string internal constant POLICY = "/ipfs/QmPolicyCidForForkTests/KLEROS_POLICY.md";
    bytes32 internal constant DEAL = keccak256("kleros-fork");
    bytes internal constant EXTRA = abi.encode(uint256(1), uint256(3), uint256(1)); // General Court, 3 jurors, Classic

    address internal kernel = address(uint160(uint256(keccak256("pluriswap.kernel.fork"))));
    IArbitratorV2 internal core;
    address internal registry;
    KlerosAdapter internal adapter;
    bool internal forked;

    function _fork(string memory envName, address core_, address registry_) internal {
        string memory rpc = vm.envOr(envName, string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        core = IArbitratorV2(core_);
        registry = registry_;
        adapter = new KlerosAdapter(core_, EXTRA, 0, "", kernel, registry_, POLICY);
        vm.deal(kernel, 1 ether);
    }

    modifier onFork() {
        vm.skip(!forked);
        _;
    }

    function test_fork_coreAndRegistryAreLive() public onFork {
        assertGt(address(core).code.length, 0, "core has no code");
        assertGt(registry.code.length, 0, "registry has no code");
        assertGt(core.arbitrationCost(EXTRA), 0, "General Court quotes zero");
    }

    function test_fork_templateRegisteredForThisChain() public onFork {
        assertGt(adapter.templateId(), 0, "registry returned template 0");
        string memory json = adapter.templateData();
        assertEq(vm.parseJsonString(json, ".arbitratorChainID"), vm.toString(block.chainid));
        assertEq(vm.parseJsonAddress(json, ".arbitratorAddress"), address(core));
        assertEq(vm.parseJsonString(json, ".policyURI"), POLICY);
    }
}

/// @dev Arbitrum One. KlerosCore there enforces an arbitrable whitelist: a fresh adapter cannot open until Kleros
///      governance lists it. This test pins that fact so a mainnet deploy is never assumed to work unlisted.
contract KlerosAdapterArbitrumForkTest is KlerosForkBase {
    function setUp() public {
        _fork(
            "ARBITRUM_RPC_URL", 0x991d2df165670b9cac3B022f4B68D65b664222ea, 0x0cFBaCA5C72e7Ca5fFABE768E135654fB3F2a5A2
        );
    }

    function test_fork_unlistedAdapterCannotOpen() public onFork {
        (bool ok, bytes memory ret) =
            address(core).staticcall(abi.encodeWithSignature("arbitrableWhitelist(address)", address(adapter)));
        assertTrue(ok && ret.length == 32, "core exposes no arbitrableWhitelist");
        assertFalse(abi.decode(ret, (bool)), "fresh adapter unexpectedly whitelisted");

        uint256 cost = core.arbitrationCost(EXTRA);
        vm.prank(kernel);
        vm.expectRevert(bytes4(keccak256("ArbitrableNotWhitelisted()")));
        adapter.openCourt{value: cost}(DEAL, kernel);
        assertFalse(adapter.opened(DEAL)); // revert undid the CEI write
    }
}

/// @dev Arbitrum Sepolia (Kleros testnet). No whitelist: the whole open path runs against the real core.
contract KlerosAdapterSepoliaForkTest is KlerosForkBase {
    function setUp() public {
        _fork(
            "ARBITRUM_SEPOLIA_RPC_URL",
            0xE8442307d36e9bf6aB27F1A009F95CE8E11C3479,
            0xe763d31Cb096B4bc7294012B78FC7F148324ebcb
        );
    }

    function test_fork_kernelOpensRealDispute() public onFork {
        uint256 cost = core.arbitrationCost(EXTRA);
        vm.prank(kernel);
        adapter.openCourt{value: cost}(DEAL, kernel);
        assertTrue(adapter.opened(DEAL));
        uint256 disputeId = adapter.disputeOf(DEAL);
        assertTrue(adapter.known(disputeId));
        assertEq(adapter.dealOf(disputeId), DEAL);
        assertEq(adapter.readRuling(DEAL), 0, "no ruling before jurors vote");
    }

    function test_fork_onlyCoreRules() public onFork {
        uint256 cost = core.arbitrationCost(EXTRA);
        vm.prank(kernel);
        adapter.openCourt{value: cost}(DEAL, kernel);
        uint256 disputeId = adapter.disputeOf(DEAL);
        vm.expectRevert(KlerosAdapter.Unauthorized.selector);
        adapter.rule(disputeId, 1);
    }
}
