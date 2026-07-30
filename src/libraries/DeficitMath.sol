// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FullMath} from "./FullMath.sol";

/// @notice Conservative fixed-point arithmetic for attributable deficit claims.
/// @dev Factors use Q128.128. Gap is rounded upward and funded entitlement is therefore
///      never overstated. If a local history update cannot fit, it saturates instead of
///      reverting; the caller records a precision floor and continues conservatively.
library DeficitMath {
    uint256 internal constant SCALE = uint256(1) << 128;

    function ratioDown(uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        if (denominator == 0) revert FullMath.FullMath_DivByZero();
        return FullMath.mulDiv(numerator, SCALE, denominator);
    }

    function ratioUp(uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        if (denominator == 0) revert FullMath.FullMath_DivByZero();
        return FullMath.mulDivUp(numerator, SCALE, denominator);
    }

    function factorDown(uint256 factor, uint256 value) internal pure returns (uint256) {
        return FullMath.mulDiv(factor, value, SCALE);
    }

    function factorUp(uint256 factor, uint256 value) internal pure returns (uint256) {
        return FullMath.mulDivUp(factor, value, SCALE);
    }

    /// @notice Saturating ceil(a*b/denominator), reporting whether the result hit uint256 max.
    function mulDivUpSaturated(uint256 a, uint256 b, uint256 denominator)
        internal
        pure
        returns (uint256 result, bool saturated)
    {
        if (denominator == 0) revert FullMath.FullMath_DivByZero();

        uint256 prod0;
        uint256 prod1;
        assembly ("memory-safe") {
            let mm := mulmod(a, b, not(0))
            prod0 := mul(a, b)
            prod1 := sub(sub(mm, prod0), lt(mm, prod0))
        }
        if (prod1 >= denominator) return (type(uint256).max, true);

        result = FullMath.mulDiv(a, b, denominator);
        if (mulmod(a, b, denominator) != 0) {
            if (result == type(uint256).max) return (result, true);
            unchecked {
                ++result;
            }
        }
    }

    function gap(uint256 gapCoefficient, uint256 historyScale, uint256 history, uint256 unpaid)
        internal
        pure
        returns (uint256)
    {
        if (unpaid == 0) return 0;
        uint256 first = factorUp(gapCoefficient, unpaid);
        (uint256 second, bool saturated) = mulDivUpSaturated(historyScale, history, SCALE);
        if (saturated || first > unpaid || second > unpaid - first) return unpaid;
        return first + second;
    }

    function funded(uint256 gapAmount, uint256 unpaid) internal pure returns (uint256) {
        return gapAmount >= unpaid ? 0 : unpaid - gapAmount;
    }
}
