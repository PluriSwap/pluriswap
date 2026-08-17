// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {KlerosAdapter} from "../src/packages/KlerosAdapter.sol";
import {PackageId} from "../src/packages/PackageId.sol";
import {PluriSwapKlerosTemplate} from "../src/packages/PluriSwapKlerosTemplate.sol";
import {IArbitrableV2, IArbitratorV2} from "../src/packages/interfaces/IKlerosV2.sol";
import {MockArbitratorV2} from "../src/mocks/MockArbitratorV2.sol";
import {MockTemplateRegistry} from "../src/mocks/MockTemplateRegistry.sol";
contract KlerosAdapterTest is Test {
    uint256 internal constant COST = 0.01 ether;
    bytes32 internal constant DEAL = keccak256("deal-kleros");

    MockArbitratorV2 internal arbitrator;
    KlerosAdapter internal adapter;
    bytes internal extraData;
    address internal controller = address(0xC0);
    address internal provider = address(0xB0B);

    function setUp() public {
        extraData = abi.encode(uint256(1), uint256(3), uint256(1));
        arbitrator = new MockArbitratorV2(COST);
        adapter = new KlerosAdapter(address(arbitrator), extraData, 0, "", address(0), address(0));
        vm.deal(controller, 1 ether);
        vm.deal(provider, 1 ether);
    }

    function test_packageId_klerosStable() public view {
        assertEq(adapter.packageId(), PackageId.kleros(address(adapter), address(arbitrator), extraData));
        assertEq(
            adapter.packageId(),
            PackageId.arbitration(address(adapter), address(arbitrator), uint256(keccak256(extraData)))
        );
    }

    function test_onlyControllerOpens() public {
        vm.prank(provider);
        vm.expectRevert(KlerosAdapter.Unauthorized.selector);
        adapter.openCourt{value: COST}(DEAL, controller);

        vm.prank(controller);
        adapter.openCourt{value: COST}(DEAL, controller);
        assertTrue(adapter.opened(DEAL));
        assertEq(adapter.disputeOf(DEAL), 0);
        assertEq(address(arbitrator).balance, COST);
        assertEq(controller.balance, 1 ether - COST);
    }

    function test_insufficientFeeReverts() public {
        vm.prank(controller);
        vm.expectRevert(KlerosAdapter.InsufficientFee.selector);
        adapter.openCourt{value: COST - 1}(DEAL, controller);
    }

    function test_cannotOpenTwice() public {
        _open(DEAL);
        vm.prank(controller);
        vm.expectRevert(KlerosAdapter.AlreadyOpen.selector);
        adapter.openCourt{value: COST}(DEAL, controller);
    }

    function test_rulingMapsZeroToStalemate() public {
        _open(DEAL);
        arbitrator.giveRuling(0, 0);
        assertEq(uint8(adapter.readRuling(DEAL)), uint8(KlerosAdapter.Ruling.Stalemate));
    }

    function test_rulingMapsOneToHolderWin() public {
        _open(DEAL);
        arbitrator.giveRuling(0, 1);
        assertEq(uint8(adapter.readRuling(DEAL)), uint8(KlerosAdapter.Ruling.HolderWin));
    }

    function test_rulingMapsTwoToProviderWin() public {
        _open(DEAL);
        arbitrator.giveRuling(0, 2);
        assertEq(uint8(adapter.readRuling(DEAL)), uint8(KlerosAdapter.Ruling.ProviderWin));
    }

    function test_invalidRulingReverts() public {
        _open(DEAL);
        vm.expectRevert(KlerosAdapter.InvalidRuling.selector);
        arbitrator.giveRuling(0, 3);
    }

    function test_registersTemplateWhenRegistrySet() public {
        MockTemplateRegistry registry = new MockTemplateRegistry();
        KlerosAdapter wired =
            new KlerosAdapter(address(arbitrator), extraData, 99, "ipfs://ignore", address(0), address(registry));
        assertEq(wired.templateId(), 1);
        assertEq(wired.templateUri(), "");
        assertEq(registry.lastTag(), PluriSwapKlerosTemplate.tag());
        assertEq(registry.lastData(), PluriSwapKlerosTemplate.json());
        assertEq(registry.lastMappings(), PluriSwapKlerosTemplate.mappings());

        vm.prank(controller);
        vm.expectEmit(true, true, false, true, address(wired));
        emit IArbitrableV2.DisputeRequest(IArbitratorV2(address(arbitrator)), 0, uint256(DEAL), 1, "");
        wired.openCourt{value: COST}(DEAL, controller);
    }

    function test_onlyArbitratorRules() public {
        _open(DEAL);
        vm.prank(controller);
        vm.expectRevert(KlerosAdapter.Unauthorized.selector);
        adapter.rule(0, 1);
    }

    function test_cannotRuleTwice() public {
        _open(DEAL);
        arbitrator.giveRuling(0, 1);
        vm.expectRevert(KlerosAdapter.AlreadyRuled.selector);
        arbitrator.giveRuling(0, 2);
    }

    function test_ruleUnknownDisputeReverts() public {
        vm.expectRevert(MockArbitratorV2.UnknownDispute.selector);
        arbitrator.giveRuling(99, 1);
    }

    function _open(bytes32 dealId) internal {
        vm.prank(controller);
        adapter.openCourt{value: COST}(dealId, controller);
    }
}
