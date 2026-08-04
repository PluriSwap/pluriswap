// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {CoreDeployer} from "../src/CoreDeployer.sol";
import {CoreEscrow} from "../src/CoreEscrow.sol";
import {CreditLedger} from "../src/CreditLedger.sol";
import {Coordinator} from "../src/Coordinator.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {DealHashing} from "../src/libraries/DealHashing.sol";
import {TerminalPlanning} from "../src/libraries/TerminalPlanning.sol";
import {
    Deal,
    DealTerms,
    FundingSpec,
    FundingAuth,
    ResolutionAuth,
    ResolutionAction,
    TerminalRecord,
    TerminalAllocation,
    DealState,
    Outcome,
    ReconciliationStatus,
    FundingPurpose,
    FundingSourceMode,
    PositionKind,
    PositionPayoutResult,
    PayoutResultCode,
    TerminalPlanContext
} from "../src/libraries/DealTypes.sol";
import {CoreDeploymentIntentOffchain} from "../src/libraries/ManifestTypes.sol";

/// @notice End-to-end integration tests covering the full deal lifecycle:
///         deploy → activate → transition → settle → withdraw.
contract EndToEndTest is Test {
    CoreDeployer deployer;
    CoreEscrow escrow;
    CreditLedger ledger;
    Coordinator coordinator;
    MockERC20 token;

    uint256 holderPk = 0xA11CE;
    uint256 providerPk = 0xB0B;
    address holder;
    address provider;
    address feeRecipient = address(0xFEE);

    function setUp() public {
        holder = vm.addr(holderPk);
        provider = vm.addr(providerPk);

        deployer = new CoreDeployer(
            1, // DIRECT_CORE_DEPLOYER
            2, // protocolVersion
            keccak256("charter"),
            keccak256("tech"),
            address(this), // coordinatorOwner
            address(this), // deploymentOperator
            CoreDeploymentIntentOffchain({
                buildHash: bytes32(uint256(1)),
                plannedDeploymentMethodHash: bytes32(uint256(2)),
                coreDeployerCreationCodeHash: bytes32(uint256(3)),
                factoryCreationCodeHash: bytes32(0),
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
            abi.encode(address(deployer.escrow()), address(deployer.coordinator()), deployer.chainId())
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

        escrow = deployer.escrow();
        ledger = deployer.ledger();
        coordinator = deployer.coordinator();
        token = new MockERC20();
    }

    // ── Helpers ─────────────────────────────────────────────────────────────

    function _terms(uint256 principal, uint256 activationFee, uint256 completionFee)
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
        t.activationFeeRecipient = activationFee > 0 ? feeRecipient : address(0);
        t.completionFee = completionFee;
        t.completionFeeRecipient = completionFee > 0 ? feeRecipient : address(0);
        t.nonce = 1;
        t.createExpiry = uint64(block.timestamp + 1 days);
        t.fiatDuration = 1 hours;
        t.releaseDuration = 1 hours;
        t.disputeDuration = 1 hours;
        t.disputeTimeoutProviderBps = 5_000;
        t.fiatCurrency = keccak256("USD");
        t.fiatAmount = 1000e18;
        t.paymentMethod = keccak256("SEPA");
        t.payeeCommitment = bytes32(0);
        t.paymentReferenceCommitment = bytes32(0);
        t.profileFlags = 0;
        t.custodyBoundaryId = DealHashing.custodyBoundaryId(
            escrow.chainId(), escrow.protocolVersion(), address(ledger), address(token)
        );
    }

    function _fundingSpec(uint8 purpose, uint256 amount, address source)
        internal
        view
        returns (FundingSpec memory)
    {
        return FundingSpec({
            purpose: purpose,
            sourceMode: FundingSourceMode.WalletPull,
            token: address(token),
            amount: amount,
            source: source,
            sourcePositionId: bytes32(0),
            authority: source
        });
    }

    function _fundingAuth(
        bytes32 termsHash,
        bytes32 specHash,
        uint8 purpose,
        address authority,
        uint256 nonce
    ) internal view returns (FundingAuth memory) {
        return FundingAuth({
            termsHash: termsHash,
            fundingSpecHash: specHash,
            purpose: purpose,
            authority: authority,
            nonce: nonce,
            expiry: uint64(block.timestamp + 1 days)
        });
    }

    function _sign(bytes32 domainSep, bytes32 structHash, uint256 pk)
        internal
        pure
        returns (bytes memory)
    {
        bytes32 digest_ = DealHashing.digest(domainSep, structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest_);
        return abi.encodePacked(r, s, v);
    }

    struct ActivateParams {
        DealTerms terms;
        FundingSpec principalSpec;
        FundingSpec feeSpec;
        FundingAuth principalAuth;
        FundingAuth feeAuth;
        bytes principalSig;
        bytes feeSig;
        bytes holderSig;
        bytes providerSig;
    }

    function _prepareActivation(
        DealTerms memory terms,
        uint256 principalFundingNonce,
        uint256 feeFundingNonce
    ) internal view returns (ActivateParams memory p, bytes32 dealId) {
        p.terms = terms;
        p.principalSpec = _fundingSpec(FundingPurpose.Principal, terms.principal, terms.holder);
        p.feeSpec = _fundingSpec(FundingPurpose.ActivationFee, terms.activationFee, terms.holder);

        bytes32 principalSpecHash = DealHashing.hashFundingSpec(p.principalSpec);
        bytes32 feeSpecHash = DealHashing.hashFundingSpec(p.feeSpec);
        p.terms.principalFundingHash = principalSpecHash;
        p.terms.activationFeeFundingHash = terms.activationFee > 0 ? feeSpecHash : bytes32(0);

        bytes32 termsHash = DealHashing.hashDealTerms(p.terms);
        dealId = DealHashing.hashDealId(
            escrow.chainId(),
            escrow.protocolVersion(),
            address(escrow),
            termsHash,
            p.terms.holder,
            p.terms.provider,
            p.terms.nonce
        );

        p.principalAuth = _fundingAuth(
            termsHash, principalSpecHash, FundingPurpose.Principal, terms.holder, principalFundingNonce
        );
        p.feeAuth = _fundingAuth(
            termsHash,
            terms.activationFee > 0 ? feeSpecHash : bytes32(0),
            FundingPurpose.ActivationFee,
            terms.holder,
            feeFundingNonce
        );

        p.principalSig = _sign(
            ledger.DOMAIN_SEPARATOR(), DealHashing.hashFundingAuth(p.principalAuth), holderPk
        );
        p.feeSig = terms.activationFee > 0
            ? _sign(ledger.DOMAIN_SEPARATOR(), DealHashing.hashFundingAuth(p.feeAuth), holderPk)
            : new bytes(0);
        p.holderSig = _sign(escrow.DOMAIN_SEPARATOR(), termsHash, holderPk);
        p.providerSig = _sign(escrow.DOMAIN_SEPARATOR(), termsHash, providerPk);
    }

    function _activatePrepared(ActivateParams memory p)
        internal
        returns (bytes32 dealId, uint8 reconciliationStatus)
    {
        return escrow.activate(
            p.terms,
            p.principalSpec,
            p.feeSpec,
            p.principalAuth,
            p.feeAuth,
            p.principalSig,
            p.feeSig,
            p.holderSig,
            p.providerSig
        );
    }

    function _activate(uint256 principal, uint256 activationFee, uint256 completionFee)
        internal
        returns (bytes32 dealId)
    {
        DealTerms memory terms = _terms(principal, activationFee, completionFee);
        ActivateParams memory p;
        (p, dealId) = _prepareActivation(terms, 1, 1);
        token.mint(holder, principal + activationFee);
        vm.prank(holder);
        token.approve(address(ledger), type(uint256).max);
        (dealId,) = _activatePrepared(p);
    }

    function _resolutionAuth(bytes32 dealId, ResolutionAction action, uint256 nonce, uint16 bps)
        internal
        view
        returns (ResolutionAuth memory)
    {
        return ResolutionAuth({
            dealId: dealId,
            action: uint8(action),
            resolutionNonce: nonce,
            expiry: uint64(block.timestamp + 1 days),
            providerShareBps: bps,
            operatorFaultCode: 0,
            operatorFaultEvidenceHash: bytes32(0),
            reservationDispositionsHash: bytes32(0),
            extensionsHash: bytes32(0)
        });
    }

    function _dealPositionId(bytes32 dealId) internal view returns (bytes32) {
        return DealHashing.positionId(
            DealHashing.custodyBoundaryId(
                escrow.chainId(), escrow.protocolVersion(), address(ledger), address(token)
            ),
            PositionKind.ActiveDeal,
            dealId,
            bytes32(0),
            address(0)
        );
    }

    function _terminalPositionId(bytes32 dealId, bytes32 terminalHash, address beneficiary)
        internal
        view
        returns (bytes32)
    {
        return DealHashing.positionId(
            DealHashing.custodyBoundaryId(
                escrow.chainId(), escrow.protocolVersion(), address(ledger), address(token)
            ),
            PositionKind.DealTerminal,
            dealId,
            terminalHash,
            beneficiary
        );
    }

    function _computeTerminalHash(
        bytes32 dealId,
        uint8 terminalState,
        uint8 outcome,
        uint16 providerBps
    ) internal view returns (bytes32) {
        Deal memory d = escrow.getDeal(dealId);
        TerminalPlanContext memory ctx = TerminalPlanContext({
            token: d.token,
            principal: d.principal,
            completionFee: d.completionFee,
            holderReceiver: d.holderReceiver,
            providerReceiver: d.providerReceiver,
            completionFeeRecipient: d.completionFeeRecipient,
            termsHash: d.termsHash,
            modulesHash: d.modulesHash,
            custodyBoundaryId: d.custodyBoundaryId
        });
        (, bytes32 terminalHash,) = TerminalPlanning.plan(
            escrow.chainId(),
            escrow.protocolVersion(),
            address(escrow),
            address(ledger),
            dealId,
            ctx,
            terminalState,
            outcome,
            providerBps,
            bytes32(0),
            uint64(block.timestamp)
        );
        return terminalHash;
    }

    // ── Scenario 1: Happy path — voluntary release ───────────────────────────

    function test_E2E_HappyPath_VoluntaryRelease() public {
        uint256 principal = 1000e18;
        bytes32 dealId = _activate(principal, 0, 0);

        // Verify deal is Funded
        assertEq(escrow.dealState(dealId), DealState.Funded);
        assertEq(token.balanceOf(address(ledger)), principal);

        // Provider marks fiat sent
        vm.prank(provider);
        escrow.markFiatSent(dealId);
        assertEq(escrow.dealState(dealId), DealState.FiatSent);

        // Holder releases
        vm.prank(holder);
        uint8 status = escrow.holderRelease(dealId);
        assertEq(status, ReconciliationStatus.Unchanged);
        assertEq(escrow.dealState(dealId), DealState.Released);

        // Verify terminal record
        TerminalRecord memory tr = escrow.getTerminalRecord(dealId);
        assertEq(tr.principal, principal);
        assertEq(tr.providerGross, principal);
        assertEq(tr.providerNet, principal);
        assertEq(tr.holderSideReturn, 0);

        // Provider withdraws terminal position
        bytes32 terminalHash = escrow.getTerminalHash(dealId);
        bytes32 posId = _terminalPositionId(dealId, terminalHash, provider);
        assertTrue(ledger.positionExists(posId));
        assertEq(ledger.positionNominal(posId), principal);

        uint256 balBefore = token.balanceOf(provider);
        vm.prank(provider);
        PositionPayoutResult memory result = ledger.withdrawPosition(posId, type(uint256).max);
        assertEq(result.code, PayoutResultCode.HealthyFull);
        assertEq(result.paidAmount, principal);
        assertEq(token.balanceOf(provider), balBefore + principal);
        assertEq(token.balanceOf(address(ledger)), 0);
    }

    // ── Scenario 2: Fiat timeout cancel ──────────────────────────────────────

    function test_E2E_FiatTimeout_Cancel() public {
        uint256 principal = 500e18;
        bytes32 dealId = _activate(principal, 0, 0);

        // Warp past fiat deadline
        vm.warp(block.timestamp + 2 hours);

        // Anyone can cancel
        uint8 status = escrow.fiatTimeoutCancel(dealId);
        assertEq(status, ReconciliationStatus.Unchanged);
        assertEq(escrow.dealState(dealId), DealState.Cancelled);

        TerminalRecord memory tr = escrow.getTerminalRecord(dealId);
        assertEq(tr.outcome, Outcome.FiatTimeoutCancel);
        assertEq(tr.holderSideReturn, principal);
        assertEq(tr.providerGross, 0);

        // Holder withdraws full refund
        bytes32 terminalHash = escrow.getTerminalHash(dealId);
        bytes32 posId = _terminalPositionId(dealId, terminalHash, holder);
        assertEq(ledger.positionNominal(posId), principal);

        uint256 balBefore = token.balanceOf(holder);
        vm.prank(holder);
        PositionPayoutResult memory result = ledger.withdrawPosition(posId, type(uint256).max);
        assertEq(result.code, PayoutResultCode.HealthyFull);
        assertEq(token.balanceOf(holder), balBefore + principal);
    }

    // ── Scenario 3: Dispute timeout split ────────────────────────────────────

    function test_E2E_DisputeTimeout_Split() public {
        uint256 principal = 1000e18;
        bytes32 dealId = _activate(principal, 0, 0);

        // Provider marks fiat sent, holder disputes
        vm.prank(provider);
        escrow.markFiatSent(dealId);
        vm.prank(holder);
        escrow.openDispute(dealId, new bytes(0));
        assertEq(escrow.dealState(dealId), DealState.Disputed);

        // Warp past dispute deadline
        vm.warp(block.timestamp + 2 hours);

        // Permissionless dispute timeout
        uint8 status = escrow.disputeTimeout(dealId);
        assertEq(status, ReconciliationStatus.Unchanged);
        assertEq(escrow.dealState(dealId), DealState.ResolvedByDisputeTimeout);

        TerminalRecord memory tr = escrow.getTerminalRecord(dealId);
        assertEq(tr.outcome, Outcome.DisputeTimeout);

        // Read the actual BPS from the stored deal
        Deal memory d = escrow.getDeal(dealId);
        uint256 expectedProvider = (principal * d.disputeTimeoutProviderBps) / 10_000;
        uint256 expectedHolder = principal - expectedProvider;
        assertEq(tr.providerGross, expectedProvider);
        assertEq(tr.holderSideReturn, expectedHolder);

        // Both parties withdraw
        bytes32 terminalHash = escrow.getTerminalHash(dealId);

        bytes32 providerPos = _terminalPositionId(dealId, terminalHash, provider);
        bytes32 holderPos = _terminalPositionId(dealId, terminalHash, holder);

        assertEq(ledger.positionNominal(providerPos), expectedProvider);
        assertEq(ledger.positionNominal(holderPos), expectedHolder);

        uint256 providerBalBefore = token.balanceOf(provider);
        uint256 holderBalBefore = token.balanceOf(holder);

        vm.prank(provider);
        ledger.withdrawPosition(providerPos, type(uint256).max);
        vm.prank(holder);
        ledger.withdrawPosition(holderPos, type(uint256).max);

        assertEq(token.balanceOf(provider), providerBalBefore + expectedProvider);
        assertEq(token.balanceOf(holder), holderBalBefore + expectedHolder);
        assertEq(token.balanceOf(address(ledger)), 0);
    }

    // ── Scenario 4: Mutual resolve — cosigned release ────────────────────────

    function test_E2E_MutualResolve_CosignedRelease() public {
        uint256 principal = 800e18;
        bytes32 dealId = _activate(principal, 0, 0);

        vm.prank(provider);
        escrow.markFiatSent(dealId);

        // Dual-signed cosigned release
        ResolutionAuth memory auth =
            _resolutionAuth(dealId, ResolutionAction.CosignedRelease, 1, 10_000);
        bytes32 resHash = DealHashing.hashResolution(auth);
        bytes memory holderSig = _sign(escrow.DOMAIN_SEPARATOR(), resHash, holderPk);
        bytes memory providerSig = _sign(escrow.DOMAIN_SEPARATOR(), resHash, providerPk);

        uint8 status = escrow.mutualResolve(dealId, auth, holderSig, providerSig);
        assertEq(status, ReconciliationStatus.Unchanged);
        assertEq(escrow.dealState(dealId), DealState.Released);
        assertEq(escrow.getTerminalRecord(dealId).outcome, Outcome.CosignedRelease);

        // Nonce burned
        assertTrue(escrow.usedResolutionNonce(dealId, ResolutionAction.CosignedRelease, 1));

        // Provider withdraws
        bytes32 terminalHash = escrow.getTerminalHash(dealId);
        bytes32 posId = _terminalPositionId(dealId, terminalHash, provider);
        vm.prank(provider);
        PositionPayoutResult memory result = ledger.withdrawPosition(posId, type(uint256).max);
        assertEq(result.code, PayoutResultCode.HealthyFull);
        assertEq(result.paidAmount, principal);
    }

    // ── Scenario 5: Mutual resolve — split ───────────────────────────────────

    function test_E2E_MutualResolve_Split() public {
        uint256 principal = 1000e18;
        uint16 providerBps = 3_000; // 30% provider, 70% holder
        bytes32 dealId = _activate(principal, 0, 0);

        vm.prank(provider);
        escrow.markFiatSent(dealId);
        vm.prank(holder);
        escrow.openDispute(dealId, new bytes(0));

        // Dual-signed split
        ResolutionAuth memory auth = _resolutionAuth(dealId, ResolutionAction.Split, 1, providerBps);
        bytes32 resHash = DealHashing.hashResolution(auth);
        bytes memory holderSig = _sign(escrow.DOMAIN_SEPARATOR(), resHash, holderPk);
        bytes memory providerSig = _sign(escrow.DOMAIN_SEPARATOR(), resHash, providerPk);

        uint8 status = escrow.mutualResolve(dealId, auth, holderSig, providerSig);
        assertEq(status, ReconciliationStatus.Unchanged);
        assertEq(escrow.dealState(dealId), DealState.ResolvedSplit);
        assertEq(escrow.getTerminalRecord(dealId).outcome, Outcome.MutualSplit);

        // Verify split amounts
        uint256 expectedProvider = (principal * providerBps) / 10_000;
        uint256 expectedHolder = principal - expectedProvider;
        assertEq(escrow.getTerminalRecord(dealId).providerGross, expectedProvider);
        assertEq(escrow.getTerminalRecord(dealId).holderSideReturn, expectedHolder);

        // Withdraw both
        bytes32 terminalHash = escrow.getTerminalHash(dealId);
        bytes32 providerPos = _terminalPositionId(dealId, terminalHash, provider);
        bytes32 holderPos = _terminalPositionId(dealId, terminalHash, holder);

        vm.prank(provider);
        ledger.withdrawPosition(providerPos, type(uint256).max);
        vm.prank(holder);
        ledger.withdrawPosition(holderPos, type(uint256).max);

        assertEq(token.balanceOf(address(ledger)), 0);
    }

    // ── Scenario 6: Activation fee + completion fee ──────────────────────────

    function test_E2E_ActivationFee_And_CompletionFee() public {
        uint256 principal = 1000e18;
        uint256 activationFee = 50e18;
        uint256 completionFee = 100e18;
        bytes32 dealId = _activate(principal, activationFee, completionFee);

        // Verify activation fee position exists
        bytes32 feePosId = DealHashing.positionId(
            DealHashing.custodyBoundaryId(
                escrow.chainId(), escrow.protocolVersion(), address(ledger), address(token)
            ),
            PositionKind.ActivationFee,
            dealId,
            bytes32(0),
            feeRecipient
        );
        assertTrue(ledger.positionExists(feePosId));
        assertEq(ledger.positionNominal(feePosId), activationFee);

        // Complete the deal
        vm.prank(provider);
        escrow.markFiatSent(dealId);
        vm.prank(holder);
        escrow.holderRelease(dealId);

        // Verify terminal record with fees
        TerminalRecord memory tr = escrow.getTerminalRecord(dealId);
        assertEq(tr.principal, principal);
        assertEq(tr.providerGross, principal);
        assertEq(tr.completionCollected, completionFee);
        assertEq(tr.providerNet, principal - completionFee);
        assertEq(tr.holderSideReturn, 0);

        // All three positions created
        bytes32 terminalHash = escrow.getTerminalHash(dealId);
        bytes32 providerPos = _terminalPositionId(dealId, terminalHash, provider);
        bytes32 feePos = _terminalPositionId(dealId, terminalHash, feeRecipient);

        assertEq(ledger.positionNominal(providerPos), principal - completionFee);
        assertEq(ledger.positionNominal(feePos), completionFee);

        // Withdraw all
        uint256 providerBalBefore = token.balanceOf(provider);
        uint256 feeBalBefore = token.balanceOf(feeRecipient);

        vm.prank(provider);
        ledger.withdrawPosition(providerPos, type(uint256).max);
        vm.prank(feeRecipient);
        ledger.withdrawPosition(feePos, type(uint256).max);
        vm.prank(feeRecipient);
        ledger.withdrawPosition(feePosId, type(uint256).max);

        assertEq(token.balanceOf(provider), providerBalBefore + principal - completionFee);
        assertEq(token.balanceOf(feeRecipient), feeBalBefore + completionFee + activationFee);
        assertEq(token.balanceOf(address(ledger)), 0);
    }
}
