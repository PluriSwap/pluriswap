// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Escrow} from "../src/Escrow.sol";
import {TestToken} from "../mocks/TestToken.sol";
import {IPassport} from "../src/packages/interfaces/IPassport.sol";
import {PassportPicker} from "./PassportPicker.s.sol";
import {KlerosConfig} from "./KlerosConfig.s.sol";
import {Reputation} from "../src/packages/Reputation.sol";
import {BondVault} from "../src/packages/BondVault.sol";
import {ZkMock} from "../mocks/ZkMock.sol";
import {VerifierMock} from "../mocks/VerifierMock.sol";
import {KlerosAdapter} from "../src/packages/KlerosAdapter.sol";

/// @dev Packaged escrow whose only court is Kleros V2. Does not overwrite sepolia-packages.json.
///      Kleros wiring comes from `KlerosConfig` (chain defaults + `KLEROS_*` env). On Arbitrum One the adapter
///      still needs Kleros governance to whitelist it before `openCourt` works; the script logs the status.
///      Test chains only for now: the ZK slot is still `VerifierMock`/`ZkMock`, whose `verify` accepts any
///      64 bytes, so publishing that `zkId` on a value-bearing chain would make every ZK deal drainable.
///      Replace the two mock CREATEs with a real verifier picker before relaxing `_requireMockChain`.
contract DeployKlerosPackages is PassportPicker, KlerosConfig {
    using stdJson for string;

    uint256 internal constant ACT_FEE = 100_000;
    uint256 internal constant COMP_FEE = 50_000;
    uint256 internal constant CONTEST_BPS = 100;
    /// @dev PLURISWAP.md §3.14.6: the official floor is low and global (~2 USDC). The old 10 USDC floor was
    ///      regressive against the T1 cap (250); a per-tier/per-deal floor is not implementable without a
    ///      kernel bump (`contestFloor` is a stateless getter that lives inside the packageId).
    uint256 internal constant CONTEST_FLOOR = 2_000_000;
    uint256 internal constant ZK_FEE = 10_000;
    address internal constant FEE_RECIPIENT = address(0xFEE);
    address internal constant SINK = address(0xdeaD);

    function run() external {
        _requireMockChain("DeployKlerosPackages");
        uint256 pk = _key();
        address deployer = vm.addr(pk);
        TestToken token = _token();
        Kleros memory k = _kleros();

        uint64 n = vm.getNonce(deployer);
        address predicted = vm.computeCreateAddress(deployer, n + 6);

        vm.startBroadcast(pk);
        (IPassport passport, address decoder) = _deployPassport();
        Reputation reputation =
            new Reputation(passport, FEE_RECIPIENT, ACT_FEE, COMP_FEE, CONTEST_BPS, CONTEST_FLOOR, predicted);
        VerifierMock verifier = new VerifierMock();
        ZkMock zk = new ZkMock(verifier, FEE_RECIPIENT, ZK_FEE, predicted);
        BondVault vault = new BondVault(predicted, SINK, passport);
        KlerosAdapter court =
            new KlerosAdapter(k.core, k.extraData, 0, "", predicted, k.registry, k.policyUri, 0, address(0xFEE));
        Escrow escrow = new Escrow();
        vm.stopBroadcast();

        require(address(escrow) == predicted, "escrow prediction");
        require(reputation.operator() == address(escrow), "rep operator");
        require(zk.operator() == address(escrow), "zk operator");
        require(vault.operator() == address(escrow), "vault operator");
        require(court.kernel() == address(escrow), "court kernel");
        require(court.templateId() != 0, "template");

        console.log("Escrow", address(escrow));
        console.log("KlerosAdapter", address(court));
        console.log("templateId", court.templateId());
        console.log("arbId", vm.toString(court.packageId()));
        console.log("policyUri", k.policyUri);
        _logWhitelist(k.core, address(court));
        (, bool whitelisted) = _whitelisted(k.core, address(court));

        string memory obj = "kleros";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "testToken", address(token));
        vm.serializeAddress(obj, "passport", address(passport));
        vm.serializeAddress(obj, "passportDecoder", decoder);
        vm.serializeAddress(obj, "reputation", address(reputation));
        vm.serializeAddress(obj, "bondVault", address(vault));
        vm.serializeAddress(obj, "verifier", address(verifier));
        vm.serializeAddress(obj, "zk", address(zk));
        vm.serializeAddress(obj, "klerosCore", k.core);
        vm.serializeAddress(obj, "templateRegistry", k.registry);
        vm.serializeBytes(obj, "klerosExtraData", k.extraData);
        vm.serializeString(obj, "klerosPolicyUri", k.policyUri);
        vm.serializeBool(obj, "klerosWhitelisted", whitelisted);
        vm.serializeUint(obj, "templateId", court.templateId());
        vm.serializeAddress(obj, "arbitration", address(court));
        vm.serializeAddress(obj, "feeRecipient", FEE_RECIPIENT);
        vm.serializeAddress(obj, "sink", SINK);
        vm.serializeBytes32(obj, "passportId", passport.packageId());
        vm.serializeBytes32(obj, "reputationId", reputation.packageId());
        vm.serializeBytes32(obj, "bondsId", vault.packageId());
        vm.serializeBytes32(obj, "zkId", zk.packageId());
        vm.serializeBytes32(obj, "arbId", court.packageId());
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
        if (block.chainid == ARBITRUM_SEPOLIA) return "deployments/sepolia-kleros-packages.json";
        return string.concat("deployments/", vm.toString(block.chainid), "-kleros-packages.json");
    }

    function _key() internal view returns (uint256 pk) {
        if (block.chainid == 31337) {
            return 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        }
        pk = vm.envUint("HOLDER_PRIVATE_KEY");
    }
}
