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
    DealTerms,
    FundingAuth,
    FundingPurpose,
    FundingSourceMode,
    FundingSpec,
    PositionKind,
    PositionPayoutAuth,
    PositionPayoutResult,
    ReconciliationStatus,
    TerminalAllocation
} from "../src/libraries/DealTypes.sol";
import {CoreDeploymentIntentOffchain} from "../src/libraries/ManifestTypes.sol";

/// @notice §15.2 status-4 matrix: activation, healthy withdrawal, recovery deposit,
///         deficit claim, and terminal settlement all checkpoint without value movement and
///         succeed on the correct retry path.
contract StatusFourMatrixTest is Test {
    uint256 internal constant HOLDER_PK = 0xA11CE;
    uint256 internal constant PROVIDER_PK = 0xB0B;

    CoreEscrow internal escrow;
    CreditLedger internal ledger;
    MockERC20 internal token;
    address internal holder;
    address internal provider;
    address internal feeRecipient = address(0xFEE);
    address internal holderReceiver;
    address internal providerReceiver;

    function setUp() public {
        holder = vm.addr(HOLDER_PK);
        provider = vm.addr(PROVIDER_PK);
        holderReceiver = holder;
        providerReceiver = provider;
        (, ledger, escrow) = _deploy();
        token = new MockERC20();
    }

    function test_statusFour_activationCheckpointsWithoutEffectsAndKeepsNoncesReusable() public {
        _activate(100e18, 0, 1, 1, 2);
        token.burn(address(ledger), 40e18);

        DealTerms memory terms = _terms(50e18, 0);
        terms.nonce = 2;
        uint256 holderBalanceBefore = token.balanceOf(holder);
        uint256 allowanceBefore = token.allowance(holder, address(ledger));
        (bytes32 dealId, uint8 status) = _activatePrepared(terms, 3, 4);
        assertEq(dealId, bytes32(0));
        assertEq(status, ReconciliationStatus.DeficitCheckpointed);
        assertFalse(escrow.usedHolderNonce(holder, 2));
        assertEq(ledger.nominalOutstanding(address(token)), 100e18);
        // Helper mints the would-be principal into the holder wallet; status-4 must not pull it.
        assertEq(token.balanceOf(holder), holderBalanceBefore + terms.principal);
        assertEq(token.allowance(holder, address(ledger)), allowanceBefore);
        assertEq(token.balanceOf(address(ledger)), 60e18);
        assertTrue(ledger.inDeficit(address(token)));

        // Correct follow-up on an irreversible deficit boundary is recovery/claim, not new exposure.
        _depositRecovery(40e18);
        uint256 holderBalanceAfterRecovery = token.balanceOf(holder);
        (dealId, status) = _activatePrepared(terms, 3, 4);
        assertEq(dealId, bytes32(0));
        assertEq(status, ReconciliationStatus.DeficitCheckpointed);
        assertFalse(escrow.usedHolderNonce(holder, 2));
        assertEq(token.balanceOf(holder), holderBalanceAfterRecovery + terms.principal);
    }

    function test_statusFour_healthyWithdrawalThenRetry() public {
        bytes32 dealId = _activate(100e18, 20e18, 1, 1, 2);
        bytes32 feePosition = DealHashing.positionId(
            _boundaryId(), PositionKind.ActivationFee, dealId, bytes32(0), feeRecipient
        );

        token.burn(address(ledger), 10e18);
        PositionPayoutResult memory blocked =
            ledger.withdrawPosition(feePosition, type(uint256).max);
        assertEq(blocked.code, 6);
        assertEq(blocked.reconciliationStatus, ReconciliationStatus.DeficitCheckpointed);
        assertEq(blocked.paidAmount, 0);
        assertEq(token.balanceOf(feeRecipient), 0);
        assertEq(ledger.positionNominalRemaining(feePosition), 20e18);

        // After the status-4 checkpoint the boundary is in deficit, so healthy withdraw routes
        // to deficit-claim-required rather than paying.
        PositionPayoutResult memory routed = ledger.withdrawPosition(feePosition, type(uint256).max);
        assertEq(routed.code, 5);
        assertEq(routed.paidAmount, 0);

        PositionPayoutResult memory paid = ledger.claimRecovery(feePosition, type(uint256).max);
        assertEq(paid.code, 3);
        assertGt(paid.paidAmount, 0);
        assertEq(token.balanceOf(feeRecipient), paid.paidAmount);
    }

    function test_statusFour_recoveryDepositThenRetry() public {
        _activate(100e18, 0, 1, 1, 2);
        token.burn(address(ledger), 50e18);
        assertEq(
            ledger.checkpointBoundary(address(token)), ReconciliationStatus.DeficitCheckpointed
        );

        address donor = address(0xD0A0);
        token.mint(donor, 20e18);
        vm.prank(donor);
        token.approve(address(ledger), 20e18);
        token.burn(address(ledger), 10e18);

        vm.prank(donor);
        uint8 status = ledger.depositRecovery(address(token), 10e18);
        assertEq(status, ReconciliationStatus.DeficitCheckpointed);
        assertEq(token.balanceOf(donor), 20e18);
        assertEq(ledger.accountedAssets(address(token)), 40e18);

        vm.prank(donor);
        status = ledger.depositRecovery(address(token), 10e18);
        assertEq(status, ReconciliationStatus.Unchanged);
        assertEq(token.balanceOf(donor), 10e18);
        assertEq(ledger.accountedAssets(address(token)), 50e18);
    }

    function test_statusFour_deficitClaimThenRetryPreservesNonce() public {
        bytes32 dealId = _activate(100e18, 0, 1, 1, 2);
        bytes32 terminalHash = keccak256("status-four-claim");
        bytes32 positionId = _settleHolderTerminal(dealId, terminalHash, 100e18);
        token.burn(address(ledger), 50e18);
        assertEq(
            ledger.checkpointBoundary(address(token)), ReconciliationStatus.DeficitCheckpointed
        );

        PositionPayoutAuth memory auth = PositionPayoutAuth({
            action: 2,
            token: address(token),
            positionId: positionId,
            beneficiary: holderReceiver,
            to: holderReceiver,
            maxAmount: 40e18,
            nonce: 77,
            expiry: uint64(block.timestamp + 1 days)
        });
        bytes memory signature = _signPayout(auth);

        token.burn(address(ledger), 10e18);
        PositionPayoutResult memory blocked = ledger.claimRecoveryTo(auth, signature);
        assertEq(blocked.code, 6);
        assertEq(blocked.reconciliationStatus, ReconciliationStatus.DeficitCheckpointed);
        assertEq(blocked.paidAmount, 0);
        assertEq(token.balanceOf(holderReceiver), 0);

        _depositRecovery(60e18);
        PositionPayoutResult memory paid = ledger.claimRecoveryTo(auth, signature);
        assertEq(paid.code, 3);
        assertEq(paid.paidAmount, 40e18);
        assertEq(token.balanceOf(holderReceiver), 40e18);
    }

    function test_statusFour_terminalSettlementThenRetry() public {
        bytes32 dealId = _activate(100e18, 0, 1, 1, 2);
        bytes32 dealPosition = DealHashing.positionId(
            _boundaryId(), PositionKind.ActiveDeal, dealId, bytes32(0), address(0)
        );
        token.burn(address(ledger), 40e18);

        bytes32 terminalHash = keccak256("status-four-settle");
        bytes32 holderPosition = DealHashing.positionId(
            _boundaryId(), PositionKind.DealTerminal, dealId, terminalHash, holderReceiver
        );
        TerminalAllocation[] memory allocations = new TerminalAllocation[](1);
        allocations[0] = TerminalAllocation({
            beneficiary: holderReceiver, amount: 100e18, positionId: holderPosition
        });

        vm.prank(address(escrow));
        uint8 status =
            ledger.settleDealAndReservations(dealId, address(token), terminalHash, allocations);
        assertEq(status, ReconciliationStatus.DeficitCheckpointed);
        assertFalse(ledger.positionExists(holderPosition));
        assertTrue(ledger.positionExists(dealPosition));
        assertFalse(ledger.positionConsumed(dealPosition));
        assertEq(ledger.nominalOutstanding(address(token)), 100e18);

        vm.prank(address(escrow));
        status = ledger.settleDealAndReservations(dealId, address(token), terminalHash, allocations);
        assertEq(status, ReconciliationStatus.Unchanged);
        assertTrue(ledger.positionExists(holderPosition));
        assertTrue(ledger.positionConsumed(dealPosition));
        assertEq(ledger.positionNominal(holderPosition), 100e18);
    }

    function _terms(uint256 principal, uint256 activationFee)
        internal
        view
        returns (DealTerms memory t)
    {
        t.holder = holder;
        t.provider = provider;
        t.holderReceiver = holderReceiver;
        t.providerReceiver = providerReceiver;
        t.token = address(token);
        t.principal = principal;
        t.activationFee = activationFee;
        t.activationFeeRecipient = activationFee > 0 ? feeRecipient : address(0);
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
        t.custodyBoundaryId = _boundaryId();
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

    function _activatePrepared(
        DealTerms memory terms,
        uint256 principalFundingNonce,
        uint256 feeFundingNonce
    ) internal returns (bytes32 dealId, uint8 status) {
        FundingSpec memory principalSpec = FundingSpec({
            purpose: FundingPurpose.Principal,
            sourceMode: FundingSourceMode.WalletPull,
            token: address(token),
            amount: terms.principal,
            source: holder,
            sourcePositionId: bytes32(0),
            authority: holder
        });
        FundingSpec memory feeSpec = FundingSpec({
            purpose: FundingPurpose.ActivationFee,
            sourceMode: FundingSourceMode.WalletPull,
            token: address(token),
            amount: terms.activationFee,
            source: holder,
            sourcePositionId: bytes32(0),
            authority: holder
        });
        bytes32 principalSpecHash = DealHashing.hashFundingSpec(principalSpec);
        bytes32 feeSpecHash = DealHashing.hashFundingSpec(feeSpec);
        terms.principalFundingHash = principalSpecHash;
        terms.activationFeeFundingHash = terms.activationFee > 0 ? feeSpecHash : bytes32(0);
        bytes32 termsHash = DealHashing.hashDealTerms(terms);

        FundingAuth memory principalAuth = FundingAuth({
            termsHash: termsHash,
            fundingSpecHash: principalSpecHash,
            purpose: FundingPurpose.Principal,
            authority: holder,
            nonce: principalFundingNonce,
            expiry: uint64(block.timestamp + 1 days)
        });
        FundingAuth memory feeAuth = FundingAuth({
            termsHash: termsHash,
            fundingSpecHash: terms.activationFee > 0 ? feeSpecHash : bytes32(0),
            purpose: FundingPurpose.ActivationFee,
            authority: holder,
            nonce: feeFundingNonce,
            expiry: uint64(block.timestamp + 1 days)
        });

        token.mint(holder, terms.principal + terms.activationFee);
        vm.prank(holder);
        token.approve(address(ledger), type(uint256).max);

        return escrow.activate(
            terms,
            principalSpec,
            feeSpec,
            principalAuth,
            feeAuth,
            _sign(ledger.DOMAIN_SEPARATOR(), DealHashing.hashFundingAuth(principalAuth), HOLDER_PK),
            terms.activationFee > 0
                ? _sign(ledger.DOMAIN_SEPARATOR(), DealHashing.hashFundingAuth(feeAuth), HOLDER_PK)
                : new bytes(0),
            _sign(escrow.DOMAIN_SEPARATOR(), termsHash, HOLDER_PK),
            _sign(escrow.DOMAIN_SEPARATOR(), termsHash, PROVIDER_PK)
        );
    }

    function _settleHolderTerminal(bytes32 dealId, bytes32 terminalHash, uint256 amount)
        internal
        returns (bytes32 positionId)
    {
        positionId = DealHashing.positionId(
            _boundaryId(), PositionKind.DealTerminal, dealId, terminalHash, holderReceiver
        );
        TerminalAllocation[] memory allocations = new TerminalAllocation[](1);
        allocations[0] = TerminalAllocation({
            beneficiary: holderReceiver, amount: amount, positionId: positionId
        });
        vm.prank(address(escrow));
        ledger.settleDealAndReservations(dealId, address(token), terminalHash, allocations);
    }

    function _depositRecovery(uint256 amount) internal {
        token.mint(address(this), amount);
        token.approve(address(ledger), amount);
        ledger.depositRecovery(address(token), amount);
    }

    function _signPayout(PositionPayoutAuth memory auth) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "PositionPayoutAuth(uint8 action,address token,bytes32 positionId,address beneficiary,address to,uint256 maxAmount,uint256 nonce,uint64 expiry)"
                ),
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
        return _sign(ledger.DOMAIN_SEPARATOR(), structHash, HOLDER_PK);
    }

    function _sign(bytes32 domainSep, bytes32 structHash, uint256 pk)
        internal
        pure
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, DealHashing.digest(domainSep, structHash));
        return abi.encodePacked(r, s, v);
    }

    function _boundaryId() internal view returns (bytes32) {
        return DealHashing.custodyBoundaryId(ledger.chainId(), 2, address(ledger), address(token));
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
