// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CoreDeployer} from "../src/CoreDeployer.sol";
import {CoreEscrow} from "../src/CoreEscrow.sol";
import {CreditLedger} from "../src/CreditLedger.sol";
import {Coordinator} from "../src/Coordinator.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {DealHashing} from "../src/libraries/DealHashing.sol";
import {
    DealState,
    DealTerms,
    FundingAuth,
    FundingPurpose,
    FundingSourceMode,
    FundingSpec,
    Outcome
} from "../src/libraries/DealTypes.sol";
import {Expired, InvalidTiming} from "../src/libraries/CoreErrors.sol";
import {CoreDeploymentIntentOffchain} from "../src/libraries/ManifestTypes.sol";

/// @notice Exact deadline races at t-1, t, and t+1 for Core timing predicates.
contract DeadlineRacesTest is Test {
    uint256 internal constant HOLDER_PK = 0xA11CE;
    uint256 internal constant PROVIDER_PK = 0xB0B;

    CoreEscrow internal escrow;
    CreditLedger internal ledger;
    MockERC20 internal token;
    address internal holder;
    address internal provider;

    function setUp() public {
        holder = vm.addr(HOLDER_PK);
        provider = vm.addr(PROVIDER_PK);
        (, ledger, escrow) = _deploy();
        token = new MockERC20();
        vm.warp(1_700_000_000);
    }

    function test_createExpiry_raceAtMinusOneExactAndPlusOne() public {
        DealTerms memory terms = _terms(100e18, 0);
        terms.createExpiry = uint64(block.timestamp + 10);
        terms.nonce = 1;

        vm.warp(uint256(terms.createExpiry) - 1);
        (bytes32 dealId, uint8 status) = _activatePrepared(terms, 1, 2);
        assertTrue(dealId != bytes32(0));
        assertEq(status, 0);

        DealTerms memory atExact = _terms(100e18, 0);
        atExact.createExpiry = uint64(block.timestamp);
        atExact.nonce = 2;
        _mintAndApprove(atExact.principal);
        _expectActivateExpired(atExact, 3, 4);

        DealTerms memory afterExpiry = _terms(100e18, 0);
        afterExpiry.createExpiry = uint64(block.timestamp - 1);
        afterExpiry.nonce = 3;
        _mintAndApprove(afterExpiry.principal);
        _expectActivateExpired(afterExpiry, 5, 6);
    }

    function test_fiatTimeout_raceAtMinusOneExactAndPlusOne() public {
        bytes32 dealId = _activate(100e18, 0, 1, 1, 2);
        uint64 deadline = escrow.getDeal(dealId).fiatDeadline;

        vm.warp(uint256(deadline) - 1);
        vm.expectRevert(InvalidTiming.selector);
        escrow.fiatTimeoutCancel(dealId);
        assertEq(uint8(escrow.dealState(dealId)), DealState.Funded);

        vm.warp(deadline);
        escrow.fiatTimeoutCancel(dealId);
        assertEq(uint8(escrow.dealState(dealId)), DealState.Cancelled);
        assertEq(uint8(escrow.getDeal(dealId).outcome), Outcome.FiatTimeoutCancel);
    }

    function test_claim_raceAtMinusOneExactAndPlusOne() public {
        bytes32 dealId = _activate(100e18, 0, 1, 1, 2);
        vm.prank(provider);
        escrow.markFiatSent(dealId);
        uint64 deadline = escrow.getDeal(dealId).releaseDeadline;

        vm.warp(uint256(deadline) - 1);
        vm.expectRevert(InvalidTiming.selector);
        escrow.claim(dealId);
        assertEq(uint8(escrow.dealState(dealId)), DealState.FiatSent);

        vm.warp(deadline);
        escrow.claim(dealId);
        assertEq(uint8(escrow.dealState(dealId)), DealState.Released);
        assertEq(uint8(escrow.getDeal(dealId).outcome), Outcome.TimeoutClaim);
    }

    function test_openDispute_raceAtMinusOneExactAndPlusOne() public {
        bytes32 dealId = _activate(100e18, 0, 1, 1, 2);
        vm.prank(provider);
        escrow.markFiatSent(dealId);
        uint64 deadline = escrow.getDeal(dealId).releaseDeadline;

        vm.warp(uint256(deadline) - 1);
        vm.prank(holder);
        escrow.openDispute(dealId, "");
        assertEq(uint8(escrow.dealState(dealId)), DealState.Disputed);

        bytes32 second = _activate(100e18, 0, 2, 3, 4);
        vm.prank(provider);
        escrow.markFiatSent(second);
        deadline = escrow.getDeal(second).releaseDeadline;

        vm.warp(deadline);
        vm.expectRevert(InvalidTiming.selector);
        vm.prank(holder);
        escrow.openDispute(second, "");
        assertEq(uint8(escrow.dealState(second)), DealState.FiatSent);

        vm.warp(uint256(deadline) + 1);
        vm.expectRevert(InvalidTiming.selector);
        vm.prank(holder);
        escrow.openDispute(second, "");
    }

    function test_disputeTimeout_raceAtMinusOneExactAndPlusOne() public {
        bytes32 dealId = _activate(100e18, 0, 1, 1, 2);
        vm.prank(provider);
        escrow.markFiatSent(dealId);
        vm.prank(holder);
        escrow.openDispute(dealId, "");
        uint64 deadline = escrow.getDeal(dealId).disputeDeadline;

        vm.warp(uint256(deadline) - 1);
        vm.expectRevert(InvalidTiming.selector);
        escrow.disputeTimeout(dealId);
        assertEq(uint8(escrow.dealState(dealId)), DealState.Disputed);

        vm.warp(deadline);
        escrow.disputeTimeout(dealId);
        assertEq(uint8(escrow.dealState(dealId)), DealState.ResolvedByDisputeTimeout);
        assertEq(uint8(escrow.getDeal(dealId).outcome), Outcome.DisputeTimeout);
    }

    function _terms(uint256 principal, uint256 activationFee)
        internal
        view
        returns (DealTerms memory t)
    {
        t.holder = holder;
        t.provider = provider;
        t.holderReceiver = holder;
        t.providerReceiver = provider;
        t.token = address(token);
        t.principal = principal;
        t.activationFee = activationFee;
        t.activationFeeRecipient = address(0);
        t.completionFee = 0;
        t.completionFeeRecipient = address(0);
        t.nonce = 1;
        t.createExpiry = uint64(block.timestamp + 1 days);
        t.fiatDuration = 1 hours;
        t.releaseDuration = 1 hours;
        t.disputeDuration = 1 hours;
        t.disputeTimeoutProviderBps = 5_000;
        t.fiatCurrency = keccak256("USD");
        t.fiatAmount = 1000e18;
        t.paymentMethod = keccak256("SEPA");
        t.custodyBoundaryId =
            DealHashing.custodyBoundaryId(escrow.chainId(), 2, address(ledger), address(token));
    }

    function _activate(
        uint256 principal,
        uint256 activationFee,
        uint256 termsNonce,
        uint256 principalFundingNonce,
        uint256 feeFundingNonce
    ) internal returns (bytes32 dealId) {
        DealTerms memory terms = _terms(principal, activationFee);
        terms.nonce = termsNonce;
        (dealId,) = _activatePrepared(terms, principalFundingNonce, feeFundingNonce);
        assertTrue(dealId != bytes32(0));
    }

    function _mintAndApprove(uint256 amount) internal {
        token.mint(holder, amount);
        vm.prank(holder);
        token.approve(address(ledger), type(uint256).max);
    }

    function _activatePrepared(
        DealTerms memory terms,
        uint256 principalFundingNonce,
        uint256 feeFundingNonce
    ) internal returns (bytes32 dealId, uint8 status) {
        _mintAndApprove(terms.principal + terms.activationFee);
        return _activateOnly(terms, principalFundingNonce, feeFundingNonce);
    }

    function _activateOnly(
        DealTerms memory terms,
        uint256 principalFundingNonce,
        uint256 feeFundingNonce
    ) internal returns (bytes32 dealId, uint8 status) {
        (
            FundingSpec memory principalSpec,
            FundingSpec memory feeSpec,
            FundingAuth memory principalAuth,
            FundingAuth memory feeAuth,
            bytes memory principalSig,
            bytes memory holderSig,
            bytes memory providerSig
        ) = _activationArgs(terms, principalFundingNonce, feeFundingNonce);

        return escrow.activate(
            terms,
            principalSpec,
            feeSpec,
            principalAuth,
            feeAuth,
            principalSig,
            new bytes(0),
            holderSig,
            providerSig
        );
    }

    function _expectActivateExpired(
        DealTerms memory terms,
        uint256 principalFundingNonce,
        uint256 feeFundingNonce
    ) internal {
        (
            FundingSpec memory principalSpec,
            FundingSpec memory feeSpec,
            FundingAuth memory principalAuth,
            FundingAuth memory feeAuth,
            bytes memory principalSig,
            bytes memory holderSig,
            bytes memory providerSig
        ) = _activationArgs(terms, principalFundingNonce, feeFundingNonce);

        vm.expectRevert(Expired.selector);
        escrow.activate(
            terms,
            principalSpec,
            feeSpec,
            principalAuth,
            feeAuth,
            principalSig,
            new bytes(0),
            holderSig,
            providerSig
        );
    }

    function _activationArgs(
        DealTerms memory terms,
        uint256 principalFundingNonce,
        uint256 feeFundingNonce
    )
        internal
        view
        returns (
            FundingSpec memory principalSpec,
            FundingSpec memory feeSpec,
            FundingAuth memory principalAuth,
            FundingAuth memory feeAuth,
            bytes memory principalSig,
            bytes memory holderSig,
            bytes memory providerSig
        )
    {
        principalSpec = FundingSpec({
            purpose: FundingPurpose.Principal,
            sourceMode: FundingSourceMode.WalletPull,
            token: address(token),
            amount: terms.principal,
            source: holder,
            sourcePositionId: bytes32(0),
            authority: holder
        });
        feeSpec = FundingSpec({
            purpose: FundingPurpose.ActivationFee,
            sourceMode: FundingSourceMode.WalletPull,
            token: address(token),
            amount: terms.activationFee,
            source: holder,
            sourcePositionId: bytes32(0),
            authority: holder
        });
        bytes32 principalSpecHash = DealHashing.hashFundingSpec(principalSpec);
        terms.principalFundingHash = principalSpecHash;
        terms.activationFeeFundingHash = bytes32(0);
        bytes32 termsHash = DealHashing.hashDealTerms(terms);
        principalAuth = FundingAuth({
            termsHash: termsHash,
            fundingSpecHash: principalSpecHash,
            purpose: FundingPurpose.Principal,
            authority: holder,
            nonce: principalFundingNonce,
            expiry: uint64(block.timestamp + 1 days)
        });
        feeAuth = FundingAuth({
            termsHash: termsHash,
            fundingSpecHash: bytes32(0),
            purpose: FundingPurpose.ActivationFee,
            authority: holder,
            nonce: feeFundingNonce,
            expiry: uint64(block.timestamp + 1 days)
        });

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(
            HOLDER_PK,
            DealHashing.digest(
                ledger.DOMAIN_SEPARATOR(), DealHashing.hashFundingAuth(principalAuth)
            )
        );
        (uint8 v2, bytes32 r2, bytes32 s2) =
            vm.sign(HOLDER_PK, DealHashing.digest(escrow.DOMAIN_SEPARATOR(), termsHash));
        (uint8 v3, bytes32 r3, bytes32 s3) =
            vm.sign(PROVIDER_PK, DealHashing.digest(escrow.DOMAIN_SEPARATOR(), termsHash));
        principalSig = abi.encodePacked(r1, s1, v1);
        holderSig = abi.encodePacked(r2, s2, v2);
        providerSig = abi.encodePacked(r3, s3, v3);
    }

    function _deploy()
        internal
        returns (CoreDeployer deployer, CreditLedger deployedLedger, CoreEscrow deployedEscrow)
    {
        deployer = new CoreDeployer(
            2,
            2,
            keccak256("charter"),
            keccak256("tech"),
            address(this),
            address(this),
            CoreDeploymentIntentOffchain({
                buildHash: bytes32(uint256(1)),
                plannedDeploymentMethodHash: bytes32(uint256(2)),
                coreDeployerCreationCodeHash: bytes32(uint256(3)),
                factoryCreationCodeHash: bytes32(uint256(4)),
                ledgerCreationCodeHash: bytes32(uint256(5)),
                coordinatorCreationCodeHash: bytes32(uint256(6)),
                escrowCreationCodeHash: bytes32(uint256(7)),
                capabilityHash: bytes32(uint256(8)),
                governanceHash: bytes32(uint256(9)),
                predecessorIntentHash: bytes32(0)
            })
        );
        bytes memory ledgerInitCode = abi.encodePacked(
            type(CreditLedger).creationCode,
            abi.encode(
                address(deployer.escrow()), address(deployer.coordinator()), deployer.chainId()
            )
        );
        bytes memory coordinatorInitCode = abi.encodePacked(
            type(Coordinator).creationCode,
            abi.encode(deployer.chainId(), address(deployer.escrow()), address(this))
        );
        bytes memory escrowInitCode = abi.encodePacked(
            type(CoreEscrow).creationCode,
            abi.encode(
                deployer.chainId(),
                deployer.protocolVersion(),
                deployer.charterHash(),
                deployer.techSpecHash(),
                address(deployer.ledger()),
                address(deployer.coordinator()),
                deployer.intentHash()
            )
        );
        deployer.deployTriad(ledgerInitCode, coordinatorInitCode, escrowInitCode);
        deployedLedger = deployer.ledger();
        deployedEscrow = deployer.escrow();
    }
}
