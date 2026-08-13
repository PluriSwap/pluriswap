// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {DealTerms} from "./Types.sol";

library Terms {
    bytes32 internal constant DEAL_TERMS_TYPEHASH = keccak256(
        "DealTerms(address holder,address controller,address provider,address token,uint256 principal,uint256 fiatDuration,uint256 releaseDuration,uint256 disputeDuration,uint256 arbitrationDuration,bytes32[] packageIds)"
    );

    error UnsortedPackageIds();
    error HolderEqualsProvider();
    error ZeroPrincipal();

    function hashTerms(DealTerms memory t) public pure returns (bytes32) {
        if (t.holder == t.provider) revert HolderEqualsProvider();
        if (t.principal == 0) revert ZeroPrincipal();
        _assertPackageIdsCanonical(t.packageIds);
        return keccak256(
            abi.encode(
                DEAL_TERMS_TYPEHASH,
                t.holder,
                t.controller,
                t.provider,
                t.token,
                t.principal,
                t.fiatDuration,
                t.releaseDuration,
                t.disputeDuration,
                t.arbitrationDuration,
                keccak256(abi.encodePacked(t.packageIds))
            )
        );
    }

    function _assertPackageIdsCanonical(bytes32[] memory ids) private pure {
        for (uint256 i = 1; i < ids.length; i++) {
            if (ids[i] <= ids[i - 1]) revert UnsortedPackageIds();
        }
    }
}
