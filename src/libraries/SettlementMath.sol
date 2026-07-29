// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library SettlementMath {
    uint16 internal constant BPS_DENOM = 10_000;

    function providerGross(uint256 principal, uint16 bps) internal pure returns (uint256) {
        return (principal * uint256(bps)) / uint256(BPS_DENOM);
    }

    function split(uint256 principal, uint16 providerBps)
        internal
        pure
        returns (uint256 holderGross, uint256 provGross)
    {
        provGross = providerGross(principal, providerBps);
        holderGross = principal - provGross;
    }

    function completionCollected(uint256 completionFee, uint256 provGross)
        internal
        pure
        returns (uint256)
    {
        if (provGross == 0) return 0;
        return completionFee < provGross ? completionFee : provGross;
    }
}
