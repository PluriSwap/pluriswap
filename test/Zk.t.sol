// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ZkMock} from "../mocks/ZkMock.sol";
import {VerifierMock} from "../mocks/VerifierMock.sol";
import {PackageId} from "../src/libraries/PackageId.sol";

contract ZkMockTest is Test {
    uint256 internal constant VERIFY_FEE = 1_000_000;
    bytes32 internal constant DEAL_A = keccak256("deal-a");
    bytes32 internal constant DEAL_B = keccak256("deal-b");
    bytes32 internal constant NULLIFIER = keccak256("receipt-1");

    VerifierMock internal verifier;
    ZkMock internal zk;
    address internal feeRecipient = address(0xFEE);

    function setUp() public {
        verifier = new VerifierMock();
        zk = new ZkMock(verifier, feeRecipient, VERIFY_FEE, address(this));
    }

    function test_packageId_zkStable() public view {
        assertEq(zk.packageId(), PackageId.zk(address(zk), address(verifier), feeRecipient, VERIFY_FEE));
    }

    function test_packageId_bindsModule() public {
        ZkMock other = new ZkMock(verifier, feeRecipient, VERIFY_FEE, address(this));
        assertTrue(zk.packageId() != other.packageId());
        assertEq(other.packageId(), PackageId.zk(address(other), address(verifier), feeRecipient, VERIFY_FEE));
    }

    function test_verifyProof_onlyOperator() public {
        vm.prank(address(0xB0B));
        vm.expectRevert(ZkMock.Unauthorized.selector);
        zk.verifyProof(DEAL_A, abi.encode(DEAL_A, NULLIFIER));
        assertFalse(zk.used(NULLIFIER));
    }

    function test_wrongDealIdReverts() public {
        bytes memory proof = abi.encode(DEAL_A, NULLIFIER);
        vm.expectRevert(ZkMock.WrongDealId.selector);
        zk.verifyProof(DEAL_B, proof);
        assertFalse(zk.used(NULLIFIER));
    }

    function test_paymentNullifierReplayReverts() public {
        bytes memory proofA = abi.encode(DEAL_A, NULLIFIER);
        assertEq(zk.verifyProof(DEAL_A, proofA), NULLIFIER);
        assertTrue(zk.used(NULLIFIER));

        bytes memory proofB = abi.encode(DEAL_B, NULLIFIER);
        vm.expectRevert(ZkMock.NullifierUsed.selector);
        zk.verifyProof(DEAL_B, proofB);
    }
}
