// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FullMath} from "../src/libraries/FullMath.sol";

contract FullMathWrapper {
    function tryMulDiv(uint256 a, uint256 b, uint256 d) external pure returns (uint256) {
        return FullMath.mulDiv(a, b, d);
    }

    function tryMulDivUp(uint256 a, uint256 b, uint256 d) external pure returns (uint256) {
        return FullMath.mulDivUp(a, b, d);
    }
}

contract FullMathTest is Test {
    FullMathWrapper wrapper;

    function setUp() public {
        wrapper = new FullMathWrapper();
    }

    function test_mulDiv_basic() public {
        assertEq(wrapper.tryMulDiv(100, 200, 10), 2000);
        assertEq(wrapper.tryMulDiv(100, 0, 10), 0);
        assertEq(wrapper.tryMulDiv(0, 200, 10), 0);
    }

    function test_mulDiv_floor() public {
        assertEq(wrapper.tryMulDiv(100, 3, 7), 42);
        assertEq(wrapper.tryMulDiv(101, 5000, 10000), 50);
    }

    function test_mulDivUp_ceilsWithoutChangingExactValues() public {
        assertEq(wrapper.tryMulDivUp(100, 3, 7), 43);
        assertEq(wrapper.tryMulDivUp(100, 200, 10), 2000);
        assertEq(wrapper.tryMulDivUp(0, 200, 10), 0);
    }

    function test_mulDivUp_revert_overflow() public {
        vm.expectRevert(FullMath.FullMath_Overflow.selector);
        wrapper.tryMulDivUp(type(uint256).max, type(uint256).max, type(uint256).max - 1);
    }

    function test_mulDiv_largeNoOverflow() public {
        uint256 max = type(uint256).max;
        // max * max / max = max
        assertEq(wrapper.tryMulDiv(max, max, max), max);
        // max * 1 / 2 = floor(max/2)
        assertEq(wrapper.tryMulDiv(max, 1, 2), max / 2);
    }

    function test_mulDiv_bpsDenominator() public {
        assertEq(wrapper.tryMulDiv(100e18, 5000, 10000), 50e18);
        assertEq(wrapper.tryMulDiv(101, 5000, 10000), 50);
        assertEq(wrapper.tryMulDiv(100e18, 10000, 10000), 100e18);
        assertEq(wrapper.tryMulDiv(100e18, 0, 10000), 0);
    }

    function test_mulDiv_revert_zeroDenominator() public {
        vm.expectRevert(FullMath.FullMath_DivByZero.selector);
        wrapper.tryMulDiv(100, 200, 0);
    }

    function test_mulDiv_revert_overflow() public {
        // max * max / 1 overflows 256 bits
        vm.expectRevert(FullMath.FullMath_Overflow.selector);
        wrapper.tryMulDiv(type(uint256).max, type(uint256).max, 1);
    }
}
