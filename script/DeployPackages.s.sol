// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Escrow} from "../src/Escrow.sol";
import {TestToken} from "../src/TestToken.sol";
import {PassportMock} from "../src/packages/PassportMock.sol";
import {Reputation} from "../src/packages/Reputation.sol";
import {BondVault} from "../src/packages/BondVault.sol";
import {ZkMock} from "../src/packages/ZkMock.sol";
import {VerifierMock} from "../src/mocks/VerifierMock.sol";
import {ArbitrationMock} from "../src/packages/ArbitrationMock.sol";

/// @dev New Sepolia escrow with the full verb list. Does not overwrite deployments/sepolia.json.
contract DeployPackages is Script {
    using stdJson for string;

    uint256 internal constant ARBITRUM_SEPOLIA = 421614;
    uint256 internal constant ACT_FEE = 100_000;
    uint256 internal constant COMP_FEE = 50_000;
    uint256 internal constant ZK_FEE = 10_000;
    uint256 internal constant COURT_FEE = 1_000_000;
    address internal constant FEE_RECIPIENT = address(0xFEE);
    address internal constant SINK = address(0xdeaD);
    address internal constant TRIBUNAL = address(0x71B);

    function run() external {
        uint256 pk = _key();
        address deployer = vm.addr(pk);
        TestToken token = _token();

        uint64 n = vm.getNonce(deployer);
        address predicted = vm.computeCreateAddress(deployer, n + 6);

        vm.startBroadcast(pk);
        PassportMock passport = new PassportMock();
        Reputation reputation = new Reputation(passport, FEE_RECIPIENT, ACT_FEE, COMP_FEE);
        VerifierMock verifier = new VerifierMock();
        ZkMock zk = new ZkMock(verifier, FEE_RECIPIENT, ZK_FEE);
        BondVault vault = new BondVault(predicted, SINK, passport);
        ArbitrationMock arb = new ArbitrationMock(TRIBUNAL, address(token), COURT_FEE, 1 days, predicted);
        Escrow escrow = new Escrow(address(passport), address(reputation), address(vault), address(zk), address(arb));
        vm.stopBroadcast();

        require(address(escrow) == predicted, "escrow prediction");
        require(vault.operator() == address(escrow), "vault operator");
        require(arb.operator() == address(escrow), "arb operator");

        console.log("chainId", block.chainid);
        console.log("TestToken", address(token));
        console.log("Passport", address(passport));
        console.log("Reputation", address(reputation));
        console.log("BondVault", address(vault));
        console.log("ZkMock", address(zk));
        console.log("ArbitrationMock", address(arb));
        console.log("Escrow", address(escrow));

        string memory obj = "packages";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "testToken", address(token));
        vm.serializeAddress(obj, "passport", address(passport));
        vm.serializeAddress(obj, "reputation", address(reputation));
        vm.serializeAddress(obj, "bondVault", address(vault));
        vm.serializeAddress(obj, "verifier", address(verifier));
        vm.serializeAddress(obj, "zk", address(zk));
        vm.serializeAddress(obj, "arbitration", address(arb));
        vm.serializeAddress(obj, "feeRecipient", FEE_RECIPIENT);
        vm.serializeAddress(obj, "sink", SINK);
        vm.serializeBytes32(obj, "passportId", escrow.passportId());
        vm.serializeBytes32(obj, "reputationId", escrow.reputationId());
        vm.serializeBytes32(obj, "bondsId", escrow.bondsId());
        vm.serializeBytes32(obj, "zkId", escrow.zkId());
        vm.serializeBytes32(obj, "arbId", escrow.arbId());
        string memory json = vm.serializeAddress(obj, "escrow", address(escrow));
        vm.writeJson(json, _out());
        console.log("wrote", _out());
    }

    function _token() internal view returns (TestToken token) {
        address override_ = vm.envOr("TOKEN", address(0));
        if (override_ != address(0)) return TestToken(override_);
        string memory core = block.chainid == ARBITRUM_SEPOLIA
            ? "deployments/sepolia.json"
            : string.concat("deployments/", vm.toString(block.chainid), ".json");
        require(vm.exists(core), core);
        token = TestToken(vm.readFile(core).readAddress(".testToken"));
        require(address(token).code.length > 0, "token");
    }

    function _out() internal view returns (string memory) {
        if (block.chainid == ARBITRUM_SEPOLIA) return "deployments/sepolia-packages.json";
        return string.concat("deployments/", vm.toString(block.chainid), "-packages.json");
    }

    function _key() internal view returns (uint256 pk) {
        if (block.chainid == 31337) {
            return 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        }
        pk = vm.envUint("HOLDER_PRIVATE_KEY");
    }
}
