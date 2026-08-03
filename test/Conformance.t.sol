// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FeeOnTransferToken} from "./helpers/FeeOnTransferToken.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {RevertingReceiver} from "./helpers/RevertingReceiver.sol";
import {Coordinator} from "../src/Coordinator.sol";
import {CoreDeployer} from "../src/CoreDeployer.sol";
import {CoreEscrow} from "../src/CoreEscrow.sol";
import {CreditLedger} from "../src/CreditLedger.sol";
import {DealHashing} from "../src/libraries/DealHashing.sol";
import {
    DealTerms,
    DealState,
    FundingAuth,
    FundingPurpose,
    FundingSourceMode,
    FundingSpec,
    Outcome,
    PayoutResultCode,
    PositionKind,
    PositionPayoutAuth,
    PositionPayoutResult,
    ResolutionAction,
    ResolutionAuth,
    TerminalRecord
} from "../src/libraries/DealTypes.sol";
import {CoreDeploymentIntentOffchain} from "../src/libraries/ManifestTypes.sol";
import {
    ExactTransferFailed,
    InvalidState,
    ProfileNotSelected
} from "../src/libraries/CoreErrors.sol";

abstract contract ConformanceHarness is Test {
    CoreDeployer deployer;
    CoreEscrow escrow;
    CreditLedger ledger;
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
            1,
            2,
            keccak256("charter"),
            keccak256("tech"),
            address(this),
            address(this),
            CoreDeploymentIntentOffchain(
                bytes32(uint256(1)),
                bytes32(uint256(2)),
                bytes32(uint256(3)),
                bytes32(0),
                bytes32(uint256(5)),
                bytes32(uint256(6)),
                bytes32(uint256(7)),
                bytes32(uint256(8)),
                bytes32(uint256(9)),
                bytes32(0)
            )
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
        escrow = deployer.escrow();
        ledger = deployer.ledger();
        token = new MockERC20();
    }

    function _boundaryId() internal view returns (bytes32) {
        return DealHashing.custodyBoundaryId(ledger.chainId(), 2, address(ledger), address(token));
    }

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
        t.custodyBoundaryId = _boundaryId();
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
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, DealHashing.digest(domainSep, structHash));
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

    function _activate(uint256 principal, uint256 activationFee, uint256 completionFee)
        internal
        returns (bytes32)
    {
        return _activateWithNonce(principal, activationFee, completionFee, 1, 1, 2);
    }

    function _activateWithNonce(
        uint256 principal,
        uint256 activationFee,
        uint256 completionFee,
        uint256 termsNonce,
        uint256 principalFundingNonce,
        uint256 feeFundingNonce
    ) internal returns (bytes32 dealId) {
        ActivateParams memory p;
        p.terms = _terms(principal, activationFee, completionFee);
        p.terms.nonce = termsNonce;
        p.principalSpec = _fundingSpec(FundingPurpose.Principal, principal, holder);
        p.feeSpec = _fundingSpec(FundingPurpose.ActivationFee, activationFee, holder);

        bytes32 principalSpecHash = DealHashing.hashFundingSpec(p.principalSpec);
        bytes32 feeSpecHash = DealHashing.hashFundingSpec(p.feeSpec);
        p.terms.principalFundingHash = principalSpecHash;
        p.terms.activationFeeFundingHash = activationFee > 0 ? feeSpecHash : bytes32(0);

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
            termsHash, principalSpecHash, FundingPurpose.Principal, holder, principalFundingNonce
        );
        p.feeAuth = _fundingAuth(
            termsHash,
            activationFee > 0 ? feeSpecHash : bytes32(0),
            FundingPurpose.ActivationFee,
            holder,
            feeFundingNonce
        );
        p.principalSig = _sign(
            ledger.DOMAIN_SEPARATOR(), DealHashing.hashFundingAuth(p.principalAuth), holderPk
        );
        p.feeSig = activationFee > 0
            ? _sign(ledger.DOMAIN_SEPARATOR(), DealHashing.hashFundingAuth(p.feeAuth), holderPk)
            : new bytes(0);
        p.holderSig = _sign(escrow.DOMAIN_SEPARATOR(), termsHash, holderPk);
        p.providerSig = _sign(escrow.DOMAIN_SEPARATOR(), termsHash, providerPk);

        token.mint(holder, principal + activationFee);
        vm.prank(holder);
        token.approve(address(ledger), type(uint256).max);

        (dealId,) = escrow.activate(
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
}

