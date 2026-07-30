// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Full-precision 512-bit multiplication and division.
/// @dev Returns floor(a * b / denominator). Reverts on overflow or divide-by-zero.
/// Uses the Remco Bloemen / OpenZeppelin algorithm.
library FullMath {
    error FullMath_DivByZero();
    error FullMath_Overflow();

    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            // 512-bit multiply [prod1 prod0]
            uint256 prod0; // Lower 256 bits
            uint256 prod1; // Upper 256 bits
            assembly ("memory-safe") {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            // Handle non-overflow case (product fits in 256 bits)
            if (prod1 == 0) {
                if (denominator == 0) revert FullMath_DivByZero();
                return prod0 / denominator;
            }

            // Make sure the result is less than 2^256.
            // Also prevents denominator == 0.
            if (denominator <= prod1) {
                if (denominator == 0) revert FullMath_DivByZero();
                revert FullMath_Overflow();
            }

            uint256 remainder;
            assembly ("memory-safe") {
                remainder := mulmod(a, b, denominator)
            }
            // Subtract remainder from prod1:prod0
            assembly ("memory-safe") {
                prod0 := sub(prod0, remainder)
            }

            // Factor powers of two out of denominator.
            // twos = denominator & (-denominator) = largest power of 2 dividing denominator.
            uint256 twos = (type(uint256).max - denominator + 1) & denominator;
            // Divide denominator by power of two
            assembly ("memory-safe") {
                denominator := div(denominator, twos)
            }
            // Divide prod0 by twos (right shift by k where twos = 2^k)
            assembly ("memory-safe") {
                prod0 := div(prod0, twos)
            }
            // Shift in bits from prod1: prod0 |= prod1 * (2^(256-k))
            // 2^(256-k) = (2^256-1)/twos + 1, which wraps to 0 when twos=1 (correct)
            assembly ("memory-safe") {
                twos := add(div(not(0), twos), 1)
            }
            prod0 |= prod1 * twos;

            // Invert denominator mod 2^256 using Newton-Raphson iteration.
            // This computes denominator^(-1) mod 2^256.
            uint256 inv = (3 * denominator) ^ 2;
            inv *= 2 - denominator * inv; // converges 0.5 bits per step
            inv *= 2 - denominator * inv; // 1 bit
            inv *= 2 - denominator * inv; // 2 bits
            inv *= 2 - denominator * inv; // 4 bits
            inv *= 2 - denominator * inv; // 8 bits
            inv *= 2 - denominator * inv; // 16 bits
            inv *= 2 - denominator * inv; // 32 bits
            inv *= 2 - denominator * inv; // 64 bits
            inv *= 2 - denominator * inv; // 128 bits
            inv *= 2 - denominator * inv; // 256 bits

            result = prod0 * inv;
            return result;
        }
    }
}
