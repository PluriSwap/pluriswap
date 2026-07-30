// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CoreDeployer} from "../src/CoreDeployer.sol";
import {CoreEscrow} from "../src/CoreEscrow.sol";
import {CreditLedger} from "../src/CreditLedger.sol";
import {Coordinator} from "../src/Coordinator.sol";

contract DeployCoreTest is Test {
    bytes32 internal constant SALT = keccak256("pluriswap.core.test");

    function test_create2_factory_predictsTriad() public {
        uint32 version = 2;
        bytes32 charter = bytes32(uint256(1));
        bytes32 tech = bytes32(uint256(2));
        address owner = address(this);

        bytes memory initCode = abi.encodePacked(
            type(CoreDeployer).creationCode, abi.encode(version, charter, tech, owner)
        );
        // In tests, `new X{salt}` CREATE2s from the test contract (not Nick's factory).
        address factoryPredicted =
            vm.computeCreate2Address(SALT, keccak256(initCode), address(this));
        address ledgerPredicted = vm.computeCreateAddress(factoryPredicted, 1);
        address coordinatorPredicted = vm.computeCreateAddress(factoryPredicted, 2);
        address escrowPredicted = vm.computeCreateAddress(factoryPredicted, 3);

        CoreDeployer deployed = new CoreDeployer{salt: SALT}(version, charter, tech, owner);

        assertEq(address(deployed), factoryPredicted);
        assertEq(address(deployed.ledger()), ledgerPredicted);
        assertEq(address(deployed.coordinator()), coordinatorPredicted);
        assertEq(address(deployed.escrow()), escrowPredicted);

        CreditLedger ledger = deployed.ledger();
        Coordinator coordinator = deployed.coordinator();
        CoreEscrow escrow = deployed.escrow();

        assertEq(ledger.escrow(), address(escrow));
        assertEq(coordinator.escrow(), address(escrow));
        assertEq(address(escrow.ledger()), address(ledger));
        assertEq(address(escrow.coordinator()), address(coordinator));
    }

    function test_create2_sameSalt_reverts() public {
        new CoreDeployer{salt: SALT}(2, bytes32(uint256(1)), bytes32(uint256(2)), address(this));
        // CREATE2 collisions revert with empty data; expectRevert is flaky at this depth.
        try this.deployWithSalt(SALT) {
            fail("expected CREATE2 salt collision");
        } catch {
            // expected
        }
    }

    function deployWithSalt(bytes32 salt) external {
        new CoreDeployer{salt: salt}(2, bytes32(uint256(1)), bytes32(uint256(2)), address(this));
    }
}
