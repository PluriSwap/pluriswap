// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {ChainIds} from "./ChainIds.s.sol";
import {PoseidonEnsurer} from "./Poseidon.s.sol";
import {PoseidonTree, DEFAULT_ROOT_HISTORY} from "../src/packages/PoseidonTree.sol";
import {HumanityRegistry} from "../src/packages/HumanityRegistry.sol";
import {PrivatePassport} from "../src/packages/PrivatePassport.sol";
import {PrivateReputation} from "../src/packages/PrivateReputation.sol";
import {PrivateBondVault} from "../src/packages/PrivateBondVault.sol";
import {IGitcoinPassportDecoder} from "../src/packages/interfaces/IGitcoinPassportDecoder.sol";
import {RegistryHumanityVerifier} from "../src/packages/adapters/RegistryHumanityVerifier.sol";
import {RegistryAccountVerifier} from "../src/packages/adapters/RegistryAccountVerifier.sol";
import {BundleVerifier} from "../src/packages/adapters/BundleVerifier.sol";
import {ClaimVerifier} from "../src/packages/adapters/ClaimVerifier.sol";
import {DepositVerifier} from "../src/packages/adapters/DepositVerifier.sol";
import {ReabsorbVerifier} from "../src/packages/adapters/ReabsorbVerifier.sol";
import {WithdrawVerifier} from "../src/packages/adapters/WithdrawVerifier.sol";
import {PassportDecoderMock} from "../mocks/PassportDecoderMock.sol";

