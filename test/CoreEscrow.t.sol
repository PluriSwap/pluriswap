// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CoreDeployer} from "../src/CoreDeployer.sol";
import {CoreEscrow} from "../src/CoreEscrow.sol";
import {CreditLedger} from "../src/CreditLedger.sol";
import {Coordinator} from "../src/Coordinator.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {DealHashing} from "../src/libraries/DealHashing.sol";
import {SettlementMath} from "../src/libraries/SettlementMath.sol";
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
    CoreManifestOffchain
} from "../src/libraries/DealTypes.sol";
import {
    InvalidState,
    InvalidTiming,
    Unauthorized,
    ProfileNotSelected,
    NonceUsed,
    DealExists,
    Expired,
    InvalidBps,
    TerminalDeal,
    InvalidTerms
} from "../src/libraries/CoreErrors.sol";

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
            CoreManifestOffchain(
                bytes32(uint256(1)),
                bytes32(uint256(2)),
                bytes32(uint256(3)),
                bytes32(0),
                bytes32(uint256(5)),
                bytes32(uint256(6)),
                bytes32(uint256(7)),
                bytes32(uint256(8)),
                bytes32(uint256(9)),
                bytes32(uint256(10)),
                bytes32(0)
            )
        );

        bytes memory ledgerInitCode = abi.encodePacked(
            type(CreditLedger).creationCode,
            abi.encode(address(deployer.escrow()), deployer.chainId())
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
                deployer.manifestHash()
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
        ActivateParams memory p;

        p.terms = _terms(principal, activationFee, completionFee);
        p.terms.nonce = termsNonce;

        p.principalSpec = _fundingSpec(FundingPurpose.Principal, principal, holder);
        p.feeSpec = activationFee > 0
            ? _fundingSpec(FundingPurpose.ActivationFee, activationFee, holder)
            : _fundingSpec(FundingPurpose.ActivationFee, 0, holder);

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
        p.feeAuth = activationFee > 0
            ? _fundingAuth(
                termsHash, feeSpecHash, FundingPurpose.ActivationFee, holder, feeFundingNonce
            )
            : _fundingAuth(
                termsHash, bytes32(0), FundingPurpose.ActivationFee, holder, feeFundingNonce
            );

        // Sign funding auths in Ledger domain
        p.principalSig = _sign(
            ledger.DOMAIN_SEPARATOR(), DealHashing.hashFundingAuth(p.principalAuth), holderPk
        );
        p.feeSig = activationFee > 0
            ? _sign(ledger.DOMAIN_SEPARATOR(), DealHashing.hashFundingAuth(p.feeAuth), holderPk)
            : new bytes(0);

        // Sign terms in Escrow domain
        p.holderSig = _sign(escrow.DOMAIN_SEPARATOR(), termsHash, holderPk);
        p.providerSig = _sign(escrow.DOMAIN_SEPARATOR(), termsHash, providerPk);

        // Mint and approve
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
        bytes32 dealId = _activate(100e18, 0, 0);

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
        bytes32 did = DealHashing.hashDealId(
            escrow.chainId(),
            escrow.protocolVersion(),
            address(escrow),
            termsHash,
            t.holder,
            t.provider,
            t.nonce
        );

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
    }

    function test_holderRelease_withCompletionFee() public {
        bytes32 dealId = _activate(100e18, 0, 10e18);
        vm.prank(provider);
        escrow.markFiatSent(dealId);

        vm.prank(holder);
        escrow.holderRelease(dealId);

        TerminalRecord memory tr = escrow.getTerminalRecord(dealId);
        assertEq(tr.providerGross, 100e18);
        assertEq(tr.completionCollected, 10e18);
        assertEq(tr.providerNet, 90e18);
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

    function test_disputeTimeout_withCompletionFee() public {
        bytes32 dealId = _activate(100e18, 0, 10e18);
        vm.prank(provider);
        escrow.markFiatSent(dealId);
        vm.prank(holder);
        escrow.openDispute(dealId, "");

        vm.warp(escrow.getDeal(dealId).disputeDeadline + 1);

        escrow.disputeTimeout(dealId);

        TerminalRecord memory tr = escrow.getTerminalRecord(dealId);
        // 5_000 bps → providerGross = 50e18
        assertEq(tr.providerGross, 50e18);
        // completionCollected = min(10e18, 50e18) = 10e18
        assertEq(tr.completionCollected, 10e18);
        // providerNet = 50e18 - 10e18 = 40e18
        assertEq(tr.providerNet, 40e18);
        // holderSideReturn = 100e18 - 50e18 = 50e18
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

    function test_manifestHash_nonZero() public {
        assertTrue(deployer.manifestHash() != bytes32(0));
    }

    function test_manifestHash_matchesEscrow() public {
        assertEq(deployer.manifestHash(), escrow.manifestHash());
    }

    function test_manifestHash_deterministic() public {
        // Compute expected manifest hash from known addresses
        address deployerAddr = address(deployer);
        address ledgerAddr = address(ledger);
        address coordinatorAddr = address(deployer.coordinator());
        address escrowAddr = address(escrow);
        CoreManifestOffchain memory off = CoreManifestOffchain(
            bytes32(uint256(1)),
            bytes32(uint256(2)),
            bytes32(uint256(3)),
            bytes32(0),
            bytes32(uint256(5)),
            bytes32(uint256(6)),
            bytes32(uint256(7)),
            bytes32(uint256(8)),
            bytes32(uint256(9)),
            bytes32(uint256(10)),
            bytes32(0)
        );
        bytes32 expected = DealHashing.hashCoreManifest(
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
        assertEq(deployer.manifestHash(), expected);
    }

    function test_manifestHash_differsForDifferentCharter() public {
        bytes32 salt = keccak256("manifest-diff");
        CoreManifestOffchain memory off = CoreManifestOffchain(
            bytes32(uint256(1)),
            bytes32(uint256(2)),
            bytes32(uint256(3)),
            bytes32(uint256(4)),
            bytes32(uint256(5)),
            bytes32(uint256(6)),
            bytes32(uint256(7)),
            bytes32(uint256(8)),
            bytes32(uint256(9)),
            bytes32(uint256(10)),
            bytes32(0)
        );
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
        assertTrue(d1.manifestHash() != d2.manifestHash());
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
