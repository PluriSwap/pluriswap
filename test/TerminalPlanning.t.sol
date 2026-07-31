// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Coordinator} from "../src/Coordinator.sol";
import {DealHashing} from "../src/libraries/DealHashing.sol";
import {TerminalAllocation, TerminalRecord} from "../src/libraries/DealTypes.sol";

contract TerminalPlanningTest is Test {
    Coordinator internal coordinator;

    function setUp() public {
        coordinator = new Coordinator(uint64(block.chainid), address(0xE), address(this));
    }

    function test_planDealTerminal_coalescesEqualReceiversAndHashesRecord() public view {
        (TerminalRecord memory record, bytes32 terminalHash, TerminalAllocation[] memory allocs) = coordinator.planDealTerminal(
            1,
            2,
            address(0xE5C),
            address(0x1ED),
            bytes32(uint256(7)),
            address(0x70C),
            100e18,
            3e18,
            address(0x1111),
            address(0x1111),
            address(0xFEE),
            bytes32(uint256(1)),
            bytes32(0),
            bytes32(uint256(9)),
            16,
            1,
            10_000,
            bytes32(0),
            1_700_000_000
        );

        assertEq(record.holderSideReturn, 0);
        assertEq(record.providerGross, 100e18);
        assertEq(record.providerNet, 97e18);
        assertEq(record.completionCollected, 3e18);
        assertEq(terminalHash, DealHashing.hashTerminalRecord(record));
        assertEq(allocs.length, 2);
        assertEq(allocs[0].beneficiary, address(0x1111));
        assertEq(allocs[0].amount, 97e18);
        assertEq(allocs[1].beneficiary, address(0xFEE));
        assertEq(allocs[1].amount, 3e18);
    }
}
