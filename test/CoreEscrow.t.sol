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
import {Overflow} from "../src/libraries/SettlementMath.sol";
import {
    DealTerms,
    FundingSpec,
    FundingAuth,
    ResolutionAuth,
    ResolutionAction,
    TerminalRecord,
    DealState,
    Outcome,
    ReconciliationStatus,
    FundingPurpose,
    FundingSourceMode,
    PositionKind,
    PositionPayoutResult,
    PayoutResultCode
} from "../src/libraries/DealTypes.sol";
import {ManifestHashing} from "../src/libraries/ManifestHashing.sol";
import {CoreDeploymentIntentOffchain} from "../src/libraries/ManifestTypes.sol";
import {
    InvalidState,
    InvalidTiming,
    Unauthorized,
    ProfileNotSelected,
    DealExists,
    Expired,
    InvalidBps,
    TerminalDeal,
    InvalidTerms,
    ZeroAddress,
    BoundaryNominalLimitExceeded
} from "../src/libraries/CoreErrors.sol";

error TokenTouched();

contract CoreEscrowTest is Test {
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

    // ── Helpers ─────────────────────────────────────────────────────────────────

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
        // All optional hash fields default to bytes32(0)
        t.custodyBoundaryId = DealHashing.custodyBoundaryId(
            escrow.chainId(), escrow.protocolVersion(), address(ledger), address(token)
        );
        // Funding hashes set in _activate
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
            termsHash,
            principalSpecHash,
            FundingPurpose.Principal,
            terms.holder,
            principalFundingNonce
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
        DealTerms memory terms = _terms(principal, activationFee, completionFee);
        terms.nonce = termsNonce;
        ActivateParams memory p;
        (p, dealId) = _prepareActivation(terms, principalFundingNonce, feeFundingNonce);

        // Mint and approve
        token.mint(holder, principal + activationFee);
        vm.prank(holder);
        token.approve(address(ledger), type(uint256).max);

        (dealId,) = _activatePrepared(p);
    }

    function _activateTerms(
        DealTerms memory terms,
        uint256 principalFundingNonce,
        uint256 feeFundingNonce
    ) internal returns (bytes32 dealId) {
        ActivateParams memory p;
        (p, dealId) = _prepareActivation(terms, principalFundingNonce, feeFundingNonce);
        token.mint(holder, terms.principal + terms.activationFee);
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

    function _assertSingleTerminalPositionCreated(
        bytes32 expectedPositionId,
        address expectedBeneficiary,
        uint256 expectedNominal
    ) internal view {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 eventSignature = keccak256("PositionCreated(bytes32,uint8,address,uint256)");
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter != address(ledger) || logs[i].topics.length == 0
                    || logs[i].topics[0] != eventSignature
            ) continue;

            ++count;
            assertEq(logs[i].topics.length, 3);
            assertEq(logs[i].topics[1], expectedPositionId);
            assertEq(address(uint160(uint256(logs[i].topics[2]))), expectedBeneficiary);
            (uint8 kind, uint256 nominal) = abi.decode(logs[i].data, (uint8, uint256));
            assertEq(kind, PositionKind.DealTerminal);
            assertEq(nominal, expectedNominal);
        }
        assertEq(count, 1);
    }

    // ── Tests ────────────────────────────────────────────────────────────────────

    function test_activate_createsDeal() public {
        bytes32 dealId = _activate(100e18, 0, 0);
        assertEq(uint8(escrow.dealState(dealId)), DealState.Funded);
        assertEq(escrow.getDeal(dealId).principal, 100e18);
        assertEq(escrow.getDeal(dealId).holder, holder);
        assertEq(escrow.getDeal(dealId).provider, provider);
    }

    function test_activate_withFees() public {
        bytes32 dealId = _activate(100e18, 5e18, 3e18);
        assertEq(uint8(escrow.dealState(dealId)), DealState.Funded);
        assertEq(escrow.getDeal(dealId).activationFee, 5e18);
        assertEq(escrow.getDeal(dealId).completionFee, 3e18);
    }

    function test_providerCancel_keepsActivationFeePosition() public {
        bytes32 dealId = _activate(100e18, 7e18, 0);

        vm.prank(provider);
        escrow.providerCancel(dealId);

        bytes32 feePositionId = DealHashing.positionId(
            escrow.getDeal(dealId).custodyBoundaryId,
            PositionKind.ActivationFee,
            dealId,
            bytes32(0),
            feeRecipient
        );
        assertTrue(ledger.positionExists(feePositionId));
        assertEq(ledger.positionNominal(feePositionId), 7e18);
        assertFalse(ledger.positionConsumed(feePositionId));
        assertEq(ledger.nominalOutstanding(address(token)), 107e18);
        assertEq(escrow.getTerminalRecord(dealId).holderSideReturn, 100e18);
    }

    function test_activate_rejectsZeroHolderReceiver() public {
        DealTerms memory terms = _terms(100e18, 0, 0);
        terms.holderReceiver = address(0);
        (ActivateParams memory p,) = _prepareActivation(terms, 1, 2);

        vm.expectRevert(ZeroAddress.selector);
        _activatePrepared(p);
    }

    function test_activate_rejectsZeroProviderReceiver() public {
        DealTerms memory terms = _terms(100e18, 0, 0);
        terms.providerReceiver = address(0);
        (ActivateParams memory p,) = _prepareActivation(terms, 1, 2);

        vm.expectRevert(ZeroAddress.selector);
        _activatePrepared(p);
    }

    function test_activate_zeroReceiverPrecedesInvalidCustodyBoundary() public {
        DealTerms memory terms = _terms(100e18, 0, 0);
        terms.holderReceiver = address(0);
        terms.custodyBoundaryId = bytes32(uint256(1));
        (ActivateParams memory p,) = _prepareActivation(terms, 1, 2);

        vm.expectRevert(ZeroAddress.selector);
        _activatePrepared(p);
    }

    function test_activate_rejectsEveryProtocolAddressForEveryReceiverRole() public {
        address[3] memory protocolReceivers;
        protocolReceivers[0] = address(ledger);
        protocolReceivers[1] = address(escrow);
        protocolReceivers[2] = address(deployer.coordinator());

        for (uint256 i; i < protocolReceivers.length; ++i) {
            DealTerms memory terms = _terms(100e18, 0, 0);
            terms.holderReceiver = protocolReceivers[i];
            _expectInvalidReceiver(terms, 10 + i * 10);

            terms = _terms(100e18, 0, 0);
            terms.providerReceiver = protocolReceivers[i];
            _expectInvalidReceiver(terms, 12 + i * 10);

            terms = _terms(100e18, 0, 0);
            terms.activationFeeRecipient = protocolReceivers[i];
            _expectInvalidReceiver(terms, 14 + i * 10);

            terms = _terms(100e18, 0, 0);
            terms.completionFeeRecipient = protocolReceivers[i];
            _expectInvalidReceiver(terms, 16 + i * 10);
        }
    }

    function test_activate_storesExactSignedReceiverValues() public {
        DealTerms memory terms = _terms(100e18, 5e18, 3e18);
        terms.holderReceiver = address(0xA11CE1);
        terms.providerReceiver = address(0xB0B1);
        terms.activationFeeRecipient = address(0xFEE1);
        terms.completionFeeRecipient = address(0xFEE2);
        (ActivateParams memory p, bytes32 dealId) = _prepareActivation(terms, 1, 2);

        token.mint(holder, terms.principal + terms.activationFee);
        vm.prank(holder);
        token.approve(address(ledger), type(uint256).max);
        _activatePrepared(p);

        assertEq(escrow.getDeal(dealId).holderReceiver, terms.holderReceiver);
        assertEq(escrow.getDeal(dealId).providerReceiver, terms.providerReceiver);
        assertEq(escrow.getDeal(dealId).activationFeeRecipient, terms.activationFeeRecipient);
        assertEq(escrow.getDeal(dealId).completionFeeRecipient, terms.completionFeeRecipient);
    }

    function test_activate_rejectsZeroActivationFeeRecipientForPositiveFee() public {
        DealTerms memory terms = _terms(100e18, 1, 0);
        terms.activationFeeRecipient = address(0);
        (ActivateParams memory p,) = _prepareActivation(terms, 1, 2);

        vm.expectRevert(ZeroAddress.selector);
        _activatePrepared(p);
    }

    function test_activate_rejectsZeroCompletionFeeRecipientForPositiveFee() public {
        DealTerms memory terms = _terms(100e18, 0, 1);
        terms.completionFeeRecipient = address(0);
        (ActivateParams memory p,) = _prepareActivation(terms, 1, 2);

        vm.expectRevert(ZeroAddress.selector);
        _activatePrepared(p);
    }

    function test_activate_allowsZeroFeeRecipientsForZeroFees() public {
        bytes32 dealId = _activate(100e18, 0, 0);

        assertEq(escrow.getDeal(dealId).activationFeeRecipient, address(0));
        assertEq(escrow.getDeal(dealId).completionFeeRecipient, address(0));
    }

    function test_activate_expiredPrecedesDeadlineOverflow() public {
        vm.warp(10);
        DealTerms memory terms = _terms(100e18, 0, 0);
        terms.createExpiry = uint64(block.timestamp);
        terms.fiatDuration = type(uint64).max;
        (ActivateParams memory p,) = _prepareActivation(terms, 1, 2);

        vm.expectRevert(Expired.selector);
        _activatePrepared(p);
    }

    function test_activate_fiatDeadlineOverflowPrecedesTokenPreflightAndLeavesNoEffects() public {
        vm.warp(10);
        uint64 activationTime = uint64(block.timestamp);
        DealTerms memory terms = _terms(100e18, 0, 0);
        terms.nonce = 41;
        terms.fiatDuration = type(uint64).max - activationTime + 1;
        (ActivateParams memory p, bytes32 dealId) = _prepareActivation(terms, 51, 52);
        bytes32 dealPositionId = DealHashing.positionId(
            terms.custodyBoundaryId, PositionKind.ActiveDeal, dealId, bytes32(0), address(0)
        );

        token.mint(holder, terms.principal);
        vm.prank(holder);
        token.approve(address(ledger), terms.principal);
        vm.mockCallRevert(
            address(token),
            abi.encodeWithSignature("balanceOf(address)", address(ledger)),
            abi.encodeWithSelector(TokenTouched.selector)
        );

        vm.expectRevert(Overflow.selector);
        _activatePrepared(p);
        vm.clearMockedCalls();

        _assertFailedActivationHasNoEffects(terms, dealId, dealPositionId);

        // Same nonces remain usable with freshly signed, representable terms. Do not warp
        // backward: overflow becomes more severe as time advances, so retry with valid durations.
        DealTerms memory retryTerms = _terms(100e18, 0, 0);
        retryTerms.nonce = terms.nonce;
        (ActivateParams memory retry, bytes32 retryDealId) = _prepareActivation(retryTerms, 51, 52);
        bytes32 retryPositionId = DealHashing.positionId(
            retryTerms.custodyBoundaryId,
            PositionKind.ActiveDeal,
            retryDealId,
            bytes32(0),
            address(0)
        );
        (bytes32 activatedDealId,) = _activatePrepared(retry);

        assertEq(activatedDealId, retryDealId);
        assertTrue(escrow.usedHolderNonce(holder, retryTerms.nonce));
        assertTrue(ledger.positionExists(retryPositionId));
        assertEq(uint8(escrow.dealState(retryDealId)), DealState.Funded);
    }

    function test_activate_immediateReleaseDisputeOverflowLeavesNoEffectsAndNoncesReusable()
        public
    {
        vm.warp(10);
        uint64 activationTime = uint64(block.timestamp);
        DealTerms memory terms = _terms(100e18, 0, 0);
        terms.nonce = 42;
        terms.fiatDuration = 1;
        terms.releaseDuration = type(uint64).max - activationTime;
        terms.disputeDuration = 1;
        (ActivateParams memory p, bytes32 dealId) = _prepareActivation(terms, 61, 62);
        bytes32 dealPositionId = DealHashing.positionId(
            terms.custodyBoundaryId, PositionKind.ActiveDeal, dealId, bytes32(0), address(0)
        );

        token.mint(holder, terms.principal);
        vm.prank(holder);
        token.approve(address(ledger), terms.principal);

        vm.expectRevert(Overflow.selector);
        _activatePrepared(p);

        _assertFailedActivationHasNoEffects(terms, dealId, dealPositionId);

        DealTerms memory retryTerms = _terms(100e18, 0, 0);
        retryTerms.nonce = terms.nonce;
        (ActivateParams memory retry, bytes32 retryDealId) = _prepareActivation(retryTerms, 61, 62);
        bytes32 retryPositionId = DealHashing.positionId(
            retryTerms.custodyBoundaryId,
            PositionKind.ActiveDeal,
            retryDealId,
            bytes32(0),
            address(0)
        );
        (bytes32 activatedDealId,) = _activatePrepared(retry);

        assertEq(activatedDealId, retryDealId);
        assertTrue(escrow.usedHolderNonce(holder, retryTerms.nonce));
        assertTrue(ledger.positionExists(retryPositionId));
        assertEq(uint8(escrow.dealState(retryDealId)), DealState.Funded);
    }

    function _expectInvalidReceiver(DealTerms memory terms, uint256 nonceBase) internal {
        (ActivateParams memory p,) = _prepareActivation(terms, nonceBase, nonceBase + 1);
        vm.expectRevert(InvalidTerms.selector);
        _activatePrepared(p);
    }

    function _assertFailedActivationHasNoEffects(
        DealTerms memory terms,
        bytes32 dealId,
        bytes32 dealPositionId
    ) internal view {
        assertEq(token.balanceOf(holder), terms.principal);
        assertEq(token.balanceOf(address(ledger)), 0);
        assertEq(token.allowance(holder, address(ledger)), terms.principal);
        assertEq(ledger.accountedAssets(address(token)), 0);
        assertEq(ledger.nominalOutstanding(address(token)), 0);
        assertFalse(ledger.positionExists(dealPositionId));
        assertFalse(escrow.usedHolderNonce(holder, terms.nonce));
        assertEq(uint8(escrow.dealState(dealId)), DealState.None);
    }

    function test_activate_boundaryAggregateLimitRollsBackAndKeepsAllNoncesReusable() public {
        uint256 maxNominal = ledger.MAX_BOUNDARY_NOMINAL();
        DealTerms memory rejectedTerms = _terms(maxNominal, 1, 0);
        rejectedTerms.nonce = 77;
        (ActivateParams memory rejected, bytes32 rejectedDealId) =
            _prepareActivation(rejectedTerms, 88, 89);
        bytes32 rejectedPositionId = DealHashing.positionId(
            rejectedTerms.custodyBoundaryId,
            PositionKind.ActiveDeal,
            rejectedDealId,
            bytes32(0),
            address(0)
        );
        token.mint(holder, maxNominal + 1);
        vm.prank(holder);
        token.approve(address(ledger), maxNominal + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                BoundaryNominalLimitExceeded.selector, 0, maxNominal + 1, maxNominal
            )
        );
        _activatePrepared(rejected);

        assertEq(token.balanceOf(holder), maxNominal + 1);
        assertEq(token.balanceOf(address(ledger)), 0);
        assertEq(token.allowance(holder, address(ledger)), maxNominal + 1);
        assertEq(ledger.nominalOutstanding(address(token)), 0);
        assertEq(ledger.accountedAssets(address(token)), 0);
        assertFalse(ledger.positionExists(rejectedPositionId));
        assertFalse(escrow.usedHolderNonce(holder, rejectedTerms.nonce));
        assertEq(uint8(escrow.dealState(rejectedDealId)), DealState.None);

        DealTerms memory retryTerms = _terms(1, 1, 0);
        retryTerms.nonce = rejectedTerms.nonce;
        (ActivateParams memory retry, bytes32 retryDealId) = _prepareActivation(retryTerms, 88, 89);
        (bytes32 activatedDealId,) = _activatePrepared(retry);

        assertEq(activatedDealId, retryDealId);
        assertTrue(escrow.usedHolderNonce(holder, retryTerms.nonce));
        assertEq(uint8(escrow.dealState(retryDealId)), DealState.Funded);
        assertEq(ledger.nominalOutstanding(address(token)), 2);
    }

    function test_activate_deficitReturnsStatusWithoutCreatingExposure() public {
        _activate(100e18, 0, 0);
        token.burn(address(ledger), 50e18);

        bytes32 result = _activateWithNonce(100e18, 0, 0, 2, 3, 4);
        assertEq(result, bytes32(0));
        assertFalse(escrow.usedHolderNonce(holder, 2));
        assertEq(ledger.nominalOutstanding(address(token)), 100e18);
        assertTrue(ledger.inDeficit(address(token)));
    }

    function test_mutualResolve_deficitDoesNotConsumeResolutionNonce() public {
        bytes32 dealId = _activate(100e18, 0, 0);
        bytes32 dealPositionId = DealHashing.positionId(
            escrow.getDeal(dealId).custodyBoundaryId,
            PositionKind.ActiveDeal,
            dealId,
            bytes32(0),
            address(0)
        );
        token.burn(address(ledger), 50e18);

        ResolutionAuth memory auth = _resolutionAuth(dealId, ResolutionAction.MutualCancel, 77, 0);
        bytes memory hSig =
            _sign(escrow.DOMAIN_SEPARATOR(), DealHashing.hashResolution(auth), holderPk);
        bytes memory pSig =
            _sign(escrow.DOMAIN_SEPARATOR(), DealHashing.hashResolution(auth), providerPk);

        uint8 status = escrow.mutualResolve(dealId, auth, hSig, pSig);

        assertEq(status, ReconciliationStatus.DeficitCheckpointed);
        assertEq(uint8(escrow.dealState(dealId)), DealState.Funded);
        assertFalse(escrow.usedResolutionNonce(dealId, ResolutionAction.MutualCancel, 77));
        assertEq(escrow.getTerminalHash(dealId), bytes32(0));
        assertEq(escrow.getTerminalRecord(dealId).evidenceHash, bytes32(0));
        assertFalse(ledger.positionConsumed(dealPositionId));
        assertEq(ledger.positionTerminalHash(dealPositionId), bytes32(0));
    }

    function test_activate_rejectsWrongCustodyBoundary() public {
        DealTerms memory t = _terms(100e18, 0, 0);
        t.nonce = 2;
        t.custodyBoundaryId = bytes32(uint256(1));

        FundingSpec memory principalSpec = _fundingSpec(FundingPurpose.Principal, 100e18, holder);
        FundingSpec memory feeSpec = _fundingSpec(FundingPurpose.ActivationFee, 0, holder);
        bytes32 principalSpecHash = DealHashing.hashFundingSpec(principalSpec);
        t.principalFundingHash = principalSpecHash;
        t.activationFeeFundingHash = bytes32(0);
        bytes32 termsHash = DealHashing.hashDealTerms(t);
        FundingAuth memory principalAuth =
            _fundingAuth(termsHash, principalSpecHash, FundingPurpose.Principal, holder, 10);
        FundingAuth memory feeAuth =
            _fundingAuth(termsHash, bytes32(0), FundingPurpose.ActivationFee, holder, 11);

        bytes memory principalSig =
            _sign(ledger.DOMAIN_SEPARATOR(), DealHashing.hashFundingAuth(principalAuth), holderPk);
        bytes memory holderSig = _sign(escrow.DOMAIN_SEPARATOR(), termsHash, holderPk);
        bytes memory providerSig = _sign(escrow.DOMAIN_SEPARATOR(), termsHash, providerPk);

        token.mint(holder, 100e18);
        vm.prank(holder);
        token.approve(address(ledger), type(uint256).max);

        vm.expectRevert(InvalidTerms.selector);
        escrow.activate(
            t,
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

    function test_activate_duplicateRejects() public {
        _activate(100e18, 0, 0);

        // Pre-mint and approve for second attempt
        token.mint(holder, 100e18);
        vm.prank(holder);
        token.approve(address(ledger), type(uint256).max);

        // Reconstruct same params (same dealId)
        DealTerms memory t = _terms(100e18, 0, 0);
        FundingSpec memory ps = _fundingSpec(FundingPurpose.Principal, 100e18, holder);
        bytes32 psh = DealHashing.hashFundingSpec(ps);
        t.principalFundingHash = psh;
        t.activationFeeFundingHash = bytes32(0);
        bytes32 termsHash = DealHashing.hashDealTerms(t);

        FundingAuth memory pa = _fundingAuth(termsHash, psh, FundingPurpose.Principal, holder, 1);
        FundingAuth memory fa =
            _fundingAuth(termsHash, bytes32(0), FundingPurpose.ActivationFee, holder, 2);
        bytes memory psig =
            _sign(ledger.DOMAIN_SEPARATOR(), DealHashing.hashFundingAuth(pa), holderPk);
        bytes memory hsig = _sign(escrow.DOMAIN_SEPARATOR(), termsHash, holderPk);
        bytes memory provSig = _sign(escrow.DOMAIN_SEPARATOR(), termsHash, providerPk);

        vm.expectRevert(DealExists.selector);
        escrow.activate(
            t,
            ps,
            _fundingSpec(FundingPurpose.ActivationFee, 0, holder),
            pa,
            fa,
            psig,
            new bytes(0),
            hsig,
            provSig
        );
    }

    function test_markFiatSent_transitionsToFiatSent() public {
        bytes32 dealId = _activate(100e18, 0, 0);
        vm.prank(provider);
        escrow.markFiatSent(dealId);
        assertEq(uint8(escrow.dealState(dealId)), DealState.FiatSent);
        assertGt(escrow.getDeal(dealId).releaseDeadline, 0);
    }

    function test_markFiatSent_nonProvider_reverts() public {
        bytes32 dealId = _activate(100e18, 0, 0);
        vm.expectRevert(Unauthorized.selector);
        escrow.markFiatSent(dealId);
    }

    function test_markFiatSent_wrongState_reverts() public {
        bytes32 dealId = _activate(100e18, 0, 0);
        vm.prank(provider);
        escrow.markFiatSent(dealId);
        vm.expectRevert(InvalidState.selector);
        vm.prank(provider);
        escrow.markFiatSent(dealId);
    }

    function test_markFiatSent_representableLateMarkOverflowPreservesFundedAndFiatTimeoutSucceeds()
        public
    {
        bytes32 dealId = _activate(100e18, 0, 0);
        uint64 lateMarkTime = type(uint64).max - escrow.getDeal(dealId).releaseDuration;
        vm.warp(lateMarkTime);
        assertLe(block.timestamp, type(uint64).max);
        assertGe(block.timestamp, escrow.getDeal(dealId).fiatDeadline);

        vm.expectRevert(Overflow.selector);
        vm.prank(provider);
        escrow.markFiatSent(dealId);

        assertEq(uint8(escrow.dealState(dealId)), DealState.Funded);
        assertEq(escrow.getDeal(dealId).releaseDeadline, 0);
        assertEq(block.timestamp, lateMarkTime);

        escrow.fiatTimeoutCancel(dealId);

        assertEq(uint8(escrow.dealState(dealId)), DealState.Cancelled);
        assertEq(uint8(escrow.getDeal(dealId).outcome), Outcome.FiatTimeoutCancel);
        assertEq(escrow.getTerminalRecord(dealId).holderSideReturn, 100e18);
        assertEq(block.timestamp, lateMarkTime);
    }

    function test_markFiatSent_releaseDeadlineOverflowPreservesFunded() public {
        bytes32 dealId = _activate(100e18, 0, 0);
        uint64 releaseDuration = escrow.getDeal(dealId).releaseDuration;
        vm.warp(type(uint64).max - releaseDuration + 1);

        vm.expectRevert(Overflow.selector);
        vm.prank(provider);
        escrow.markFiatSent(dealId);

        assertEq(uint8(escrow.dealState(dealId)), DealState.Funded);
        assertEq(escrow.getDeal(dealId).releaseDeadline, 0);
    }

    function test_markFiatSent_exactMaxDisputeHorizonSucceeds() public {
        bytes32 dealId = _activate(100e18, 0, 0);
        uint64 releaseDuration = escrow.getDeal(dealId).releaseDuration;
        uint64 disputeDuration = escrow.getDeal(dealId).disputeDuration;
        uint64 markTime = type(uint64).max - releaseDuration - disputeDuration;
        vm.warp(markTime);

        vm.prank(provider);
        escrow.markFiatSent(dealId);

        assertEq(uint8(escrow.dealState(dealId)), DealState.FiatSent);
        assertEq(escrow.getDeal(dealId).releaseDeadline, markTime + releaseDuration);
        assertEq(
            uint256(escrow.getDeal(dealId).releaseDeadline) + uint256(disputeDuration),
            uint256(type(uint64).max)
        );
    }

    function test_holderRelease_settlesToProvider() public {
        bytes32 dealId = _activate(100e18, 0, 0);
        vm.prank(provider);
        escrow.markFiatSent(dealId);

        vm.prank(holder);
        escrow.holderRelease(dealId);

        assertEq(uint8(escrow.dealState(dealId)), DealState.Released);
        assertEq(uint8(escrow.getDeal(dealId).outcome), Outcome.VoluntaryRelease);

        // Check terminal record
        TerminalRecord memory tr = escrow.getTerminalRecord(dealId);
        assertEq(tr.providerGross, 100e18);
        assertEq(tr.holderSideReturn, 0);
        assertEq(tr.providerNet, 100e18);
        assertEq(tr.completionCollected, 0);
        assertEq(tr.evidenceHash, bytes32(0));
    }

    function test_holderRelease_withCompletionFee() public {
        bytes32 dealId = _activate(100e18, 0, 10e18);
        vm.prank(provider);
        escrow.markFiatSent(dealId);

        vm.prank(holder);
        escrow.holderRelease(dealId);

        TerminalRecord memory tr = escrow.getTerminalRecord(dealId);
        assertEq(tr.providerGross, 100e18);
        assertEq(tr.evidenceHash, bytes32(0));
        assertEq(tr.completionCollected, 10e18);
        assertEq(tr.providerNet, 90e18);
    }

    function test_holderRelease_terminalPosition_withdrawsExactAmount() public {
        bytes32 dealId = _activate(100e18, 0, 0);
        vm.prank(provider);
        escrow.markFiatSent(dealId);
        vm.prank(holder);
        escrow.holderRelease(dealId);

        bytes32 positionId = DealHashing.positionId(
            escrow.getDeal(dealId).custodyBoundaryId,
            PositionKind.DealTerminal,
            dealId,
            escrow.getTerminalHash(dealId),
            provider
        );
        PositionPayoutResult memory result = ledger.withdrawPosition(positionId, type(uint256).max);

        assertEq(result.code, PayoutResultCode.HealthyFull);
        assertEq(result.paidAmount, 100e18);
        assertTrue(ledger.positionConsumed(positionId));
        assertEq(token.balanceOf(provider), 100e18);
        assertEq(token.balanceOf(address(ledger)), 0);
    }

    function test_holderRelease_minimumPrincipalCompletesFeeWithoutProviderPayout() public {
        bytes32 dealId = _activate(1, 0, 1);
        vm.prank(provider);
        escrow.markFiatSent(dealId);
        vm.prank(holder);
        escrow.holderRelease(dealId);

        TerminalRecord memory tr = escrow.getTerminalRecord(dealId);
        assertEq(tr.holderSideReturn, 0);
        assertEq(tr.providerGross, 1);
        assertEq(tr.completionCollected, 1);
        assertEq(tr.providerNet, 0);
    }

    function test_activate_rejectsCompletionFeeAbovePrincipal() public {
        DealTerms memory terms = _terms(100e18, 0, 100e18 + 1);
        (ActivateParams memory p,) = _prepareActivation(terms, 1, 2);

        vm.expectRevert(InvalidTerms.selector);
        _activatePrepared(p);
    }

    function test_holderRelease_nonHolder_reverts() public {
        bytes32 dealId = _activate(100e18, 0, 0);
        vm.prank(provider);
        escrow.markFiatSent(dealId);

        vm.expectRevert(Unauthorized.selector);
        escrow.holderRelease(dealId);
    }

    function test_claim_afterReleaseDeadline() public {
        bytes32 dealId = _activate(100e18, 0, 0);
        vm.prank(provider);
        escrow.markFiatSent(dealId);

        // Warp past release deadline
        vm.warp(escrow.getDeal(dealId).releaseDeadline + 1);

        // Anyone can claim
        escrow.claim(dealId);

        assertEq(uint8(escrow.dealState(dealId)), DealState.Released);
        assertEq(uint8(escrow.getDeal(dealId).outcome), Outcome.TimeoutClaim);

        TerminalRecord memory tr = escrow.getTerminalRecord(dealId);
        assertEq(tr.providerGross, 100e18);
        assertEq(tr.evidenceHash, bytes32(0));
    }

    function test_claim_withCompletionFee_createsCompletionPosition() public {
        bytes32 dealId = _activate(100e18, 0, 60e18);
        vm.prank(provider);
        escrow.markFiatSent(dealId);
        vm.warp(escrow.getDeal(dealId).releaseDeadline + 1);
        escrow.claim(dealId);

        TerminalRecord memory tr = escrow.getTerminalRecord(dealId);
        assertEq(tr.providerGross, 100e18);
        assertEq(tr.completionCollected, 60e18);
        assertEq(tr.providerNet, 40e18);

        bytes32 completionPositionId = DealHashing.positionId(
            escrow.getDeal(dealId).custodyBoundaryId,
            PositionKind.DealTerminal,
            dealId,
            escrow.getTerminalHash(dealId),
            feeRecipient
        );
        assertTrue(ledger.positionExists(completionPositionId));
        assertEq(ledger.positionNominal(completionPositionId), 60e18);
    }

    function test_claim_beforeReleaseDeadline_reverts() public {
        bytes32 dealId = _activate(100e18, 0, 0);
        vm.prank(provider);
        escrow.markFiatSent(dealId);

        vm.expectRevert(InvalidTiming.selector);
        escrow.claim(dealId);
    }

    function test_providerCancel_returnsToHolder() public {
        bytes32 dealId = _activate(100e18, 0, 0);

        vm.prank(provider);
        escrow.providerCancel(dealId);

        assertEq(uint8(escrow.dealState(dealId)), DealState.Cancelled);
        assertEq(uint8(escrow.getDeal(dealId).outcome), Outcome.ProviderCancel);

        TerminalRecord memory tr = escrow.getTerminalRecord(dealId);
        assertEq(tr.holderSideReturn, 100e18);
        assertEq(tr.providerGross, 0);
        assertEq(tr.evidenceHash, bytes32(0));
    }

    function test_providerCancel_timestampBeyondUint64HasNoEffects() public {
        bytes32 dealId = _activate(100e18, 0, 0);
        bytes32 dealPositionId = DealHashing.positionId(
            escrow.getDeal(dealId).custodyBoundaryId,
            PositionKind.ActiveDeal,
            dealId,
            bytes32(0),
            address(0)
        );
        vm.warp(uint256(type(uint64).max) + 1);

        vm.expectRevert(Overflow.selector);
        vm.prank(provider);
        escrow.providerCancel(dealId);

        assertEq(uint8(escrow.dealState(dealId)), DealState.Funded);
        assertEq(escrow.getTerminalHash(dealId), bytes32(0));
        assertEq(escrow.getTerminalRecord(dealId).terminatedAt, 0);
        assertFalse(ledger.positionConsumed(dealPositionId));
        assertEq(ledger.positionTerminalHash(dealPositionId), bytes32(0));
    }

    function test_fiatTimeoutCancel_timestampBeyondUint64HasNoEffects() public {
        bytes32 dealId = _activate(100e18, 0, 0);
        bytes32 dealPositionId = DealHashing.positionId(
            escrow.getDeal(dealId).custodyBoundaryId,
            PositionKind.ActiveDeal,
            dealId,
            bytes32(0),
            address(0)
        );
        vm.warp(uint256(type(uint64).max) + 1);

        vm.expectRevert(Overflow.selector);
        escrow.fiatTimeoutCancel(dealId);

        assertEq(uint8(escrow.dealState(dealId)), DealState.Funded);
        assertEq(escrow.getTerminalHash(dealId), bytes32(0));
        assertEq(escrow.getTerminalRecord(dealId).terminatedAt, 0);
        assertFalse(ledger.positionConsumed(dealPositionId));
        assertEq(ledger.positionTerminalHash(dealPositionId), bytes32(0));
    }

    function test_providerCancel_nonProvider_reverts() public {
        bytes32 dealId = _activate(100e18, 0, 0);
        vm.expectRevert(Unauthorized.selector);
        escrow.providerCancel(dealId);
    }

    function test_fiatTimeoutCancel_returnsToHolder() public {
        bytes32 dealId = _activate(100e18, 0, 0);

        // Warp past fiat deadline
        vm.warp(escrow.getDeal(dealId).fiatDeadline + 1);

        escrow.fiatTimeoutCancel(dealId);

        assertEq(uint8(escrow.dealState(dealId)), DealState.Cancelled);
        assertEq(uint8(escrow.getDeal(dealId).outcome), Outcome.FiatTimeoutCancel);

        TerminalRecord memory tr = escrow.getTerminalRecord(dealId);
        assertEq(tr.holderSideReturn, 100e18);
        assertEq(tr.evidenceHash, bytes32(0));
    }

    function test_fiatTimeoutCancel_isPermissionless() public {
        bytes32 dealId = _activate(100e18, 0, 0);
        vm.warp(escrow.getDeal(dealId).fiatDeadline + 1);

        vm.prank(address(0xCAFE));
        escrow.fiatTimeoutCancel(dealId);

        assertEq(uint8(escrow.dealState(dealId)), DealState.Cancelled);
        assertEq(uint8(escrow.getDeal(dealId).outcome), Outcome.FiatTimeoutCancel);
    }

    function test_fiatTimeoutCancel_beforeDeadline_reverts() public {
        bytes32 dealId = _activate(100e18, 0, 0);
        vm.expectRevert(InvalidTiming.selector);
        escrow.fiatTimeoutCancel(dealId);
    }

    function test_openDispute_entersDisputed() public {
        bytes32 dealId = _activate(100e18, 0, 0);
        vm.prank(provider);
        escrow.markFiatSent(dealId);

        vm.prank(holder);
        escrow.openDispute(dealId, "");

        assertEq(uint8(escrow.dealState(dealId)), DealState.Disputed);
        assertGt(escrow.getDeal(dealId).disputeDeadline, 0);
    }

    function test_openDispute_nonHolder_reverts() public {
        bytes32 dealId = _activate(100e18, 0, 0);
        vm.prank(provider);
        escrow.markFiatSent(dealId);

        vm.expectRevert(Unauthorized.selector);
        escrow.openDispute(dealId, "");
    }

    function test_openDispute_afterReleaseDeadline_reverts() public {
        bytes32 dealId = _activate(100e18, 0, 0);
        vm.prank(provider);
        escrow.markFiatSent(dealId);

        vm.warp(escrow.getDeal(dealId).releaseDeadline + 1);

        vm.expectRevert(InvalidTiming.selector);
        vm.prank(holder);
        escrow.openDispute(dealId, "");
    }

    function test_disputeTimeout_splitsByBps() public {
        bytes32 dealId = _activate(100e18, 0, 0);
        vm.prank(provider);
        escrow.markFiatSent(dealId);
        vm.prank(holder);
        escrow.openDispute(dealId, "");

        vm.warp(escrow.getDeal(dealId).disputeDeadline + 1);

        escrow.disputeTimeout(dealId);

        assertEq(uint8(escrow.dealState(dealId)), DealState.ResolvedByDisputeTimeout);
        assertEq(uint8(escrow.getDeal(dealId).outcome), Outcome.DisputeTimeout);

        TerminalRecord memory tr = escrow.getTerminalRecord(dealId);
        // 5_000 bps = 50%
        assertEq(tr.providerGross, 50e18);
        assertEq(tr.holderSideReturn, 50e18);
        assertEq(tr.evidenceHash, bytes32(0));
    }

    function test_mutualResolve_splitOddPrincipal_assignsDustToHolder() public {
        bytes32 dealId = _activate(1, 0, 0);
        vm.prank(provider);
        escrow.markFiatSent(dealId);

        ResolutionAuth memory auth = _resolutionAuth(dealId, ResolutionAction.Split, 1, 5_000);
        bytes memory holderSig =
            _sign(escrow.DOMAIN_SEPARATOR(), DealHashing.hashResolution(auth), holderPk);
        bytes memory providerSig =
            _sign(escrow.DOMAIN_SEPARATOR(), DealHashing.hashResolution(auth), providerPk);
        escrow.mutualResolve(dealId, auth, holderSig, providerSig);

        TerminalRecord memory tr = escrow.getTerminalRecord(dealId);
        assertEq(tr.providerGross, 0);
        assertEq(tr.holderSideReturn, 1);
        assertEq(uint8(escrow.dealState(dealId)), DealState.ResolvedSplit);
    }

    function test_disputeTimeout_beforeDeadline_reverts() public {
        bytes32 dealId = _activate(100e18, 0, 0);
        vm.prank(provider);
        escrow.markFiatSent(dealId);
        vm.prank(holder);
        escrow.openDispute(dealId, "");

        vm.expectRevert(InvalidTiming.selector);
        escrow.disputeTimeout(dealId);
    }

    function test_mutualResolve_cancel() public {
        bytes32 dealId = _activate(100e18, 0, 0);

        ResolutionAuth memory auth = _resolutionAuth(dealId, ResolutionAction.MutualCancel, 1, 0);
        bytes memory hSig =
            _sign(escrow.DOMAIN_SEPARATOR(), DealHashing.hashResolution(auth), holderPk);
        bytes memory pSig =
            _sign(escrow.DOMAIN_SEPARATOR(), DealHashing.hashResolution(auth), providerPk);

        escrow.mutualResolve(dealId, auth, hSig, pSig);

        assertEq(uint8(escrow.dealState(dealId)), DealState.Cancelled);
        assertEq(uint8(escrow.getDeal(dealId).outcome), Outcome.MutualCancel);

        TerminalRecord memory tr = escrow.getTerminalRecord(dealId);
        assertEq(tr.holderSideReturn, 100e18);
        assertEq(tr.providerGross, 0);
        bytes32 resolutionHash = DealHashing.hashResolution(auth);
        assertEq(tr.evidenceHash, resolutionHash);
        assertNotEq(resolutionHash, DealHashing.digest(escrow.DOMAIN_SEPARATOR(), resolutionHash));
        assertEq(escrow.getTerminalHash(dealId), DealHashing.hashTerminalRecord(tr));

        ResolutionAuth memory differentAuth = auth;
        differentAuth.resolutionNonce += 1;
        tr.evidenceHash = DealHashing.hashResolution(differentAuth);
        assertNotEq(escrow.getTerminalHash(dealId), DealHashing.hashTerminalRecord(tr));

        bytes32 dealPositionId = DealHashing.positionId(
            escrow.getDeal(dealId).custodyBoundaryId,
            PositionKind.ActiveDeal,
            dealId,
            bytes32(0),
            address(0)
        );
        assertEq(ledger.positionTerminalHash(dealPositionId), escrow.getTerminalHash(dealId));
    }

    function test_mutualResolve_cancelFromFiatSent() public {
        bytes32 dealId = _activate(100e18, 0, 0);
        vm.prank(provider);
        escrow.markFiatSent(dealId);

        ResolutionAuth memory auth = _resolutionAuth(dealId, ResolutionAction.MutualCancel, 1, 0);
        bytes memory hSig =
            _sign(escrow.DOMAIN_SEPARATOR(), DealHashing.hashResolution(auth), holderPk);
        bytes memory pSig =
            _sign(escrow.DOMAIN_SEPARATOR(), DealHashing.hashResolution(auth), providerPk);

        escrow.mutualResolve(dealId, auth, hSig, pSig);

        assertEq(uint8(escrow.dealState(dealId)), DealState.Cancelled);
    }

    function test_mutualResolve_cancelFromDisputed() public {
        bytes32 dealId = _activate(100e18, 0, 0);
        vm.prank(provider);
        escrow.markFiatSent(dealId);
        vm.prank(holder);
        escrow.openDispute(dealId, "");

        ResolutionAuth memory auth = _resolutionAuth(dealId, ResolutionAction.MutualCancel, 1, 0);
        bytes memory hSig =
            _sign(escrow.DOMAIN_SEPARATOR(), DealHashing.hashResolution(auth), holderPk);
        bytes memory pSig =
            _sign(escrow.DOMAIN_SEPARATOR(), DealHashing.hashResolution(auth), providerPk);

        escrow.mutualResolve(dealId, auth, hSig, pSig);

        assertEq(uint8(escrow.dealState(dealId)), DealState.Cancelled);
    }

    function test_mutualResolve_cosignedRelease() public {
        bytes32 dealId = _activate(100e18, 0, 0);
        vm.prank(provider);
        escrow.markFiatSent(dealId);

        ResolutionAuth memory auth =
            _resolutionAuth(dealId, ResolutionAction.CosignedRelease, 1, 10_000);
        bytes memory hSig =
            _sign(escrow.DOMAIN_SEPARATOR(), DealHashing.hashResolution(auth), holderPk);
        bytes memory pSig =
            _sign(escrow.DOMAIN_SEPARATOR(), DealHashing.hashResolution(auth), providerPk);

        escrow.mutualResolve(dealId, auth, hSig, pSig);

        assertEq(uint8(escrow.dealState(dealId)), DealState.Released);
        assertEq(uint8(escrow.getDeal(dealId).outcome), Outcome.CosignedRelease);

        TerminalRecord memory tr = escrow.getTerminalRecord(dealId);
        assertEq(tr.providerGross, 100e18);
        assertEq(tr.evidenceHash, DealHashing.hashResolution(auth));
    }

    function test_mutualResolve_cosignedReleaseFromDisputed() public {
        bytes32 dealId = _activate(100e18, 0, 0);
        vm.prank(provider);
        escrow.markFiatSent(dealId);
        vm.prank(holder);
        escrow.openDispute(dealId, "");

        ResolutionAuth memory auth =
            _resolutionAuth(dealId, ResolutionAction.CosignedRelease, 1, 10_000);
        bytes memory hSig =
            _sign(escrow.DOMAIN_SEPARATOR(), DealHashing.hashResolution(auth), holderPk);
        bytes memory pSig =
            _sign(escrow.DOMAIN_SEPARATOR(), DealHashing.hashResolution(auth), providerPk);

        escrow.mutualResolve(dealId, auth, hSig, pSig);

        assertEq(uint8(escrow.dealState(dealId)), DealState.Released);
    }

    function test_mutualResolve_split() public {
        bytes32 dealId = _activate(100e18, 0, 0);
        vm.prank(provider);
        escrow.markFiatSent(dealId);

        ResolutionAuth memory auth = _resolutionAuth(dealId, ResolutionAction.Split, 1, 3_000);
        bytes memory hSig =
            _sign(escrow.DOMAIN_SEPARATOR(), DealHashing.hashResolution(auth), holderPk);
        bytes memory pSig =
            _sign(escrow.DOMAIN_SEPARATOR(), DealHashing.hashResolution(auth), providerPk);

        escrow.mutualResolve(dealId, auth, hSig, pSig);

        assertEq(uint8(escrow.dealState(dealId)), DealState.ResolvedSplit);
        assertEq(uint8(escrow.getDeal(dealId).outcome), Outcome.MutualSplit);

        TerminalRecord memory tr = escrow.getTerminalRecord(dealId);
        assertEq(tr.providerGross, 30e18);
        assertEq(tr.holderSideReturn, 70e18);
        assertEq(tr.evidenceHash, DealHashing.hashResolution(auth));
    }

    function test_mutualResolve_splitCoalescesEqualBeneficiaryBeforeSettlement() public {
        address sharedReceiver = address(0xCAFE);
        DealTerms memory terms = _terms(100e18, 0, 0);
        terms.holderReceiver = sharedReceiver;
        terms.providerReceiver = sharedReceiver;
        bytes32 dealId = _activateTerms(terms, 1, 2);
        vm.prank(provider);
        escrow.markFiatSent(dealId);

        ResolutionAuth memory auth = _resolutionAuth(dealId, ResolutionAction.Split, 1, 3_000);
        bytes memory hSig =
            _sign(escrow.DOMAIN_SEPARATOR(), DealHashing.hashResolution(auth), holderPk);
        bytes memory pSig =
            _sign(escrow.DOMAIN_SEPARATOR(), DealHashing.hashResolution(auth), providerPk);

        vm.recordLogs();
        escrow.mutualResolve(dealId, auth, hSig, pSig);

        TerminalRecord memory tr = escrow.getTerminalRecord(dealId);
        assertEq(tr.holderSideReturn, 70e18);
        assertEq(tr.providerGross, 30e18);
        assertEq(tr.providerNet, 30e18);
        bytes32 terminalPositionId = DealHashing.positionId(
            escrow.getDeal(dealId).custodyBoundaryId,
            PositionKind.DealTerminal,
            dealId,
            escrow.getTerminalHash(dealId),
            sharedReceiver
        );
        _assertSingleTerminalPositionCreated(terminalPositionId, sharedReceiver, 100e18);
        assertEq(ledger.positionNominal(terminalPositionId), 100e18);
    }

    function test_holderRelease_coalescesProviderAndCompletionFeeRecipient() public {
        address sharedReceiver = address(0xBEEF);
        DealTerms memory terms = _terms(100e18, 0, 10e18);
        terms.providerReceiver = sharedReceiver;
        terms.completionFeeRecipient = sharedReceiver;
        bytes32 dealId = _activateTerms(terms, 1, 2);
        vm.prank(provider);
        escrow.markFiatSent(dealId);

        vm.recordLogs();
        vm.prank(holder);
        escrow.holderRelease(dealId);

        TerminalRecord memory tr = escrow.getTerminalRecord(dealId);
        assertEq(tr.providerGross, 100e18);
        assertEq(tr.providerNet, 90e18);
        assertEq(tr.completionCollected, 10e18);
        bytes32 terminalPositionId = DealHashing.positionId(
            escrow.getDeal(dealId).custodyBoundaryId,
            PositionKind.DealTerminal,
            dealId,
            escrow.getTerminalHash(dealId),
            sharedReceiver
        );
        _assertSingleTerminalPositionCreated(terminalPositionId, sharedReceiver, 100e18);
        assertEq(ledger.positionNominal(terminalPositionId), 100e18);
    }

    function test_mutualResolve_splitCoalescesInDeficitAndPreservesCheckpoint() public {
        address sharedReceiver = address(0xD3F1C17);
        DealTerms memory terms = _terms(100, 20, 0);
        terms.holderReceiver = sharedReceiver;
        terms.providerReceiver = sharedReceiver;
        bytes32 dealId = _activateTerms(terms, 1, 2);
        vm.prank(provider);
        escrow.markFiatSent(dealId);

        bytes32 activationFeePosition = DealHashing.positionId(
            escrow.getDeal(dealId).custodyBoundaryId,
            PositionKind.ActivationFee,
            dealId,
            bytes32(0),
            feeRecipient
        );
        token.burn(address(ledger), 60);
        assertEq(
            ledger.checkpointBoundary(address(token)), ReconciliationStatus.DeficitCheckpointed
        );
        ledger.claimRecovery(activationFeePosition, type(uint256).max);
        assertGt(ledger.deficitHistoryTotal(address(token)), 0);
        bytes32 checkpointBefore = ledger.boundaryCheckpointId(address(token));

        ResolutionAuth memory auth = _resolutionAuth(dealId, ResolutionAction.Split, 1, 3_000);
        bytes memory hSig =
            _sign(escrow.DOMAIN_SEPARATOR(), DealHashing.hashResolution(auth), holderPk);
        bytes memory pSig =
            _sign(escrow.DOMAIN_SEPARATOR(), DealHashing.hashResolution(auth), providerPk);

        vm.recordLogs();
        escrow.mutualResolve(dealId, auth, hSig, pSig);

        TerminalRecord memory tr = escrow.getTerminalRecord(dealId);
        assertEq(tr.holderSideReturn, 70);
        assertEq(tr.providerGross, 30);
        bytes32 terminalPositionId = DealHashing.positionId(
            escrow.getDeal(dealId).custodyBoundaryId,
            PositionKind.DealTerminal,
            dealId,
            escrow.getTerminalHash(dealId),
            sharedReceiver
        );
        _assertSingleTerminalPositionCreated(terminalPositionId, sharedReceiver, 100);
        assertEq(ledger.positionNominal(terminalPositionId), 100);
        assertEq(ledger.boundaryCheckpointId(address(token)), checkpointBefore);

        ledger.claimRecovery(terminalPositionId, type(uint256).max);
        assertEq(token.balanceOf(sharedReceiver), 50);
        assertEq(ledger.positionNominal(terminalPositionId), 100);
        assertEq(ledger.positionNominalRemaining(terminalPositionId), 50);
    }

    function test_mutualResolve_splitFromDisputed() public {
        bytes32 dealId = _activate(100e18, 0, 0);
        vm.prank(provider);
        escrow.markFiatSent(dealId);
        vm.prank(holder);
        escrow.openDispute(dealId, "");

        ResolutionAuth memory auth = _resolutionAuth(dealId, ResolutionAction.Split, 1, 4_000);
        bytes memory hSig =
            _sign(escrow.DOMAIN_SEPARATOR(), DealHashing.hashResolution(auth), holderPk);
        bytes memory pSig =
            _sign(escrow.DOMAIN_SEPARATOR(), DealHashing.hashResolution(auth), providerPk);

        escrow.mutualResolve(dealId, auth, hSig, pSig);

        assertEq(uint8(escrow.dealState(dealId)), DealState.ResolvedSplit);

        TerminalRecord memory tr = escrow.getTerminalRecord(dealId);
        assertEq(tr.providerGross, 40e18);
        assertEq(tr.holderSideReturn, 60e18);
    }

    function test_mutualResolve_cosignedRelease_fromFunded_reverts() public {
        bytes32 dealId = _activate(100e18, 0, 0);

        ResolutionAuth memory auth =
            _resolutionAuth(dealId, ResolutionAction.CosignedRelease, 1, 10_000);
        bytes memory hSig =
            _sign(escrow.DOMAIN_SEPARATOR(), DealHashing.hashResolution(auth), holderPk);
        bytes memory pSig =
            _sign(escrow.DOMAIN_SEPARATOR(), DealHashing.hashResolution(auth), providerPk);

        vm.expectRevert(InvalidState.selector);
        escrow.mutualResolve(dealId, auth, hSig, pSig);
    }

    function test_mutualResolve_split_fromFunded_reverts() public {
        bytes32 dealId = _activate(100e18, 0, 0);

        ResolutionAuth memory auth = _resolutionAuth(dealId, ResolutionAction.Split, 1, 5_000);
        bytes memory hSig =
            _sign(escrow.DOMAIN_SEPARATOR(), DealHashing.hashResolution(auth), holderPk);
        bytes memory pSig =
            _sign(escrow.DOMAIN_SEPARATOR(), DealHashing.hashResolution(auth), providerPk);

        vm.expectRevert(InvalidState.selector);
        escrow.mutualResolve(dealId, auth, hSig, pSig);
    }

    function test_mutualResolve_cancel_wrongBps_reverts() public {
        bytes32 dealId = _activate(100e18, 0, 0);

        ResolutionAuth memory auth =
            _resolutionAuth(dealId, ResolutionAction.MutualCancel, 1, 1_000);
        bytes memory hSig =
            _sign(escrow.DOMAIN_SEPARATOR(), DealHashing.hashResolution(auth), holderPk);
        bytes memory pSig =
            _sign(escrow.DOMAIN_SEPARATOR(), DealHashing.hashResolution(auth), providerPk);

        vm.expectRevert(InvalidBps.selector);
        escrow.mutualResolve(dealId, auth, hSig, pSig);
    }

    function test_mutualResolve_nonceReplay_reverts() public {
        bytes32 dealId = _activate(100e18, 0, 0);

        ResolutionAuth memory auth = _resolutionAuth(dealId, ResolutionAction.MutualCancel, 1, 0);
        bytes memory hSig =
            _sign(escrow.DOMAIN_SEPARATOR(), DealHashing.hashResolution(auth), holderPk);
        bytes memory pSig =
            _sign(escrow.DOMAIN_SEPARATOR(), DealHashing.hashResolution(auth), providerPk);

        escrow.mutualResolve(dealId, auth, hSig, pSig);

        // Replay same nonce - should fail (deal is terminal)
        vm.expectRevert(TerminalDeal.selector);
        escrow.mutualResolve(dealId, auth, hSig, pSig);
    }

    function test_terminalDeal_rejectsTransitions() public {
        bytes32 dealId = _activate(100e18, 0, 0);
        vm.prank(provider);
        escrow.providerCancel(dealId);

        // All transitions should reject
        vm.expectRevert(InvalidState.selector);
        vm.prank(provider);
        escrow.markFiatSent(dealId);

        vm.expectRevert(InvalidState.selector);
        escrow.fiatTimeoutCancel(dealId);
    }

    function test_extensionStubs_reject() public {
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

    function test_claim_unavailableFromDisputed() public {
        bytes32 dealId = _activate(100e18, 0, 0);
        vm.prank(provider);
        escrow.markFiatSent(dealId);
        vm.prank(holder);
        escrow.openDispute(dealId, "");

        vm.warp(escrow.getDeal(dealId).releaseDeadline + 1);

        // Claim from DISPUTED should reject (state != FiatSent)
        vm.expectRevert(InvalidState.selector);
        escrow.claim(dealId);
    }

    function test_holderRelease_unavailableFromDisputed() public {
        bytes32 dealId = _activate(100e18, 0, 0);
        vm.prank(provider);
        escrow.markFiatSent(dealId);
        vm.prank(holder);
        escrow.openDispute(dealId, "");

        // Holder release from DISPUTED should reject
        vm.expectRevert(InvalidState.selector);
        vm.prank(holder);
        escrow.holderRelease(dealId);
    }

    function test_disputeTimeout_capsValidCompletionFeeByProviderGrossEndToEnd() public {
        bytes32 dealId = _activate(100e18, 0, 80e18);
        vm.prank(provider);
        escrow.markFiatSent(dealId);
        vm.prank(holder);
        escrow.openDispute(dealId, "");

        vm.warp(escrow.getDeal(dealId).disputeDeadline + 1);

        escrow.disputeTimeout(dealId);

        TerminalRecord memory tr = escrow.getTerminalRecord(dealId);
        // 5_000 bps → providerGross = 50e18
        assertEq(tr.providerGross, 50e18);
        // completionCollected = min(80e18, 50e18) = 50e18
        assertEq(tr.completionCollected, 50e18);
        assertEq(tr.providerNet, 0);
        // holderSideReturn = 100e18 - 50e18 = 50e18
        assertEq(tr.holderSideReturn, 50e18);

        bytes32 feePositionId = DealHashing.positionId(
            escrow.getDeal(dealId).custodyBoundaryId,
            PositionKind.DealTerminal,
            dealId,
            escrow.getTerminalHash(dealId),
            feeRecipient
        );
        assertEq(ledger.positionNominal(feePositionId), 50e18);

        ledger.withdrawPosition(feePositionId, type(uint256).max);
        assertEq(token.balanceOf(feeRecipient), 50e18);
    }

    function test_disputeTimeout_completionFeeEqualPrincipalIsAcceptedAndCapped() public {
        bytes32 dealId = _activate(100e18, 0, 100e18);
        vm.prank(provider);
        escrow.markFiatSent(dealId);
        vm.prank(holder);
        escrow.openDispute(dealId, "");
        vm.warp(escrow.getDeal(dealId).disputeDeadline + 1);

        escrow.disputeTimeout(dealId);

        TerminalRecord memory tr = escrow.getTerminalRecord(dealId);
        assertEq(tr.providerGross, 50e18);
        assertEq(tr.completionCollected, 50e18);
        assertEq(tr.providerNet, 0);
        assertEq(tr.holderSideReturn, 50e18);
    }

    function test_terminalHash_nonZero() public {
        bytes32 dealId = _activate(100e18, 0, 0);
        vm.prank(provider);
        escrow.providerCancel(dealId);

        bytes32 th = escrow.getTerminalHash(dealId);
        assertTrue(th != bytes32(0));
        assertEq(th, DealHashing.hashTerminalRecord(escrow.getTerminalRecord(dealId)));
    }

    // ── Manifest tests ──────────────────────────────────────────────────────────

    function test_intentHash_nonZero() public {
        assertTrue(deployer.intentHash() != bytes32(0));
    }

    function test_intentHash_matchesEscrow() public {
        assertEq(deployer.intentHash(), escrow.intentHash());
    }

    function test_intentHash_deterministic() public {
        // Compute expected manifest hash from known addresses
        address deployerAddr = address(deployer);
        address ledgerAddr = address(ledger);
        address coordinatorAddr = address(deployer.coordinator());
        address escrowAddr = address(escrow);
        CoreDeploymentIntentOffchain memory off = CoreDeploymentIntentOffchain({
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
        });
        bytes32 expected = ManifestHashing.hashDeploymentIntent(
            uint64(block.chainid),
            2,
            keccak256("charter"),
            keccak256("tech"),
            deployerAddr,
            ledgerAddr,
            coordinatorAddr,
            escrowAddr,
            off
        );
        assertEq(deployer.intentHash(), expected);
    }

    function test_intentHash_differsForDifferentCharter() public {
        bytes32 salt = keccak256("manifest-diff");
        CoreDeploymentIntentOffchain memory off = CoreDeploymentIntentOffchain({
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
        });
        vm.startPrank(address(0x123));
        CoreDeployer d1 = new CoreDeployer{salt: salt}(
            2, 2, keccak256("charterA"), keccak256("tech"), address(0x456), address(this), off
        );
        vm.stopPrank();
        vm.startPrank(address(0x789));
        CoreDeployer d2 = new CoreDeployer{salt: salt}(
            2, 2, keccak256("charterB"), keccak256("tech"), address(0xABC), address(this), off
        );
        vm.stopPrank();
        assertTrue(d1.intentHash() != d2.intentHash());
    }

    function test_deployer_storesIdentityFields() public {
        assertEq(deployer.chainId(), uint64(block.chainid));
        assertEq(deployer.protocolVersion(), 2);
        assertEq(deployer.charterHash(), keccak256("charter"));
        assertEq(deployer.techSpecHash(), keccak256("tech"));
    }

    function test_deployer_createsExactlyTheTriad() public {
        assertEq(address(ledger), _createAddress(address(deployer), 1));
        assertEq(address(deployer.coordinator()), _createAddress(address(deployer), 2));
        assertEq(address(escrow), _createAddress(address(deployer), 3));
        assertGt(address(ledger).code.length, 0);
        assertGt(address(deployer.coordinator()).code.length, 0);
        assertGt(address(escrow).code.length, 0);
        assertEq(_createAddress(address(deployer), 4).code.length, 0);
    }

    function _createAddress(address creator, uint8 nonce) private pure returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), creator, bytes1(nonce)))
                )
            )
        );
    }
}
