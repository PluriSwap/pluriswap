// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FullMath} from "../src/libraries/FullMath.sol";
import {FullMathVectors} from "./vectors/FullMathVectors.sol";

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

    function test_mulDiv_highWordBorrowRegression() public view {
        FullMathVectors.Vector[] memory vectors = FullMathVectors.highWordBorrowCases();

        for (uint256 i; i < vectors.length; ++i) {
            FullMathVectors.Vector memory vector = vectors[i];
            uint256 productLow;
            unchecked {
                productLow = vector.a * vector.b;
            }

            assertGt(vector.productHigh, 0, vector.name);
            assertGt(vector.denominator, vector.productHigh, vector.name);
            assertEq(productLow, vector.productLow, vector.name);
            assertEq(mulmod(vector.a, vector.b, vector.denominator), vector.remainder, vector.name);
            assertGt(vector.remainder, vector.productLow, vector.name);
            assertEq(
                wrapper.tryMulDiv(vector.a, vector.b, vector.denominator),
                vector.expectedFloor,
                vector.name
            );
        }
    }

    function test_mulDivUp_highWordBorrowRegression() public view {
        FullMathVectors.Vector[] memory vectors = FullMathVectors.highWordBorrowCases();

        for (uint256 i; i < vectors.length; ++i) {
            FullMathVectors.Vector memory vector = vectors[i];

            assertGt(vector.remainder, 0, vector.name);
            assertEq(vector.expectedCeil, vector.expectedFloor + 1, vector.name);
            assertEq(
                wrapper.tryMulDivUp(vector.a, vector.b, vector.denominator),
                vector.expectedCeil,
                vector.name
            );
        }
    }

    function testFuzz_mulDiv_highWordBorrowAtBps(uint8 offsetSeed) public view {
        uint256 offset = bound(uint256(offsetSeed), 1, 31);
        uint256 a = (uint256(1) << 255) + offset;
        uint256 productLow = 2 * offset;
        uint256 decomposedRemainder = type(uint256).max % 10_000 + 1 + productLow;
        uint256 expectedFloor = type(uint256).max / 10_000 + decomposedRemainder / 10_000;

        assertGt(decomposedRemainder % 10_000, productLow);
        assertEq(wrapper.tryMulDiv(a, 2, 10_000), expectedFloor);
        assertEq(wrapper.tryMulDivUp(a, 2, 10_000), expectedFloor + 1);
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