/// @notice Named end-to-end evidence for the Mandatory Core release paths.
contract ConformanceTest is ConformanceHarness {
    function test_Conformance_ZeroFeeReleaseWithdraw() public {
        bytes32 dealId = _activate(100e18, 0, 0);

        vm.prank(provider);
        escrow.markFiatSent(dealId);
        vm.prank(holder);
        escrow.holderRelease(dealId);

        bytes32 terminalHash = escrow.getTerminalHash(dealId);
        bytes32 providerPosition = _terminalPosition(dealId, terminalHash, provider);
        PositionPayoutResult memory result =
            ledger.withdrawPosition(providerPosition, type(uint256).max);

        assertEq(result.code, PayoutResultCode.HealthyFull);
        assertEq(result.paidAmount, 100e18);
        assertTrue(ledger.positionConsumed(providerPosition));
        assertEq(token.balanceOf(provider), 100e18);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_Conformance_ActivationFeeNotRefundedOnCancel() public {
        bytes32 dealId = _activate(100e18, 7e18, 0);

        vm.prank(provider);
        escrow.providerCancel(dealId);

        bytes32 boundaryId = _boundaryId();
        bytes32 feePosition = DealHashing.positionId(
            boundaryId, PositionKind.ActivationFee, dealId, bytes32(0), feeRecipient
        );

        assertTrue(ledger.positionExists(feePosition));
        assertEq(ledger.positionNominal(feePosition), 7e18);
        assertFalse(ledger.positionConsumed(feePosition));
        assertEq(ledger.nominalOutstanding(address(token)), 107e18);
        assertEq(escrow.getTerminalRecord(dealId).holderSideReturn, 100e18);
    }

    function test_Conformance_FiatTimeoutThirdParty() public {
        bytes32 dealId = _activate(100e18, 0, 0);
        vm.warp(escrow.getDeal(dealId).fiatDeadline + 1);

        vm.prank(address(0xCAFE));
        escrow.fiatTimeoutCancel(dealId);

        assertEq(escrow.dealState(dealId), DealState.Cancelled);
        assertEq(escrow.getTerminalRecord(dealId).outcome, Outcome.FiatTimeoutCancel);
    }

    function test_Conformance_ClaimCollectsCompletionFee() public {
        bytes32 dealId = _activate(100e18, 0, 60e18);

        vm.prank(provider);
        escrow.markFiatSent(dealId);
        vm.warp(escrow.getDeal(dealId).releaseDeadline + 1);
        escrow.claim(dealId);

        TerminalRecord memory record = escrow.getTerminalRecord(dealId);
        assertEq(record.providerGross, 100e18);
        assertEq(record.completionCollected, 60e18);
        assertEq(record.providerNet, 40e18);

        bytes32 completionPosition =
            _terminalPosition(dealId, escrow.getTerminalHash(dealId), feeRecipient);
        assertTrue(ledger.positionExists(completionPosition));
        assertEq(ledger.positionNominal(completionPosition), 60e18);
    }

    function test_Conformance_DisputeTimeoutResidual() public {
        bytes32 dealId = _activate(100e18, 0, 0);

        vm.prank(provider);
        escrow.markFiatSent(dealId);
        vm.prank(holder);
        escrow.openDispute(dealId, "");
        vm.warp(escrow.getDeal(dealId).disputeDeadline + 1);
        escrow.disputeTimeout(dealId);

        TerminalRecord memory record = escrow.getTerminalRecord(dealId);
        assertEq(record.outcome, Outcome.DisputeTimeout);
        assertEq(record.providerGross, 50e18);
        assertEq(record.holderSideReturn, 50e18);
    }

    function test_Conformance_MutualCancelReleaseSplit() public {
        bytes32 cancelDeal = _activateWithNonce(100e18, 0, 0, 10, 11, 12);
        _mutualResolve(cancelDeal, ResolutionAction.MutualCancel, 1, 0);
        assertEq(escrow.dealState(cancelDeal), DealState.Cancelled);
        assertEq(escrow.getTerminalRecord(cancelDeal).outcome, Outcome.MutualCancel);

        bytes32 releaseDeal = _activateWithNonce(100e18, 0, 0, 20, 21, 22);
        vm.prank(provider);
        escrow.markFiatSent(releaseDeal);
        _mutualResolve(releaseDeal, ResolutionAction.CosignedRelease, 1, 10_000);
        assertEq(escrow.dealState(releaseDeal), DealState.Released);
        assertEq(escrow.getTerminalRecord(releaseDeal).outcome, Outcome.CosignedRelease);

        bytes32 splitDeal = _activateWithNonce(100e18, 0, 0, 30, 31, 32);
        vm.prank(provider);
        escrow.markFiatSent(splitDeal);
        _mutualResolve(splitDeal, ResolutionAction.Split, 1, 3_000);
        assertEq(escrow.dealState(splitDeal), DealState.ResolvedSplit);
        assertEq(escrow.getTerminalRecord(splitDeal).outcome, Outcome.MutualSplit);
    }

    function test_Conformance_DisputedBlocksClaimAndRelease() public {
        bytes32 dealId = _activate(100e18, 0, 0);

        vm.prank(provider);
        escrow.markFiatSent(dealId);
        vm.prank(holder);
        escrow.openDispute(dealId, "");
        vm.warp(escrow.getDeal(dealId).releaseDeadline + 1);

        vm.expectRevert(InvalidState.selector);
        escrow.claim(dealId);
        vm.expectRevert(InvalidState.selector);
        vm.prank(holder);
        escrow.holderRelease(dealId);

        assertEq(escrow.dealState(dealId), DealState.Disputed);
    }

    function test_Conformance_ExtensionStubsRevert() public {
        bytes32 dealId = _activate(100e18, 0, 0);

        vm.expectRevert(ProfileNotSelected.selector);
        escrow.submitPaymentProof(dealId, "");
        vm.expectRevert(ProfileNotSelected.selector);
        escrow.openArbitration(dealId, "");
        vm.expectRevert(ProfileNotSelected.selector);
        escrow.submitArbitrationRuling(dealId, "");
        vm.expectRevert(ProfileNotSelected.selector);
        escrow.arbitrationTimeout(dealId);
    }

    function test_Conformance_FeeOnTransferReject() public {
        FeeOnTransferToken feeToken = new FeeOnTransferToken();
        uint256 amount = 100e18;
        feeToken.mint(holder, amount);
        vm.prank(holder);
        feeToken.approve(address(ledger), type(uint256).max);

        FundingSpec memory principalSpec = FundingSpec({
            purpose: FundingPurpose.Principal,
            sourceMode: FundingSourceMode.WalletPull,
            token: address(feeToken),
            amount: amount,
            source: holder,
            sourcePositionId: bytes32(0),
            authority: holder
        });
        bytes32 termsHash = keccak256("fee-on-transfer-conformance");
        FundingAuth memory principalAuth = _fundingAuth(
            termsHash,
            DealHashing.hashFundingSpec(principalSpec),
            FundingPurpose.Principal,
            holder,
            100
        );
        bytes memory signature =
            _sign(ledger.DOMAIN_SEPARATOR(), DealHashing.hashFundingAuth(principalAuth), holderPk);

        vm.expectRevert(ExactTransferFailed.selector);
        vm.prank(address(escrow));
        ledger.fundDealAndReservations(
            termsHash,
            keccak256("fee-on-transfer-deal"),
            address(feeToken),
            amount,
            0,
            address(0),
            principalSpec,
            FundingSpec(0, 0, address(0), 0, address(0), bytes32(0), address(0)),
            principalAuth,
            FundingAuth(bytes32(0), bytes32(0), 0, address(0), 0, 0),
            signature,
            ""
        );

        assertEq(feeToken.balanceOf(holder), amount);
        assertEq(feeToken.balanceOf(address(ledger)), 0);
    }

    function test_Conformance_WithdrawRetryAfterReceiverRevert() public {
        bytes32 dealId = _activate(100e18, 0, 0);
        vm.prank(provider);
        escrow.markFiatSent(dealId);
        vm.prank(holder);
        escrow.holderRelease(dealId);

        bytes32 positionId = _terminalPosition(dealId, escrow.getTerminalHash(dealId), provider);
        RevertingReceiver receiver = new RevertingReceiver();
        token.setTransferRevert(address(receiver), true);
        assertTrue(token.transferReverts(address(receiver)));
        PositionPayoutAuth memory failedAuth = PositionPayoutAuth({
            action: 1,
            token: address(token),
            positionId: positionId,
            beneficiary: provider,
            to: address(receiver),
            maxAmount: type(uint256).max,
            nonce: 777,
            expiry: uint64(block.timestamp + 1 days)
        });

        bytes memory failedSignature = _signPayout(failedAuth, providerPk);
        vm.expectRevert();
        ledger.withdrawPositionTo(failedAuth, failedSignature);

        assertEq(ledger.positionNominal(positionId), 100e18);
        assertFalse(ledger.positionConsumed(positionId));

        failedAuth.to = address(0x2222);
        PositionPayoutResult memory result =
            ledger.withdrawPositionTo(failedAuth, _signPayout(failedAuth, providerPk));
        assertEq(result.code, PayoutResultCode.HealthyFull);
        assertEq(result.paidAmount, 100e18);
        assertTrue(ledger.positionConsumed(positionId));
    }

    function test_Conformance_ReplayAcrossDomainFails() public view {
        bytes32 structHash = keccak256("domain-separated-action");
        bytes32 ledgerDigest = DealHashing.digest(ledger.DOMAIN_SEPARATOR(), structHash);
        bytes32 escrowDigest = DealHashing.digest(escrow.DOMAIN_SEPARATOR(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(holderPk, escrowDigest);

        assertTrue(ecrecover(ledgerDigest, v, r, s) != holder);
    }

    function test_Conformance_ResidualExtremes() public {
        bytes32 dealId = _activate(1, 0, 1);

        vm.prank(provider);
        escrow.markFiatSent(dealId);
        vm.prank(holder);
        escrow.holderRelease(dealId);

        TerminalRecord memory record = escrow.getTerminalRecord(dealId);
        assertEq(record.holderSideReturn, 0);
        assertEq(record.providerGross, 1);
        assertEq(record.completionCollected, 1);
        assertEq(record.providerNet, 0);
    }

    function test_Conformance_SplitDustToHolder() public {
        bytes32 dealId = _activate(1, 0, 0);
        vm.prank(provider);
        escrow.markFiatSent(dealId);

        _mutualResolve(dealId, ResolutionAction.Split, 1, 5_000);
        TerminalRecord memory record = escrow.getTerminalRecord(dealId);

        assertEq(record.providerGross, 0);
        assertEq(record.holderSideReturn, 1);
        assertEq(escrow.dealState(dealId), DealState.ResolvedSplit);
    }

    function _terminalPosition(bytes32 dealId, bytes32 terminalHash, address beneficiary)
        internal
        view
        returns (bytes32)
    {
        bytes32 boundaryId = _boundaryId();
        return DealHashing.positionId(
            boundaryId, PositionKind.DealTerminal, dealId, terminalHash, beneficiary
        );
    }

    function _mutualResolve(
        bytes32 dealId,
        ResolutionAction action,
        uint256 nonce,
        uint16 providerBps
    ) internal {
        ResolutionAuth memory auth = _resolutionAuth(dealId, action, nonce, providerBps);
        bytes32 hash = DealHashing.hashResolution(auth);
        escrow.mutualResolve(
            dealId,
            auth,
            _sign(escrow.DOMAIN_SEPARATOR(), hash, holderPk),
            _sign(escrow.DOMAIN_SEPARATOR(), hash, providerPk)
        );
    }

    function _signPayout(PositionPayoutAuth memory auth, uint256 signerPk)
        internal
        view
        returns (bytes memory)
    {
        bytes32 typeHash = keccak256(
            "PositionPayoutAuth(uint8 action,address token,bytes32 positionId,address beneficiary,address to,uint256 maxAmount,uint256 nonce,uint64 expiry)"
        );
        bytes32 structHash = keccak256(
            abi.encode(
                typeHash,
                auth.action,
                auth.token,
                auth.positionId,
                auth.beneficiary,
                auth.to,
                auth.maxAmount,
                auth.nonce,
                auth.expiry
            )
        );
        return _sign(ledger.DOMAIN_SEPARATOR(), structHash, signerPk);
    }
}