/// @title DeployPrivate
/// @notice The private layer of PLURISWAP.md §3.15, as one deployment: Poseidon singletons, the
///         humanity registry, the nine real Honk verifier adapters, and the passport / reputation /
///         bond-vault triangle behind the kernel's `IPassport`, `IReputation` and `IBondVault`.
/// @dev F1–F4 closed in tests and had never been deployed. This is that gap.
///
///      Two things make the order non-obvious and both are load-bearing:
///
///      * **The wiring circle.** The accounts tree's owner is the reputation, the reputation's bound
///        vault is the vault, and the vault's gating reputation is the reputation. Broken exactly as
///        the tests break it — by CREATE prediction off the deployer's nonce, with every constructor
///        argument already deployed before the prediction is taken, so the count cannot drift. The
///        script asserts both predictions landed rather than trusting the arithmetic.
///      * **Nothing here is linked.** The Honk verifiers are deployed by their adapters from
///        committed initcode (`test/fixtures/verifiers/`), and Poseidon is the pinned upstream
///        deployment (§5.1) — `ensurePoseidon` puts it there on a chain that lacks it, which on
///        Arbitrum today means `PoseidonT2`.
///
///      Test chains only. The humanity gate needs a Passport decoder, and off Arbitrum One that is
///      `PassportDecoderMock`, whose `setScore` is unauthenticated — enrolment would be a free pass.
///      Arbitrum One is refused for a second reason that outlives the mock: the circuits are
///      unaudited and they touch money (§3.15.11).
///
///      `REGISTRY_ID` defaults to the canonical domain pinned in `test/fixtures/vectors.json`, so the
///      committed fixture proofs verify against this deployment and the whole stack can be smoke
///      tested on a testnet without a prover.
contract DeployPrivate is PoseidonEnsurer, ChainIds {
    using stdJson for string;

    /// @dev Mirrors `DeployPackages`: same fee policy, so the private and public reputation packages
    ///      are comparable. Placeholders, never a production identity (PLURISWAP.md §5.7).
    uint256 internal constant ACT_FEE = 100_000;
    uint256 internal constant COMP_FEE = 50_000;
    uint256 internal constant CONTEST_BPS = 100;
    uint256 internal constant CONTEST_FLOOR = 2_000_000;
    address internal constant FEE_RECIPIENT = address(0xFEE);
    address internal constant SINK = address(0xdeaD);

    struct Verifiers {
        RegistryHumanityVerifier humanity;
        RegistryAccountVerifier account;
        /// @dev One verifier for the whole side since 2026-09-23 (§3.15.4): the passport, admission
        ///      and split of one side are one proof, checked once and read by the three modules.
        BundleVerifier bundle;
        ClaimVerifier claim;
        DepositVerifier deposit;
        ReabsorbVerifier reabsorb;
        WithdrawVerifier withdraw;
    }

    struct Stack {
        address decoder;
        HumanityRegistry registry;
        PoseidonTree accountTree;
        PrivatePassport passport;
        PrivateReputation reputation;
        PrivateBondVault vault;
    }

    function run() external {
        _requireMockChain("DeployPrivate");
        address escrow = _escrow();
        bytes32 registryId = _registryId();
        uint256 pk = _key();
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);
        ensurePoseidon();
        (Stack memory s, Verifiers memory v) = deployStack(deployer, escrow, registryId, _decoder());
        vm.stopBroadcast();

        _report(s, v, escrow, registryId);
    }

    /// @notice The wiring itself, with nothing around it: no env, no broadcast, no JSON. `run` calls
    ///         it between `startBroadcast` and `stopBroadcast`; `test/DeployPrivate.t.sol` calls it
    ///         directly and then puts real proofs through what it built, so the deployed wiring and
    ///         the tested wiring cannot drift apart.
    /// @param deployer The address whose nonce the CREATE predictions are taken from — the caller.
    function deployStack(address deployer, address escrow, bytes32 registryId, address decoder)
        public
        returns (Stack memory s, Verifiers memory v)
    {
        s.decoder = decoder;
        s.registry = new HumanityRegistry(IGitcoinPassportDecoder(decoder), 0, registryId);
        v = _deployVerifiers(s.registry);

        // Prediction taken here, after every constructor argument exists: +2 is the reputation, +3
        // the vault. The vault's own notes tree is a CREATE by the vault, not by the deployer, so it
        // does not move this sequence.
        uint256 n = vm.getNonce(deployer);
        address predictedRep = vm.computeCreateAddress(deployer, n + 2);
        address predictedVault = vm.computeCreateAddress(deployer, n + 3);

        s.accountTree = new PoseidonTree(32, DEFAULT_ROOT_HISTORY, predictedRep);
        s.passport = new PrivatePassport(s.accountTree, v.humanity, v.bundle);
        s.reputation = new PrivateReputation(
            s.passport,
            s.accountTree,
            v.account,
            v.bundle,
            v.claim,
            FEE_RECIPIENT,
            ACT_FEE,
            COMP_FEE,
            CONTEST_BPS,
            CONTEST_FLOOR,
            escrow,
            predictedVault
        );
        s.vault =
            new PrivateBondVault(s.passport, s.reputation, SINK, escrow, v.deposit, v.bundle, v.reabsorb, v.withdraw);

        require(address(s.reputation) == predictedRep, "reputation prediction drifted");
        require(address(s.vault) == predictedVault, "vault prediction drifted");
        require(s.accountTree.owner() == address(s.reputation), "account tree owner");
        require(s.reputation.operator() == escrow, "reputation operator");
        require(s.reputation.bondsVault() == address(s.vault), "reciprocal rep/vault binding");
        require(s.vault.operator() == escrow, "vault operator");
        require(address(s.vault.passport()) == address(s.passport), "vault peer passport");
    }

    function _deployVerifiers(HumanityRegistry registry) internal returns (Verifiers memory v) {
        v.humanity = new RegistryHumanityVerifier(registry, _initcode("register_humanity"));
        v.account = new RegistryAccountVerifier(registry, _initcode("register_account"));
        v.bundle = new BundleVerifier(_initcode("prepare_side"));
        v.claim = new ClaimVerifier(_initcode("claim"));
        v.deposit = new DepositVerifier(_initcode("deposit"));
        v.reabsorb = new ReabsorbVerifier(_initcode("reabsorb"));
        v.withdraw = new WithdrawVerifier(_initcode("withdraw"));
    }

    /// @dev The generated Honk verifier of one circuit, as committed by `bun circuits:prove`. The
    ///      main tree cannot compile these (via_ir vs the generated dispatchers), which is why they
    ///      travel as initcode and each adapter CREATEs its own.
    function _initcode(string memory circuit) internal view returns (bytes memory) {
        return vm.readFile(string.concat("test/fixtures/verifiers/", circuit, ".json")).readBytes(".initcode");
    }

    function _decoder() internal returns (address decoder) {
        decoder = vm.envOr("PASSPORT_DECODER", address(0));
        if (decoder != address(0)) {
            require(decoder.code.length > 0, "passport decoder has no code on this chain");
            return decoder;
        }
        // `setScore` takes no authorisation: anyone can hand themselves a passing score and enrol.
        _requireMockChain("PassportDecoderMock");
        return address(new PassportDecoderMock(200_000, 1 days));
    }

    /// @dev The enrolment domain `hn` is nullified under. Defaults to the canonical one the circuit
    ///      vectors pin, so the committed fixture proofs verify against this deployment.
    function _registryId() internal view returns (bytes32) {
        bytes32 override_ = vm.envOr("REGISTRY_ID", bytes32(0));
        if (override_ != bytes32(0)) return override_;
        return bytes32(vm.readFile("test/fixtures/vectors.json").readUint(".registry.registry_id"));
    }

    function _escrow() internal view returns (address escrow) {
        escrow = vm.envOr("ESCROW", address(0));
        if (escrow != address(0)) return escrow;
        string memory packages = block.chainid == ARBITRUM_SEPOLIA
            ? "deployments/sepolia-packages.json"
            : string.concat("deployments/", vm.toString(block.chainid), "-packages.json");
        require(vm.exists(packages), string.concat("no ESCROW and no ", packages));
        escrow = vm.readFile(packages).readAddress(".escrow");
        require(escrow.code.length > 0, "escrow has no code on this chain");
    }

    function _out() internal view returns (string memory) {
        if (block.chainid == ARBITRUM_SEPOLIA) return "deployments/sepolia-private.json";
        return string.concat("deployments/", vm.toString(block.chainid), "-private.json");
    }

    function _key() internal view override returns (uint256) {
        if (block.chainid == ANVIL) return 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        return vm.envUint("HOLDER_PRIVATE_KEY");
    }

    function _report(Stack memory s, Verifiers memory v, address escrow, bytes32 registryId) internal {
        console.log("chainId", block.chainid);
        console.log("escrow (operator)", escrow);
        console.log("HumanityRegistry", address(s.registry));
        console.log("accountTree", address(s.accountTree));
        console.log("PrivatePassport", address(s.passport));
        console.log("PrivateReputation", address(s.reputation));
        console.log("PrivateBondVault", address(s.vault));

        string memory obj = "private";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "escrow", escrow);
        vm.serializeAddress(obj, "passportDecoder", s.decoder);
        vm.serializeBytes32(obj, "registryId", registryId);
        vm.serializeAddress(obj, "humanityRegistry", address(s.registry));
        vm.serializeAddress(obj, "enrollmentTree", address(s.registry.tree()));
        vm.serializeAddress(obj, "accountTree", address(s.accountTree));
        vm.serializeAddress(obj, "notesTree", address(s.vault.notesTree()));
        vm.serializeAddress(obj, "privatePassport", address(s.passport));
        vm.serializeAddress(obj, "privateReputation", address(s.reputation));
        vm.serializeAddress(obj, "privateBondVault", address(s.vault));
        vm.serializeAddress(obj, "feeRecipient", FEE_RECIPIENT);
        vm.serializeAddress(obj, "sink", SINK);
        vm.serializeBytes32(obj, "passportId", s.passport.packageId());
        vm.serializeBytes32(obj, "reputationId", s.reputation.packageId());
        vm.serializeBytes32(obj, "bondsId", s.vault.packageId());
        vm.serializeAddress(obj, "humanityVerifier", address(v.humanity));
        vm.serializeAddress(obj, "accountVerifier", address(v.account));
        vm.serializeAddress(obj, "bundleVerifier", address(v.bundle));
        vm.serializeAddress(obj, "claimVerifier", address(v.claim));
        vm.serializeAddress(obj, "depositVerifier", address(v.deposit));
        vm.serializeAddress(obj, "reabsorbVerifier", address(v.reabsorb));
        string memory json = vm.serializeAddress(obj, "withdrawVerifier", address(v.withdraw));
        vm.writeJson(json, _out());
        console.log("wrote", _out());
    }
}
