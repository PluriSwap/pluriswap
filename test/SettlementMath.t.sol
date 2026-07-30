// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SettlementMath} from "../src/libraries/SettlementMath.sol";
import {FullMath} from "../src/libraries/FullMath.sol";

contract SettlementMathWrapper {
    function tryCheckedAdd64(uint64 a, uint64 b) external pure returns (uint64) {
        return SettlementMath.checkedAdd64(a, b);
    }
}

contract SettlementMathTest is Test {
    SettlementMathWrapper wrapper;

    function setUp() public {
        wrapper = new SettlementMathWrapper();
    }
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

    function test_split_largePrincipal_noOverflow() public pure {
        uint256 huge = type(uint256).max;
        (uint256 holder, uint256 prov) = SettlementMath.split(huge, 5_000);
        assertEq(prov, FullMath.mulDiv(huge, 5000, 10000));
        assertEq(holder, huge - prov);
    }

    function test_completionCollected_capsByGross() public pure {
        assertEq(SettlementMath.completionCollected(100, 40), 40);
        assertEq(SettlementMath.completionCollected(100, 0), 0);
        assertEq(SettlementMath.completionCollected(10, 40), 10);
    }

    function test_completionCollected_zeroGross() public pure {
        assertEq(SettlementMath.completionCollected(100, 0), 0);
    }

    function test_checkedAdd64_normal() public pure {
        assertEq(SettlementMath.checkedAdd64(100, 200), 300);
    }

    function test_checkedAdd64_overflow() public {
        vm.expectRevert();
        wrapper.tryCheckedAdd64(type(uint64).max, 1);
    }

}
