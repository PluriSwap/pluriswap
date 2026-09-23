// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {KlerosAdapter} from "../src/packages/KlerosAdapter.sol";
import {PackageId} from "../src/libraries/PackageId.sol";
import {PluriSwapKlerosTemplate} from "../src/packages/PluriSwapKlerosTemplate.sol";
import {IArbitrableV2, IArbitratorV2} from "../src/packages/interfaces/IKlerosV2.sol";
import {MockArbitratorV2} from "../mocks/MockArbitratorV2.sol";
import {MockTemplateRegistry} from "../mocks/MockTemplateRegistry.sol";
import {DealTerms} from "../src/libraries/Types.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @dev Minimal kernel: exposes `terms` and opens as `msg.sender == kernel`.
contract KernelStub {
    mapping(bytes32 => DealTerms) internal t;

    function set(bytes32 dealId, address holder, address provider, address token, uint256 principal) external {
        DealTerms storage d = t[dealId];
        d.holder = holder;
        d.provider = provider;
        d.token = token;
        d.principal = principal;
    }

    function terms(bytes32 dealId) external view returns (DealTerms memory) {
        return t[dealId];
    }

    function open(KlerosAdapter adapter, bytes32 dealId, uint256 cost) external {
        adapter.openCourt{value: cost}(dealId, address(this));
    }
}

contract TokenStub {
    uint8 public decimals;
    string public symbol;

    constructor(uint8 decimals_, string memory symbol_) {
        decimals = decimals_;
        symbol = symbol_;
    }
}

