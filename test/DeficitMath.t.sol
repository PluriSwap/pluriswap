// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeficitMath} from "../src/libraries/DeficitMath.sol";

contract DeficitMathHarness {
    function scale() external pure returns (uint256) {
        return DeficitMath.SCALE;
    }

    function gap(uint256 coefficient, uint256 historyScale, uint256 history, uint256 unpaid)
        external
        pure
        returns (uint256)
    {
        return DeficitMath.gap(coefficient, historyScale, history, unpaid);
    }

    function funded(uint256 gapAmount, uint256 unpaid) external pure returns (uint256) {
        return DeficitMath.funded(gapAmount, unpaid);
    }

    function mulDivUpSaturated(uint256 a, uint256 b, uint256 denominator)
        external
        pure
        returns (uint256 result, bool saturated)
    {
        return DeficitMath.mulDivUpSaturated(a, b, denominator);
    }
}

contract DeficitMathTest is Test {
    DeficitMathHarness harness;

    function setUp() public {
        harness = new DeficitMathHarness();
    }

    function test_gapRoundsUpAndFundedRoundsDown() public {
        uint256 scale = harness.scale();
        uint256 gapAmount = harness.gap(scale / 2, scale, 0, 3);

        assertEq(gapAmount, 2);
        assertEq(harness.funded(gapAmount, 3), 1);
    }

    function test_gapClampsToUnpaid() public {
        uint256 scale = harness.scale();
        assertEq(harness.gap(scale, type(uint256).max, type(uint256).max, 7), 7);
        assertEq(harness.funded(7, 7), 0);
    }

    function test_historyProductSaturatesInsteadOfWrapping() public {
        (uint256 result, bool saturated) =
            harness.mulDivUpSaturated(type(uint256).max, type(uint256).max, harness.scale());

        assertTrue(saturated);
        assertEq(result, type(uint256).max);
    }
}
