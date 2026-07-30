// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FullMath} from "./FullMath.sol";

/// @notice Settlement math per MANDATORY_CORE.md §10.3.
/// Uses full-precision mulDiv for provider gross; floor division with dust to holder.
library SettlementMath {
    uint16 constant BPS_DENOM = 10_000;

    /// @dev providerGross = floor(principal * bps / 10_000) using full precision.
    function providerGross(uint256 principal, uint16 bps) internal pure returns (uint256) {
        if (principal == 0 || bps == 0) return 0;
        return FullMath.mulDiv(principal, uint256(bps), uint256(BPS_DENOM));
    }

    /// @dev Returns (holderGross, providerGross). Dust goes to holder.
    function split(uint256 principal, uint16 providerBps)
        internal
        pure
        returns (uint256 holderGross, uint256 provGross)
    {
        provGross = providerGross(principal, providerBps);
        holderGross = principal - provGross;
    }

    /// @dev completionCollected = 0 if providerGross == 0, else min(completionFee, providerGross).
    function completionCollected(uint256 completionFee, uint256 provGross)
        internal
        pure
        returns (uint256)
    {
        if (provGross == 0) return 0;
        return completionFee < provGross ? completionFee : provGross;
    }

    /// @dev Checked uint64 addition; reverts on overflow.
    function checkedAdd64(uint64 a, uint64 b) internal pure returns (uint64) {
        uint64 result = a + b;
        if (result < a) revert Overflow();
        return result;
    }
}

error Overflow();
