// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {DealTerms} from "../src/libraries/Types.sol";
import {Terms} from "../src/libraries/Terms.sol";

contract TermsTest is Test {
    address internal holder = address(0xA11CE);
    address internal provider = address(0xB0B);
    address internal token = address(0x5555);

    function _validTerms() internal view returns (DealTerms memory t) {
        t.holder = holder;
        t.controller = holder;
        t.provider = provider;
        t.token = token;
        t.principal = 1_000_000;
        t.fiatDuration = 3600;
        t.releaseDuration = 1800;
        t.disputeDuration = 7200;
        t.arbitrationDuration = 0;
        t.packageIds = new bytes32[](0);
    }

    function test_hashTerms_stable() public view {
        DealTerms memory a = _validTerms();
        DealTerms memory b = _validTerms();
        bytes32 ha = Terms.hashTerms(a);
        bytes32 hb = Terms.hashTerms(b);
        assertEq(ha, hb);
        assertTrue(ha != bytes32(0), "hash must be non-zero");
        a.principal = 2_000_000;
        assertTrue(Terms.hashTerms(a) != hb, "principal must enter the hash");
    }

    function test_hashTerms_revertsIfPackageIdsUnsorted() public {
        DealTerms memory t = _validTerms();
        t.packageIds = new bytes32[](2);
        t.packageIds[0] = bytes32(uint256(2));
        t.packageIds[1] = bytes32(uint256(1));
        vm.expectRevert();
        Terms.hashTerms(t);
    }

    function test_hashTerms_revertsIfDuplicatePackageId() public {
        DealTerms memory t = _validTerms();
        t.packageIds = new bytes32[](2);
        t.packageIds[0] = bytes32(uint256(1));
        t.packageIds[1] = bytes32(uint256(1));
        vm.expectRevert();
        Terms.hashTerms(t);
    }

    function test_hashTerms_revertsIfHolderEqualsProvider() public {
        DealTerms memory t = _validTerms();
        t.provider = t.holder;
        vm.expectRevert();
        Terms.hashTerms(t);
    }

    function test_hashTerms_revertsIfPrincipalZero() public {
        DealTerms memory t = _validTerms();
        t.principal = 0;
        vm.expectRevert();
        Terms.hashTerms(t);
    }
}
