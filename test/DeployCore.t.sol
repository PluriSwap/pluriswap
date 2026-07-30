// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CoreEscrow} from "../src/CoreEscrow.sol";
import {CreditLedger} from "../src/CreditLedger.sol";
import {Coordinator} from "../src/Coordinator.sol";

contract DeployCoreTest is Test {
    function test_createAddress_triad() public {
        uint64 chainId_ = uint64(block.chainid);
        address deployer = address(this);
        uint64 nonce = uint64(vm.getNonce(deployer));
        address escrowPredicted = vm.computeCreateAddress(deployer, nonce + 2);

        CreditLedger ledger = new CreditLedger(escrowPredicted, chainId_);
        Coordinator coordinator = new Coordinator(chainId_, escrowPredicted, address(this));
        CoreEscrow escrow = new CoreEscrow(
            chainId_, 2, bytes32(uint256(1)), bytes32(uint256(2)), address(ledger), address(coordinator)
        );

        assertEq(address(escrow), escrowPredicted);
        assertEq(ledger.escrow(), address(escrow));
        assertEq(coordinator.escrow(), address(escrow));
        assertEq(address(escrow.ledger()), address(ledger));
        assertEq(address(escrow.coordinator()), address(coordinator));
    }
}