contract KlerosAdapterTest is Test {
    uint256 internal constant COST = 0.01 ether;
    bytes32 internal constant DEAL = keccak256("deal-kleros");
    string internal constant POLICY = "/ipfs/QmPolicyCidForTests/KLEROS_POLICY.md";

    MockArbitratorV2 internal arbitrator;
    KlerosAdapter internal adapter;
    bytes internal extraData;
    address internal controller = address(0xC0);
    address internal provider = address(0xB0B);

    function setUp() public {
        extraData = abi.encode(uint256(1), uint256(3), uint256(1));
        arbitrator = new MockArbitratorV2(COST);
        adapter =
            new KlerosAdapter(address(arbitrator), extraData, 0, "", address(this), address(0), "", 0, address(0xFEE));
        vm.deal(address(this), 1 ether);
        vm.deal(controller, 1 ether);
        vm.deal(provider, 1 ether);
    }

    /// A court that prices a contest must name somewhere to send it. Otherwise `_pullFee` would
    /// `safeTransfer` to address(0), the ERC-20 reverts, and `openDisputed` -- a Core verb -- is
    /// bricked for every deal that signed this package. KERNEL-04 says a package may lose its fee,
    /// never hold a Core exit hostage, so this fails at deploy instead of at the fight. A free court
    /// (`contestFee == 0`) needs no recipient, and `Reputation` has always guarded the same way.
    function test_constructor_rejectsAPricedContestWithNoRecipient() public {
        vm.expectRevert(KlerosAdapter.ZeroAddress.selector);
        new KlerosAdapter(address(arbitrator), extraData, 0, "", address(this), address(0), "", 1, address(0));

        // Free is fine without one.
        KlerosAdapter free =
            new KlerosAdapter(address(arbitrator), extraData, 0, "", address(this), address(0), "", 0, address(0));
        assertEq(free.contestFee(), 0);
    }

    function test_packageId_klerosStable() public view {
        assertEq(
            adapter.packageId(), PackageId.kleros(address(adapter), address(arbitrator), extraData, 0, address(0xFEE))
        );
        assertEq(
            adapter.packageId(),
            PackageId.arbitration(
                address(adapter), address(arbitrator), uint256(keccak256(extraData)), 0, address(0xFEE)
            )
        );
    }

    function test_onlyKernelOpens() public {
        vm.prank(controller);
        vm.expectRevert(KlerosAdapter.Unauthorized.selector);
        adapter.openCourt{value: COST}(DEAL, controller);

        uint256 before = address(this).balance;
        adapter.openCourt{value: COST}(DEAL, controller);
        assertTrue(adapter.opened(DEAL));
        assertEq(adapter.disputeOf(DEAL), 0);
        assertEq(address(arbitrator).balance, COST);
        assertEq(address(this).balance, before - COST);
    }

    function test_constructor_requiresArbitratorAndKernel() public {
        vm.expectRevert(KlerosAdapter.ZeroAddress.selector);
        new KlerosAdapter(address(0), extraData, 0, "", address(this), address(0), "", 0, address(0xFEE));
        vm.expectRevert(KlerosAdapter.ZeroAddress.selector);
        new KlerosAdapter(address(arbitrator), extraData, 0, "", address(0), address(0), "", 0, address(0xFEE));
    }

    function test_insufficientFeeReverts() public {
        vm.expectRevert(KlerosAdapter.InsufficientFee.selector);
        adapter.openCourt{value: COST - 1}(DEAL, controller);
    }

    function test_cannotOpenTwice() public {
        _open(DEAL);
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
        KlerosAdapter wired = new KlerosAdapter(
            address(arbitrator),
            extraData,
            99,
            "ipfs://ignore",
            address(this),
            address(registry),
            POLICY,
            0,
            address(0xFEE)
        );
        assertEq(wired.templateId(), 1);
        assertEq(wired.templateUri(), "");
        assertEq(wired.policyUri(), POLICY);
        assertEq(registry.lastTag(), PluriSwapKlerosTemplate.tag());
        assertEq(registry.lastData(), PluriSwapKlerosTemplate.json(block.chainid, address(arbitrator), POLICY));
        assertEq(registry.lastData(), wired.templateData());
        assertEq(registry.lastMappings(), PluriSwapKlerosTemplate.mappings());

        // Both DisputeRequest shapes: legacy (live subgraph, keyed by externalDisputeID) and dev (3-arg).
        vm.expectEmit(true, true, false, true, address(wired));
        emit IArbitrableV2.DisputeRequest(IArbitratorV2(address(arbitrator)), 0, uint256(DEAL), 1, "");
        vm.expectEmit(true, true, false, true, address(wired));
        emit IArbitrableV2.DisputeRequest(IArbitratorV2(address(arbitrator)), 0, 1);
        wired.openCourt{value: COST}(DEAL, controller);
    }

    /// @dev The Court UI validates the rendered template against the KIP-99 `DisputeDetails` schema: must be
    ///      JSON, carry `policyURI`, and point at the arbitrator of this chain. Placeholders stay literal here.
    function test_templateIsValidDisputeDetails() public {
        KlerosAdapter wired = new KlerosAdapter(
            address(arbitrator),
            extraData,
            0,
            "",
            address(this),
            address(new MockTemplateRegistry()),
            POLICY,
            0,
            address(0xFEE)
        );
        string memory json = wired.templateData();
        assertEq(vm.parseJsonString(json, ".policyURI"), POLICY);
        assertEq(vm.parseJsonString(json, ".arbitratorChainID"), vm.toString(block.chainid));
        assertEq(vm.parseJsonAddress(json, ".arbitratorAddress"), address(arbitrator));
        assertEq(vm.parseJsonString(json, ".version"), "1.0");
        assertEq(vm.parseJsonString(json, ".answers[0].id"), "0x00");
        assertEq(vm.parseJsonString(json, ".answers[1].title"), "Holder");
        assertEq(vm.parseJsonString(json, ".answers[2].title"), "Provider");
        assertEq(vm.parseJsonString(json, ".aliases.Holder"), "{{holder}}");
        assertEq(vm.parseJsonString(json, ".metadata.dealId"), "{{dealId}}");

        string memory mappings = wired.templateMappings();
        assertEq(vm.parseJsonString(mappings, "[0].type"), "abi/call");
        assertEq(vm.parseJsonString(mappings, "[0].functionName"), "caseOf");
        assertEq(vm.parseJsonString(mappings, "[0].address"), "{{arbitrableAddress}}");
        assertEq(vm.parseJsonString(mappings, "[0].args[0]"), "{{externalDisputeID}}");
        string[] memory populate = vm.parseJsonStringArray(mappings, "[0].populate");
        assertEq(populate.length, 5);
        assertEq(populate[0], "dealId");
        assertEq(populate[4], "amount");
    }

    function test_templateIdentityChangesWithChainAndArbitrator() public {
        string memory here = PluriSwapKlerosTemplate.json(block.chainid, address(arbitrator), POLICY);
        string memory mainnet = PluriSwapKlerosTemplate.json(42161, address(arbitrator), POLICY);
        string memory other = PluriSwapKlerosTemplate.json(block.chainid, address(0xABCD), POLICY);
        assertNotEq(keccak256(bytes(here)), keccak256(bytes(mainnet)));
        assertNotEq(keccak256(bytes(here)), keccak256(bytes(other)));
        assertEq(vm.parseJsonString(mainnet, ".arbitratorChainID"), "42161");
    }

    function test_caseOf_readsKernelTermsAndFormatsAmount() public {
        KernelStub k = new KernelStub();
        KlerosAdapter wired =
            new KlerosAdapter(address(arbitrator), extraData, 0, "", address(k), address(0), POLICY, 0, address(0xFEE));
        TokenStub usdc = new TokenStub(6, "USDC");
        k.set(DEAL, address(0xA11CE), address(0xB0B), address(usdc), 1_250_500_000);

        vm.expectRevert(KlerosAdapter.UnknownCase.selector);
        wired.caseOf(uint256(DEAL));

        vm.deal(address(k), 1 ether);
        k.open(wired, DEAL, COST);

        (bytes32 dealId, address holder_, address provider_, address token_, string memory amount) =
            wired.caseOf(uint256(DEAL));
        assertEq(dealId, DEAL);
        assertEq(holder_, address(0xA11CE));
        assertEq(provider_, address(0xB0B));
        assertEq(token_, address(usdc));
        assertEq(amount, "1250.5 USDC");
    }

    function test_caseOf_amountEdgeCases() public {
        KernelStub k = new KernelStub();
        KlerosAdapter wired =
            new KlerosAdapter(address(arbitrator), extraData, 0, "", address(k), address(0), POLICY, 0, address(0xFEE));
        vm.deal(address(k), 1 ether);

        TokenStub usdc = new TokenStub(6, "USDC");
        bytes32 d1 = keccak256("whole");
        k.set(d1, address(1), address(2), address(usdc), 1_000_000);
        k.open(wired, d1, COST);
        (,,,, string memory a1) = wired.caseOf(uint256(d1));
        assertEq(a1, "1 USDC");

        bytes32 d2 = keccak256("tiny");
        k.set(d2, address(1), address(2), address(usdc), 7);
        k.open(wired, d2, COST);
        (,,,, string memory a2) = wired.caseOf(uint256(d2));
        assertEq(a2, "0.000007 USDC");

        TokenStub weth = new TokenStub(18, "WETH");
        bytes32 d3 = keccak256("eth");
        k.set(d3, address(1), address(2), address(weth), 1.5 ether);
        k.open(wired, d3, COST);
        (,,,, string memory a3) = wired.caseOf(uint256(d3));
        assertEq(a3, "1.5 WETH");

        TokenStub zero = new TokenStub(0, "UNIT");
        bytes32 d4 = keccak256("zero");
        k.set(d4, address(1), address(2), address(zero), 42);
        k.open(wired, d4, COST);
        (,,,, string memory a4) = wired.caseOf(uint256(d4));
        assertEq(a4, "42 UNIT");

        bytes32 d5 = keccak256("nometa");
        address bare = address(0xBEEF);
        k.set(d5, address(1), address(2), bare, 99);
        k.open(wired, d5, COST);
        (,,,, string memory a5) = wired.caseOf(uint256(d5));
        assertEq(a5, string.concat("99 raw units of ", Strings.toHexString(bare)));
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
        adapter.openCourt{value: COST}(dealId, controller);
    }
}
