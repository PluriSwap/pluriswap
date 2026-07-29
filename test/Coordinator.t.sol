// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Coordinator} from "../src/Coordinator.sol";
import {ModuleRole} from "../src/libraries/DealTypes.sol";
import {Unauthorized, ZeroAddress} from "../src/libraries/CoreErrors.sol";

contract CoordinatorTest is Test {
    Coordinator coord;
    address owner = address(0xBEEF);
    address escrow = address(0xE5C);
    address module = address(0x1234);

    bytes32 codehash = keccak256("code");
    bytes32 policyHash = keccak256("policy");

    function setUp() public {
        coord = new Coordinator(uint64(block.chainid), escrow, owner);
    }

    function test_isAllowed_falseByDefault() public view {
        assertFalse(coord.isAllowed(ModuleRole.PaymentProofVerifier, module, codehash, policyHash));
    }

    function test_allow_thenTrue() public {
        vm.prank(owner);
        coord.allow(ModuleRole.PaymentProofVerifier, module, codehash, policyHash);
        assertTrue(coord.isAllowed(ModuleRole.PaymentProofVerifier, module, codehash, policyHash));
    }

    function test_disallow() public {
        vm.startPrank(owner);
        coord.allow(ModuleRole.PaymentProofVerifier, module, codehash, policyHash);
        coord.disallow(ModuleRole.PaymentProofVerifier, module, codehash, policyHash);
        vm.stopPrank();
        assertFalse(coord.isAllowed(ModuleRole.PaymentProofVerifier, module, codehash, policyHash));
    }

    function test_nonOwner_allow_reverts() public {
        vm.expectRevert(Unauthorized.selector);
        coord.allow(ModuleRole.PaymentProofVerifier, module, codehash, policyHash);
    }

    function test_constructor_zeroEscrow_reverts() public {
        vm.expectRevert(ZeroAddress.selector);
        new Coordinator(1, address(0), owner);
    }

    function test_allow_zeroModule_reverts() public {
        vm.prank(owner);
        vm.expectRevert(ZeroAddress.selector);
        coord.allow(ModuleRole.BondVault, address(0), codehash, policyHash);
    }
}
