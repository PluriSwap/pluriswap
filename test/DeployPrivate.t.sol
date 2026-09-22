// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {DeployPrivate} from "../script/DeployPrivate.s.sol";
import {PoseidonSingletons} from "./PoseidonSingletons.sol";
import {PassportDecoderMock} from "../mocks/PassportDecoderMock.sol";
import {PackageId} from "../src/libraries/PackageId.sol";

/// @title DeployPrivate wiring tests
/// @notice The private layer of §3.15 was closed in tests and had never been deployed, so the only
///         wiring that had ever been exercised was each test file's own. This puts the DEPLOY
///         SCRIPT's wiring under real proofs, so the two cannot drift apart.
/// @dev What is actually at risk here is the circle: the accounts tree is owned by the reputation,
///      the reputation's bound vault is the vault, the vault gates on the reputation. The script
///      breaks it by CREATE prediction off the deployer's nonce, and an off-by-one there is a stack
///      that deploys cleanly and is wired to the wrong addresses forever.
contract DeployPrivateTest is Test {
    using stdJson for string;

    DeployPrivate internal script;
    address internal constant ESCROW = address(0xE5C0);

    function setUp() public {
        PoseidonSingletons.install();
        script = new DeployPrivate();
    }

    function _deploy() internal returns (DeployPrivate.Stack memory s) {
        bytes32 registryId = bytes32(vm.readFile("test/fixtures/vectors.json").readUint(".registry.registry_id"));
        address decoder = address(new PassportDecoderMock(200_000, 1 days));
        // The script predicts off the CALLER's nonce, and here the caller is the script contract.
        (s,) = script.deployStack(address(script), ESCROW, registryId, decoder);
    }

    function test_deployStack_closesTheWiringCircle() public {
        DeployPrivate.Stack memory s = _deploy();
        assertEq(s.accountTree.owner(), address(s.reputation), "tree owner");
        assertEq(s.reputation.bondsVault(), address(s.vault), "rep -> vault");
        assertEq(address(s.vault.reputation()), address(s.reputation), "vault -> rep");
        assertEq(address(s.passport.accountTree()), address(s.accountTree), "passport -> tree");
        assertEq(address(s.reputation.accountTree()), address(s.accountTree), "rep -> tree");
        assertEq(address(s.vault.passport()), address(s.passport), "vault -> passport");
    }

    /// The kernel only ever reaches these through `Packages.resolve`, which re-derives each id from
    /// the live module and its policy. A deployment whose ids do not match is a deployment no signed
    /// deal can name.
    function test_deployStack_packageIdsResolveAsTheKernelWouldDeriveThem() public {
        DeployPrivate.Stack memory s = _deploy();
        assertEq(s.passport.packageId(), PackageId.passport(address(s.passport)), "passport id");
        assertEq(
            s.reputation.packageId(),
            PackageId.reputation(
                address(s.reputation),
                s.reputation.feeRecipient(),
                s.reputation.activationFee(),
                s.reputation.completionFee(),
                s.reputation.contestBps(),
                s.reputation.contestFloor()
            ),
            "reputation id"
        );
        assertEq(s.vault.packageId(), PackageId.bonds(address(s.vault), s.vault.sink()), "bonds id");
        // `Packages.resolve` also demands both peers name the same passport.
        assertEq(address(s.reputation.passport()), address(s.passport), "rep peer");
        assertEq(address(s.vault.passport()), address(s.passport), "vault peer");
    }

    function test_deployStack_operatorIsTheEscrowEverywhere() public {
        DeployPrivate.Stack memory s = _deploy();
        assertEq(s.reputation.operator(), ESCROW);
        assertEq(s.vault.operator(), ESCROW);
    }

    /// The real proof leg: a committed `register_humanity` + `register_account` bundle must verify
    /// against a stack this script built, not one a test file hand-wired. That exercises the
    /// registry domain, both Honk adapters and the account tree in one shot.
    function test_deployStack_takesTheCommittedRegisterProofs() public {
        vm.warp(1_700_000_000);
        string memory vectors = vm.readFile("test/fixtures/vectors.json");
        DeployPrivate.Stack memory s = _deploy();

        address anchor = makeAddr("anchor");
        PassportDecoderMock(s.decoder).setScore(anchor, 200_000, uint64(block.timestamp + 30 days));
        // Resolve the commitment BEFORE the prank: an intervening call would eat it.
        bytes32 commitment = s.registry.identityCommitmentOf(bytes32(vectors.readUint(".registry.hsk")));
        vm.prank(anchor);
        s.registry.enroll(commitment);

        bytes32 hn = bytes32(vectors.readUint(".registry.sample_hn"));
        bytes32 leaf0 = bytes32(vectors.readUint(".registry.sample_leaf0"));
        s.passport
            .register(
                vm.readFile("test/fixtures/proofs/register_humanity.json").readBytes(".proof_with_public_inputs"), hn
            );
        s.reputation
            .register(
                vm.readFile("test/fixtures/proofs/register_account.json").readBytes(".proof_with_public_inputs"),
                hn,
                leaf0
            );

        assertTrue(s.passport.humanitySpent(hn), "humanity not burned");
        assertTrue(s.reputation.registeredHn(hn), "account not registered");
        assertEq(s.accountTree.nextIndex(), 1, "leaf0 not inserted");
        assertTrue(s.accountTree.isKnownRoot(s.accountTree.root()), "root not in the window");
    }
}
