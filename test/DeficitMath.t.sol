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

    function test_gapRoundsUpAndFundedRoundsDown() public view {
        uint256 scale = harness.scale();
        uint256 gapAmount = harness.gap(scale / 2, scale, 0, 3);

        assertEq(gapAmount, 2);
        assertEq(harness.funded(gapAmount, 3), 1);
    }

    function test_gapClampsToUnpaid() public view {
        uint256 scale = harness.scale();
        assertEq(harness.gap(scale, type(uint256).max, type(uint256).max, 7), 7);
        assertEq(harness.funded(7, 7), 0);
    }

    function test_historyProductSaturatesInsteadOfWrapping() public view {
        (uint256 result, bool saturated) =
            harness.mulDivUpSaturated(type(uint256).max, type(uint256).max, harness.scale());

        assertTrue(saturated);
        assertEq(result, type(uint256).max);
    }

    function testFuzz_zeroHistorySplitRoundingHasOneUnitPerExtraChildBound(
        uint256 coefficientSeed,
        uint96 nominalSeed,
        uint8 childCountSeed,
        uint96 firstShareSeed,
        uint96 secondShareSeed
    ) public view {
        uint256 childCount = bound(childCountSeed, 1, 3);
        uint256 nominal = bound(nominalSeed, childCount, 1e12);
        uint256 coefficient = bound(coefficientSeed, 0, harness.scale());
        uint256[] memory childNominals =
            _partition(nominal, childCount, firstShareSeed, secondShareSeed);

        uint256 parentGap = harness.gap(coefficient, harness.scale(), 0, nominal);
        uint256 childGapTotal;
        for (uint256 i; i < childCount; ++i) {
            childGapTotal += harness.gap(coefficient, harness.scale(), 0, childNominals[i]);
        }

        assertGe(childGapTotal, parentGap);
        assertLe(childGapTotal - parentGap, childCount - 1);
    }

    function test_zeroHistorySplitCanReachOneUnitPerExtraChildBound() public view {
        uint256 scale = harness.scale();
        uint256 coefficient = scale / 3;
        uint256 parentGap = harness.gap(coefficient, scale, 0, 2);
        uint256 childGapTotal =
            harness.gap(coefficient, scale, 0, 1) + harness.gap(coefficient, scale, 0, 1);

        assertEq(parentGap, 1);
        assertEq(childGapTotal, 2);
        assertEq(childGapTotal - parentGap, 1);
    }

    function _partition(
        uint256 nominal,
        uint256 childCount,
        uint256 firstShareSeed,
        uint256 secondShareSeed
    ) internal pure returns (uint256[] memory childNominals) {
        childNominals = new uint256[](childCount);
        if (childCount == 1) {
            childNominals[0] = nominal;
            return childNominals;
        }

        uint256 first = 1 + (firstShareSeed % (nominal - childCount + 1));
        childNominals[0] = first;
        if (childCount == 2) {
            childNominals[1] = nominal - first;
            return childNominals;
        }

        uint256 remaining = nominal - first;
        uint256 second = 1 + (secondShareSeed % (remaining - 1));
        childNominals[1] = second;
        childNominals[2] = remaining - second;
    }
}
