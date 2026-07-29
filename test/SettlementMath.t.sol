// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SettlementMath} from "../src/libraries/SettlementMath.sol";

contract SettlementMathTest is Test {
    function test_split_zeroBps() public pure {
        (uint256 holder, uint256 prov) = SettlementMath.split(1000, 0);
        assertEq(holder, 1000);
        assertEq(prov, 0);
    }

    function test_split_fullBps() public pure {
        (uint256 holder, uint256 prov) = SettlementMath.split(1000, 10_000);
        assertEq(holder, 0);
        assertEq(prov, 1000);
    }

    function test_split_halfOddPrincipal_dustToHolder() public pure {
        (uint256 holder, uint256 prov) = SettlementMath.split(101, 5_000);
        assertEq(prov, 50);
        assertEq(holder, 51);
    }

    function test_completionCollected_capsByGross() public pure {
        assertEq(SettlementMath.completionCollected(100, 40), 40);
        assertEq(SettlementMath.completionCollected(100, 0), 0);
        assertEq(SettlementMath.completionCollected(10, 40), 10);
    }
}
