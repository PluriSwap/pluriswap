// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Coordinator} from "../src/Coordinator.sol";
import {ModuleBinding} from "../src/libraries/DealTypes.sol";
import {ModuleCodehashMismatch, ModuleBindingMismatch} from "../src/libraries/CoreErrors.sol";

contract CoordinatorTest is Test {
    Coordinator coordinator;

    function setUp() public {
        coordinator = new Coordinator(uint64(block.chainid), address(0xE), address(this));
    }

    function _binding() internal view returns (ModuleBinding memory binding) {
        binding = ModuleBinding({
            role: 0,
            module: address(this),
            runtimeCodeHash: address(this).codehash,
            policyHash: keccak256("policy"),
            manifestHash: keccak256("manifest"),
            apiId: keccak256("api"),
            moduleTermsHash: keccak256("terms"),
            capabilityMask: 1
        });
    }

    function test_allowAndDisallowExactTuple() public {
        ModuleBinding memory binding = _binding();
        coordinator.allow(binding);
        assertTrue(coordinator.isAllowed(binding));
        coordinator.disallow(binding);
        assertFalse(coordinator.isAllowed(binding));
    }

    function test_wrongRuntimeCodeHashRejects() public {
        ModuleBinding memory binding = _binding();
        binding.runtimeCodeHash = bytes32(uint256(1));
        vm.expectRevert(ModuleCodehashMismatch.selector);
        coordinator.allow(binding);
    }

    function test_invalidRoleAndZeroBindingHashesReject() public {
        ModuleBinding memory binding = _binding();
        binding.role = 8;
        vm.expectRevert(ModuleBindingMismatch.selector);
        coordinator.allow(binding);

        binding.role = 0;
        binding.policyHash = bytes32(0);
        vm.expectRevert(ModuleBindingMismatch.selector);
        coordinator.allow(binding);
    }
}
