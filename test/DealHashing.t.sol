// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DealHashing} from "../src/libraries/DealHashing.sol";
import {DealTerms, ModuleIdentity} from "../src/libraries/DealTypes.sol";
import {DealSigUtils} from "./helpers/DealSigUtils.sol";

contract DealHashingTest is Test {
    function _emptyTerms() internal pure returns (DealTerms memory t) {
        ModuleIdentity[] memory modules;
        t.holder = address(1);
        t.provider = address(2);
        t.holderReceiver = address(3);
        t.providerReceiver = address(4);
        t.token = address(5);
        t.principal = 100e18;
        t.nonce = 1;
        t.createExpiry = 1_700_000_000;
        t.fiatDuration = 3600;
        t.releaseDuration = 3600;
        t.disputeDuration = 3600;
        t.disputeTimeoutProviderBps = 5000;
        t.modules = modules;
        t.extensions = "";
    }

    function test_hashDealTerms_golden() public pure {
        assertEq(
            DealHashing.hashDealTerms(_emptyTerms()),
            0x32939fdbe561087092889db77477a714f7d5eacddb2c91772a854909bafdad61
        );
    }

    function test_emptyExtensionsHash_isZero() public pure {
        assertEq(DealHashing.extensionsHash(""), bytes32(0));
    }

    function test_domainSeparator_matchesHelper() public view {
        bytes32 expected = DealSigUtils.domainSeparator(block.chainid, address(0xE5C));
        bytes32 manual = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes("PluriSwap")),
                keccak256(bytes("2")),
                block.chainid,
                address(0xE5C)
            )
        );
        assertEq(expected, manual);
    }
}
