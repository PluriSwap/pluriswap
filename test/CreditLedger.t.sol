// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {CreditLedger} from "../src/CreditLedger.sol";
import {CoreDeployer} from "../src/CoreDeployer.sol";
import {CoreEscrow} from "../src/CoreEscrow.sol";
import {Coordinator} from "../src/Coordinator.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {DealHashing} from "../src/libraries/DealHashing.sol";
import {
    FundingSpec,
    FundingAuth,
    DeficitComponents,
    PositionView,
    PositionPayoutAuth,
    PositionPayoutResult,
    TerminalAllocation,
    FundingPurpose,
    FundingSourceMode,
    PositionKind,
    BoundaryMode,
    ReconciliationStatus,
    PayoutResultCode
} from "../src/libraries/DealTypes.sol";
import {CoreDeploymentIntentOffchain} from "../src/libraries/ManifestTypes.sol";
import {
    PositionAlreadyConsumed,
    PositionAlreadyExists,
    PositionNotFound,
    PositionNotClaimable,
    Unauthorized,
    InvalidPositionKind,
    InvalidTokenList,
    InvalidAmount,
    NonceUsed,
    RecoveryExceedsGap,
    DeficitNotActive,
    ExactTransferFailed,
    SelfReceiver,
    FundingAuthInvalid,
    PositionNotSplittable
} from "../src/libraries/CoreErrors.sol";

contract CreditLedgerInvariantHarness is CreditLedger {
    constructor(address escrow_, address coordinator_, uint64 chainId_)
        CreditLedger(escrow_, coordinator_, chainId_)
    {}

    function setActiveDeficitAccounting(
        bytes32 positionId,
        uint256 paidAssets,
        uint256 history,
        uint256 generation
    ) external {
        Position storage position = _positions[positionId];
        position.deficitPaidAssets = paidAssets;
        position.deficitHistory = history;
        position.deficitGeneration = generation;
    }

    function emitLossCheckpointFixture(address token, bytes32 checkpointId) external {
        emit LossCheckpointed(token, checkpointId, 11, 22, 33, 44, 55, 66, 77, 88, 99, true);
    }
}

/// @dev Tests the CreditLedger as sole vault with positions and reconciliation.
/// Uses vm.prank(escrow) to isolate Ledger authorization and accounting behavior.
contract CreditLedgerTest is Test {
    event PositionConsumed(bytes32 indexed positionId);

    uint256 internal constant MAX_BOUNDARY_NOMINAL = type(uint128).max;

    CoreDeployer deployer;
    CreditLedger ledger;
    MockERC20 token;
    address escrow;
    address holder;
    address provider = address(0xB0B);
    address holderReceiver = address(0x1111);
    address providerReceiver = address(0x2222);
    address feeRecipient = address(0xFEE);

    uint256 holderPk = 0xA11CE;
    uint256 authorityPk = 0xA11CE; // holder is the funding authority for direct deals

    struct FundingCall {
        bytes32 termsHash;
        bytes32 dealId;
        address token;
        uint256 principal;
        uint256 activationFee;
        FundingSpec principalSpec;
        FundingSpec feeSpec;
        FundingAuth principalAuth;
        FundingAuth feeAuth;
        bytes principalSignature;
        bytes feeSignature;
    }

    struct LossCheckpointFixture {
        uint256 accountedAssets;
        uint256 nominalOutstanding;
        uint256 deficitNominalUnits;
        uint256 deficitPaidAssets;
        uint256 deficitGapCoefficient;
        uint256 deficitHistoryScale;
        uint256 deficitHistoryTotal;
        uint256 deficitGeneration;
        uint256 deficitRoundingDust;
        bool deficitPrecisionFloor;
    }

    function setUp() public {
        holder = vm.addr(holderPk);
        bytes32 salt = keccak256("ledger-test");
        deployer = new CoreDeployer{salt: salt}(
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
        ledger = deployer.ledger();
        escrow = address(deployer.escrow());
        token = new MockERC20();
    }

    // ── Helpers ─────────────────────────────────────────────────────────────────

    function _fundingSpec(uint8 purpose, address token_, uint256 amount, address source)
        internal
        pure
        returns (FundingSpec memory)
    {
        return FundingSpec({
            purpose: purpose,
            sourceMode: FundingSourceMode.WalletPull,
            token: token_,
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

    function _signFundingAuth(FundingAuth memory auth, uint256 pk)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest_ =
            DealHashing.digest(ledger.DOMAIN_SEPARATOR(), DealHashing.hashFundingAuth(auth));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest_);
        return abi.encodePacked(r, s, v);
    }

    function _prepareFundingCall(
        bytes32 dealId,
        FundingSpec memory principalSpec,
        FundingSpec memory feeSpec,
        uint256 principalNonce,
        uint256 feeNonce
    ) internal view returns (FundingCall memory call) {
        call.termsHash = keccak256(abi.encodePacked("funding-terms", dealId));
        call.dealId = dealId;
        call.token = principalSpec.token;
        call.principal = principalSpec.amount;
        call.activationFee = feeSpec.amount;
        call.principalSpec = principalSpec;
        call.feeSpec = feeSpec;
        call.principalAuth = _fundingAuth(
            call.termsHash,
            DealHashing.hashFundingSpec(principalSpec),
            FundingPurpose.Principal,
            principalSpec.authority,
            principalNonce
        );
        call.principalSignature = _signFundingAuth(call.principalAuth, authorityPk);
        if (call.activationFee > 0) {
            call.feeAuth = _fundingAuth(
                call.termsHash,
                DealHashing.hashFundingSpec(feeSpec),
                FundingPurpose.ActivationFee,
                feeSpec.authority,
                feeNonce
            );
            call.feeSignature = _signFundingAuth(call.feeAuth, authorityPk);
        }
    }

    function _walletFundingCall(
        address token_,
        bytes32 dealId,
        uint256 principal,
        uint256 activationFee,
        uint256 principalNonce,
        uint256 feeNonce
    ) internal view returns (FundingCall memory) {
        FundingSpec memory principalSpec =
            _fundingSpec(FundingPurpose.Principal, token_, principal, holder);
        FundingSpec memory feeSpec =
            _fundingSpec(FundingPurpose.ActivationFee, token_, activationFee, holder);
        return _prepareFundingCall(dealId, principalSpec, feeSpec, principalNonce, feeNonce);
    }

    function _callFunding(FundingCall memory call) internal returns (uint8 reconciliationStatus) {
        vm.prank(escrow);
        return ledger.fundDealAndReservations(
            call.termsHash,
            call.dealId,
            call.token,
            call.principal,
            call.activationFee,
            feeRecipient,
            call.principalSpec,
            call.feeSpec,
            call.principalAuth,
            call.feeAuth,
            call.principalSignature,
            call.feeSignature
        );
    }

    function _boundaryId(address token_) internal view returns (bytes32) {
        return DealHashing.custodyBoundaryId(ledger.chainId(), 2, address(ledger), token_);
    }

    function _dealPosId(address token_, bytes32 dealId) internal view returns (bytes32) {
        return DealHashing.positionId(
            _boundaryId(token_), PositionKind.ActiveDeal, dealId, bytes32(0), address(0)
        );
    }

    function _termPosId(address token_, bytes32 dealId, bytes32 terminalHash, address beneficiary)
        internal
        view
        returns (bytes32)
    {
        return DealHashing.positionId(
            _boundaryId(token_), PositionKind.DealTerminal, dealId, terminalHash, beneficiary
        );
    }

    function _settleToHolder(address token_, bytes32 dealId, uint256 amount)
        internal
        returns (bytes32 positionId)
    {
        bytes32 terminalHash = keccak256(abi.encodePacked("terminal", dealId));
        positionId = _termPosId(token_, dealId, terminalHash, holder);
        TerminalAllocation[] memory allocations = new TerminalAllocation[](1);
        allocations[0] =
            TerminalAllocation({beneficiary: holder, amount: amount, positionId: positionId});
        vm.prank(escrow);
        ledger.settleDealAndReservations(dealId, token_, terminalHash, allocations);
    }

    function _limitError(uint256 current, uint256 added) internal pure returns (bytes memory) {
        return abi.encodeWithSignature(
            "BoundaryNominalLimitExceeded(uint256,uint256,uint256)",
            current,
            added,
            MAX_BOUNDARY_NOMINAL
        );
    }

    function _mockUnexpectedPull(MockERC20 token_, uint256 amount) internal {
        vm.mockCallRevert(
            address(token_),
            abi.encodeWithSelector(
                MockERC20.transferFrom.selector, holder, address(ledger), amount
            ),
            abi.encodeWithSignature("UnexpectedTokenPull()")
        );
    }

    function _fundDeal(bytes32 dealId, uint256 principal, uint256 activationFee) internal {
        token.mint(holder, principal + activationFee);
        vm.prank(holder);
        token.approve(address(ledger), type(uint256).max);

        FundingSpec memory principalSpec =
            _fundingSpec(FundingPurpose.Principal, address(token), principal, holder);
        FundingSpec memory feeSpec =
            _fundingSpec(FundingPurpose.ActivationFee, address(token), activationFee, holder);
        bytes32 principalSpecHash = DealHashing.hashFundingSpec(principalSpec);
        bytes32 feeSpecHash = DealHashing.hashFundingSpec(feeSpec);

        FundingAuth memory principalAuth = _fundingAuth(
            bytes32(uint256(1)), principalSpecHash, FundingPurpose.Principal, holder, 1
        );
        FundingAuth memory feeAuth = activationFee > 0
            ? _fundingAuth(
                bytes32(uint256(1)), feeSpecHash, FundingPurpose.ActivationFee, holder, 2
            )
            : _fundingAuth(bytes32(uint256(1)), bytes32(0), FundingPurpose.ActivationFee, holder, 2);

        bytes memory principalSig = _signFundingAuth(principalAuth, authorityPk);
        bytes memory feeSig =
            activationFee > 0 ? _signFundingAuth(feeAuth, authorityPk) : new bytes(0);

        vm.prank(escrow);
        ledger.fundDealAndReservations(
            bytes32(uint256(1)),
            dealId,
            address(token),
            principal,
            activationFee,
            feeRecipient,
            principalSpec,
            feeSpec,
            principalAuth,
            feeAuth,
            principalSig,
            feeSig
        );
    }

    function _dealPosId(bytes32 dealId) internal view returns (bytes32) {
        bytes32 boundaryId =
            DealHashing.custodyBoundaryId(ledger.chainId(), 2, address(ledger), address(token));
        return
            DealHashing.positionId(
                boundaryId, PositionKind.ActiveDeal, dealId, bytes32(0), address(0)
            );
    }

    function _termPosId(bytes32 dealId, bytes32 terminalHash, address beneficiary)
        internal
        view
        returns (bytes32)
    {
        bytes32 boundaryId =
            DealHashing.custodyBoundaryId(ledger.chainId(), 2, address(ledger), address(token));
        return DealHashing.positionId(
            boundaryId, PositionKind.DealTerminal, dealId, terminalHash, beneficiary
        );
    }

    // ── Tests ────────────────────────────────────────────────────────────────────

    function test_fundDeal_createsPositions() public {
        bytes32 dealId = keccak256("deal1");
        _fundDeal(dealId, 100e18, 5e18);

        // DEAL position
        bytes32 dealPos = _dealPosId(dealId);
        assertTrue(ledger.positionExists(dealPos));
        assertEq(ledger.positionNominal(dealPos), 100e18);
        assertEq(ledger.positionKind(dealPos), PositionKind.ActiveDeal);
        assertFalse(ledger.positionConsumed(dealPos));

        // ACTIVATION_FEE position
        bytes32 boundaryId =
            DealHashing.custodyBoundaryId(ledger.chainId(), 2, address(ledger), address(token));
        bytes32 feePos = DealHashing.positionId(
            boundaryId, PositionKind.ActivationFee, dealId, bytes32(0), feeRecipient
        );
        assertTrue(ledger.positionExists(feePos));
        assertEq(ledger.positionNominal(feePos), 5e18);
        assertEq(ledger.positionBeneficiary(feePos), feeRecipient);

        // Accounting
        assertEq(ledger.accountedAssets(address(token)), 105e18);
        assertEq(ledger.nominalOutstanding(address(token)), 105e18);
        assertEq(token.balanceOf(address(ledger)), 105e18);
    }

    function test_fundDeal_zeroFee() public {
        bytes32 dealId = keccak256("deal2");
        _fundDeal(dealId, 100e18, 0);

        bytes32 dealPos = _dealPosId(dealId);
        assertTrue(ledger.positionExists(dealPos));
        assertEq(ledger.positionNominal(dealPos), 100e18);
        assertEq(ledger.accountedAssets(address(token)), 100e18);
    }

    function test_boundaryNominalLimit_isExposedAndExactCapIsAccepted() public {
        (bool success, bytes memory result) =
            address(ledger).staticcall(abi.encodeWithSignature("MAX_BOUNDARY_NOMINAL()"));
        assertTrue(success);
        assertEq(abi.decode(result, (uint256)), MAX_BOUNDARY_NOMINAL);

        FundingCall memory call = _walletFundingCall(
            address(token), keccak256("exact-boundary-cap"), MAX_BOUNDARY_NOMINAL, 0, 10, 11
        );
        token.mint(holder, MAX_BOUNDARY_NOMINAL);
        vm.prank(holder);
        token.approve(address(ledger), MAX_BOUNDARY_NOMINAL);

        assertEq(_callFunding(call), ReconciliationStatus.Unchanged);
        assertEq(ledger.nominalOutstanding(address(token)), MAX_BOUNDARY_NOMINAL);
        assertEq(ledger.accountedAssets(address(token)), MAX_BOUNDARY_NOMINAL);
        assertTrue(ledger.positionExists(_dealPosId(address(token), call.dealId)));
    }

    function test_boundaryNominalLimit_capPlusOneRejectsBeforePullWithReusableNonce() public {
        uint256 amount = MAX_BOUNDARY_NOMINAL + 1;
        bytes32 rejectedDealId = keccak256("cap-plus-one");
        FundingCall memory rejected =
            _walletFundingCall(address(token), rejectedDealId, amount, 0, 20, 21);
        token.mint(holder, amount);
        vm.prank(holder);
        token.approve(address(ledger), amount);
        _mockUnexpectedPull(token, amount);

        vm.expectRevert(_limitError(0, amount));
        _callFunding(rejected);
        vm.clearMockedCalls();

        assertEq(token.balanceOf(address(ledger)), 0);
        assertEq(token.balanceOf(holder), amount);
        assertEq(token.allowance(holder, address(ledger)), amount);
        assertEq(ledger.nominalOutstanding(address(token)), 0);
        assertEq(ledger.accountedAssets(address(token)), 0);
        assertFalse(ledger.positionExists(_dealPosId(address(token), rejectedDealId)));

        FundingCall memory retry =
            _walletFundingCall(address(token), keccak256("cap-plus-one-retry"), 1, 0, 20, 22);
        assertEq(_callFunding(retry), ReconciliationStatus.Unchanged);
        assertEq(ledger.nominalOutstanding(address(token)), 1);
    }

    function test_boundaryNominalLimit_validatesAuthBeforeLimit() public {
        uint256 amount = MAX_BOUNDARY_NOMINAL + 1;
        FundingCall memory call = _walletFundingCall(
            address(token), keccak256("invalid-auth-before-limit"), amount, 0, 30, 31
        );
        call.principalSignature = _signFundingAuth(call.principalAuth, 0xBADD);

        vm.expectRevert(FundingAuthInvalid.selector);
        _callFunding(call);
    }

    function test_boundaryNominalLimit_principalAndFeeCrossingRejectsBeforeEitherPull() public {
        uint256 principal = MAX_BOUNDARY_NOMINAL;
        uint256 activationFee = 1;
        FundingCall memory call = _walletFundingCall(
            address(token),
            keccak256("aggregate-principal-and-fee"),
            principal,
            activationFee,
            40,
            41
        );
        token.mint(holder, principal + activationFee);
        vm.prank(holder);
        token.approve(address(ledger), type(uint256).max);
        _mockUnexpectedPull(token, principal);

        vm.expectRevert(_limitError(0, principal + activationFee));
        _callFunding(call);
        vm.clearMockedCalls();

        assertEq(token.balanceOf(address(ledger)), 0);
        assertEq(ledger.nominalOutstanding(address(token)), 0);
        assertFalse(ledger.positionExists(_dealPosId(address(token), call.dealId)));
    }

    function test_boundaryNominalLimit_existingExposurePlusWalletFundingRejects() public {
        uint256 existing = MAX_BOUNDARY_NOMINAL - 1;
        FundingCall memory initial =
            _walletFundingCall(address(token), keccak256("existing-near-cap"), existing, 0, 50, 51);
        token.mint(holder, existing);
        vm.prank(holder);
        token.approve(address(ledger), type(uint256).max);
        _callFunding(initial);

        FundingCall memory crossing =
            _walletFundingCall(address(token), keccak256("later-crossing"), 2, 0, 52, 53);
        token.mint(holder, 2);
        _mockUnexpectedPull(token, 2);

        vm.expectRevert(_limitError(existing, 2));
        _callFunding(crossing);
        vm.clearMockedCalls();

        assertEq(ledger.nominalOutstanding(address(token)), existing);
        assertEq(ledger.accountedAssets(address(token)), existing);
        assertFalse(ledger.positionExists(_dealPosId(address(token), crossing.dealId)));
    }

    function test_boundaryNominalLimit_mixedFundingCountsOnlyWalletUnits() public {
        uint256 initialAmount = MAX_BOUNDARY_NOMINAL - 10;
        bytes32 sourceDealId = keccak256("mixed-source");
        FundingCall memory initial =
            _walletFundingCall(address(token), sourceDealId, initialAmount, 0, 60, 61);
        token.mint(holder, initialAmount);
        vm.prank(holder);
        token.approve(address(ledger), type(uint256).max);
        _callFunding(initial);
        bytes32 sourcePositionId = _settleToHolder(address(token), sourceDealId, initialAmount);

        FundingSpec memory principalSpec =
            _fundingSpec(FundingPurpose.Principal, address(token), 6, holder);
        principalSpec.sourceMode = FundingSourceMode.LedgerPosition;
        principalSpec.sourcePositionId = sourcePositionId;
        FundingSpec memory feeSpec =
            _fundingSpec(FundingPurpose.ActivationFee, address(token), 10, holder);
        FundingCall memory mixed =
            _prepareFundingCall(keccak256("mixed-destination"), principalSpec, feeSpec, 62, 63);
        token.mint(holder, 10);

        assertEq(_callFunding(mixed), ReconciliationStatus.Unchanged);
        assertEq(ledger.nominalOutstanding(address(token)), MAX_BOUNDARY_NOMINAL);
        assertEq(ledger.accountedAssets(address(token)), MAX_BOUNDARY_NOMINAL);
        assertEq(ledger.positionNominal(sourcePositionId), initialAmount - 6);
        assertTrue(ledger.positionExists(_dealPosId(address(token), mixed.dealId)));
    }

    function test_boundaryNominalLimit_mixedCrossingRejectsBeforePositionDebit() public {
        bytes32 sourceDealId = keccak256("mixed-at-cap-source");
        FundingCall memory initial =
            _walletFundingCall(address(token), sourceDealId, MAX_BOUNDARY_NOMINAL, 0, 70, 71);
        token.mint(holder, MAX_BOUNDARY_NOMINAL);
        vm.prank(holder);
        token.approve(address(ledger), type(uint256).max);
        _callFunding(initial);
        bytes32 sourcePositionId =
            _settleToHolder(address(token), sourceDealId, MAX_BOUNDARY_NOMINAL);

        FundingSpec memory principalSpec =
            _fundingSpec(FundingPurpose.Principal, address(token), 1, holder);
        principalSpec.sourceMode = FundingSourceMode.LedgerPosition;
        principalSpec.sourcePositionId = sourcePositionId;
        FundingSpec memory feeSpec =
            _fundingSpec(FundingPurpose.ActivationFee, address(token), 1, holder);
        FundingCall memory crossing = _prepareFundingCall(
            keccak256("mixed-at-cap-destination"), principalSpec, feeSpec, 72, 73
        );
        token.mint(holder, 1);
        _mockUnexpectedPull(token, 1);

        vm.expectRevert(_limitError(MAX_BOUNDARY_NOMINAL, 1));
        _callFunding(crossing);
        vm.clearMockedCalls();

        assertEq(ledger.positionNominal(sourcePositionId), MAX_BOUNDARY_NOMINAL);
        assertEq(ledger.nominalOutstanding(address(token)), MAX_BOUNDARY_NOMINAL);
        assertFalse(ledger.positionExists(_dealPosId(address(token), crossing.dealId)));
    }

    function test_boundaryNominalLimit_sameVaultReallocationAtCapSucceeds() public {
        bytes32 sourceDealId = keccak256("same-vault-at-cap-source");
        FundingCall memory initial =
            _walletFundingCall(address(token), sourceDealId, MAX_BOUNDARY_NOMINAL, 0, 80, 81);
        token.mint(holder, MAX_BOUNDARY_NOMINAL);
        vm.prank(holder);
        token.approve(address(ledger), type(uint256).max);
        _callFunding(initial);
        bytes32 sourcePositionId =
            _settleToHolder(address(token), sourceDealId, MAX_BOUNDARY_NOMINAL);

        FundingSpec memory principalSpec =
            _fundingSpec(FundingPurpose.Principal, address(token), 1, holder);
        principalSpec.sourceMode = FundingSourceMode.LedgerPosition;
        principalSpec.sourcePositionId = sourcePositionId;
        FundingSpec memory emptyFee =
            _fundingSpec(FundingPurpose.ActivationFee, address(token), 0, holder);
        FundingCall memory reallocation = _prepareFundingCall(
            keccak256("same-vault-at-cap-destination"), principalSpec, emptyFee, 82, 83
        );

        assertEq(_callFunding(reallocation), ReconciliationStatus.Unchanged);
        assertEq(ledger.positionNominal(sourcePositionId), MAX_BOUNDARY_NOMINAL - 1);
        assertEq(ledger.nominalOutstanding(address(token)), MAX_BOUNDARY_NOMINAL);
        assertEq(token.balanceOf(address(ledger)), MAX_BOUNDARY_NOMINAL);
    }

    function test_boundaryNominalLimit_isIndependentPerTokenBoundary() public {
        MockERC20 secondToken = new MockERC20();
        FundingCall memory first = _walletFundingCall(
            address(token), keccak256("first-token-cap"), MAX_BOUNDARY_NOMINAL, 0, 90, 91
        );
        FundingCall memory second = _walletFundingCall(
            address(secondToken), keccak256("second-token-cap"), MAX_BOUNDARY_NOMINAL, 0, 92, 93
        );
        token.mint(holder, MAX_BOUNDARY_NOMINAL);
        secondToken.mint(holder, MAX_BOUNDARY_NOMINAL);
        vm.startPrank(holder);
        token.approve(address(ledger), type(uint256).max);
        secondToken.approve(address(ledger), type(uint256).max);
        vm.stopPrank();

        _callFunding(first);
        _callFunding(second);

        assertEq(ledger.nominalOutstanding(address(token)), MAX_BOUNDARY_NOMINAL);
        assertEq(ledger.nominalOutstanding(address(secondToken)), MAX_BOUNDARY_NOMINAL);
        assertEq(token.balanceOf(address(ledger)), MAX_BOUNDARY_NOMINAL);
        assertEq(secondToken.balanceOf(address(ledger)), MAX_BOUNDARY_NOMINAL);
    }

    function test_boundaryNominalLimit_uint256ExtremeAndAggregateOverflowRejectBeforePull() public {
        FundingCall memory extreme = _walletFundingCall(
            address(token), keccak256("uint256-extreme"), type(uint256).max, 0, 100, 101
        );
        token.mint(holder, type(uint256).max);
        vm.prank(holder);
        token.approve(address(ledger), type(uint256).max);
        _mockUnexpectedPull(token, type(uint256).max);

        vm.expectRevert(_limitError(0, type(uint256).max));
        _callFunding(extreme);
        vm.clearMockedCalls();

        FundingCall memory overflowing = _walletFundingCall(
            address(token), keccak256("uint256-aggregate-overflow"), type(uint256).max, 1, 102, 103
        );
        _mockUnexpectedPull(token, type(uint256).max);

        vm.expectRevert(_limitError(0, type(uint256).max));
        _callFunding(overflowing);
        vm.clearMockedCalls();

        assertEq(ledger.nominalOutstanding(address(token)), 0);
        assertEq(ledger.accountedAssets(address(token)), 0);
    }

    function test_boundaryNominalLimit_oneUnitLossAtCapHasOneUnitMaterializationBound() public {
        FundingCall memory call = _walletFundingCall(
            address(token), keccak256("one-unit-loss-at-cap"), MAX_BOUNDARY_NOMINAL, 0, 110, 111
        );
        token.mint(holder, MAX_BOUNDARY_NOMINAL);
        vm.prank(holder);
        token.approve(address(ledger), type(uint256).max);
        _callFunding(call);
        token.burn(address(ledger), 1);

        vm.recordLogs();
        uint8 status = ledger.checkpointBoundary(address(token));

        assertEq(status, ReconciliationStatus.DeficitCheckpointed);
        assertEq(ledger.deficitRoundingDust(address(token)), 1);
        bytes32 checkpointId = _expectedBoundaryCheckpointIdWithDust(1);
        assertEq(ledger.boundaryCheckpointId(address(token)), checkpointId);
        _assertInitialDeficitEntryLogs(checkpointId);

        PositionView memory position = ledger.getPosition(_dealPosId(address(token), call.dealId));
        uint256 exactGap = 1;
        uint256 materializedGap = position.components.unfundedGap;

        assertEq(materializedGap, 2);
        assertLe(materializedGap - exactGap, 1);
        assertEq(position.components.fundedEntitlement, MAX_BOUNDARY_NOMINAL - 2);
        assertLt(materializedGap, uint256(1) << 128);
    }

    function test_fundDeal_rejectsCoordinatorActivationFeeRecipient() public {
        bytes32 dealId = keccak256("coordinator-activation-fee");
        uint256 principal = 100e18;
        uint256 activationFee = 5e18;
        token.mint(holder, principal + activationFee);
        vm.prank(holder);
        token.approve(address(ledger), type(uint256).max);

        FundingSpec memory principalSpec =
            _fundingSpec(FundingPurpose.Principal, address(token), principal, holder);
        FundingSpec memory feeSpec =
            _fundingSpec(FundingPurpose.ActivationFee, address(token), activationFee, holder);
        bytes32 termsHash = keccak256("coordinator-activation-fee-terms");
        FundingAuth memory principalAuth = _fundingAuth(
            termsHash,
            DealHashing.hashFundingSpec(principalSpec),
            FundingPurpose.Principal,
            holder,
            1
        );
        FundingAuth memory feeAuth = _fundingAuth(
            termsHash, DealHashing.hashFundingSpec(feeSpec), FundingPurpose.ActivationFee, holder, 2
        );
        bytes memory principalSignature = _signFundingAuth(principalAuth, authorityPk);
        bytes memory feeSignature = _signFundingAuth(feeAuth, authorityPk);
        address coordinatorReceiver = address(deployer.coordinator());

        vm.prank(escrow);
        vm.expectRevert(SelfReceiver.selector);
        ledger.fundDealAndReservations(
            termsHash,
            dealId,
            address(token),
            principal,
            activationFee,
            coordinatorReceiver,
            principalSpec,
            feeSpec,
            principalAuth,
            feeAuth,
            principalSignature,
            feeSignature
        );
    }

    function test_fundDeal_nonEscrow_reverts() public {
        vm.expectRevert(Unauthorized.selector);
        ledger.fundDealAndReservations(
            bytes32(0),
            bytes32(0),
            address(token),
            0,
            0,
            address(0),
            FundingSpec(0, 0, address(0), 0, address(0), bytes32(0), address(0)),
            FundingSpec(0, 0, address(0), 0, address(0), bytes32(0), address(0)),
            FundingAuth(bytes32(0), bytes32(0), 0, address(0), 0, 0),
            FundingAuth(bytes32(0), bytes32(0), 0, address(0), 0, 0),
            "",
            ""
        );
    }

    function test_settle_createsTerminalPositions() public {
        bytes32 dealId = keccak256("deal3");
        _fundDeal(dealId, 100e18, 0);

        bytes32 terminalHash = keccak256("terminal");
        TerminalAllocation[] memory allocs = new TerminalAllocation[](2);
        allocs[0] = TerminalAllocation({
            beneficiary: holderReceiver,
            amount: 60e18,
            positionId: _termPosId(dealId, terminalHash, holderReceiver)
        });
        allocs[1] = TerminalAllocation({
            beneficiary: providerReceiver,
            amount: 40e18,
            positionId: _termPosId(dealId, terminalHash, providerReceiver)
        });

        bytes32 dealPos = _dealPosId(dealId);
        assertEq(ledger.positionTerminalHash(dealPos), bytes32(0));
        vm.expectEmit(true, false, false, true, address(ledger));
        emit PositionConsumed(dealPos);
        vm.prank(escrow);
        ledger.settleDealAndReservations(dealId, address(token), terminalHash, allocs);

        // Deal position consumed
        assertTrue(ledger.positionConsumed(dealPos));
        assertEq(ledger.positionTerminalHash(dealPos), terminalHash);

        // Terminal positions created
        bytes32 holderTerm = _termPosId(dealId, terminalHash, holderReceiver);
        bytes32 providerTerm = _termPosId(dealId, terminalHash, providerReceiver);
        assertTrue(ledger.positionExists(holderTerm));
        assertEq(ledger.positionNominal(holderTerm), 60e18);
        assertTrue(ledger.positionExists(providerTerm));
        assertEq(ledger.positionNominal(providerTerm), 40e18);

        // Accounting unchanged (no token movement)
        assertEq(ledger.accountedAssets(address(token)), 100e18);
        assertEq(ledger.nominalOutstanding(address(token)), 100e18);
    }

    function test_settle_rejectsCoordinatorTerminalReceiver() public {
        bytes32 dealId = keccak256("coordinator-terminal");
        _fundDeal(dealId, 100e18, 0);
        bytes32 terminalHash = keccak256("coordinator-terminal-hash");
        address coordinatorReceiver = address(deployer.coordinator());
        TerminalAllocation[] memory allocations = new TerminalAllocation[](1);
        allocations[0] = TerminalAllocation({
            beneficiary: coordinatorReceiver,
            amount: 100e18,
            positionId: _termPosId(dealId, terminalHash, coordinatorReceiver)
        });

        vm.prank(escrow);
        vm.expectRevert(SelfReceiver.selector);
        ledger.settleDealAndReservations(dealId, address(token), terminalHash, allocations);

        assertFalse(ledger.positionConsumed(_dealPosId(dealId)));
    }

    function test_settle_rejectsMalformedDuplicateBeneficiaryAllocations() public {
        bytes32 dealId = keccak256("deal4");
        _fundDeal(dealId, 100e18, 0);

        bytes32 terminalHash = keccak256("terminal");
        TerminalAllocation[] memory allocs = new TerminalAllocation[](2);
        allocs[0] = TerminalAllocation({
            beneficiary: holderReceiver,
            amount: 30e18,
            positionId: _termPosId(dealId, terminalHash, holderReceiver)
        });
        allocs[1] = TerminalAllocation({
            beneficiary: holderReceiver,
            amount: 70e18,
            positionId: _termPosId(dealId, terminalHash, holderReceiver)
        });

        vm.expectRevert(PositionAlreadyExists.selector);
        vm.prank(escrow);
        ledger.settleDealAndReservations(dealId, address(token), terminalHash, allocs);

        bytes32 dealPositionId = _dealPosId(dealId);
        assertFalse(ledger.positionConsumed(dealPositionId));
        assertEq(ledger.positionTerminalHash(dealPositionId), bytes32(0));
        assertFalse(ledger.positionExists(_termPosId(dealId, terminalHash, holderReceiver)));
    }

    function test_settle_duplicateRejects() public {
        bytes32 dealId = keccak256("deal5");
        _fundDeal(dealId, 100e18, 0);

        bytes32 terminalHash = keccak256("terminal");
        TerminalAllocation[] memory allocs = new TerminalAllocation[](1);
        allocs[0] = TerminalAllocation({
            beneficiary: holderReceiver,
            amount: 100e18,
            positionId: _termPosId(dealId, terminalHash, holderReceiver)
        });

        vm.prank(escrow);
        ledger.settleDealAndReservations(dealId, address(token), terminalHash, allocs);
        bytes32 dealPositionId = _dealPosId(dealId);
        assertEq(ledger.positionTerminalHash(dealPositionId), terminalHash);

        // Second settlement on consumed deal → reverts
        bytes32 differentTerminalHash = keccak256("different-terminal");
        TerminalAllocation[] memory differentAllocs = new TerminalAllocation[](1);
        differentAllocs[0] = TerminalAllocation({
            beneficiary: holderReceiver,
            amount: 100e18,
            positionId: _termPosId(dealId, differentTerminalHash, holderReceiver)
        });
        vm.prank(escrow);
        vm.expectRevert(PositionAlreadyConsumed.selector);
        ledger.settleDealAndReservations(
            dealId, address(token), differentTerminalHash, differentAllocs
        );
        assertEq(ledger.positionTerminalHash(dealPositionId), terminalHash);
    }

    function test_settle_statusFourLeavesTerminalProvenanceUntouched() public {
        bytes32 dealId = keccak256("settlement-reconciliation-only");
        _fundDeal(dealId, 100e18, 0);
        bytes32 dealPositionId = _dealPosId(dealId);
        bytes32 terminalHash = keccak256("uncommitted-terminal");
        TerminalAllocation[] memory allocations = new TerminalAllocation[](1);
        allocations[0] = TerminalAllocation({
            beneficiary: holderReceiver,
            amount: 100e18,
            positionId: _termPosId(dealId, terminalHash, holderReceiver)
        });
        token.burn(address(ledger), 50e18);

        vm.prank(escrow);
        uint8 status =
            ledger.settleDealAndReservations(dealId, address(token), terminalHash, allocations);

        assertEq(status, ReconciliationStatus.DeficitCheckpointed);
        assertFalse(ledger.positionConsumed(dealPositionId));
        assertEq(ledger.positionTerminalHash(dealPositionId), bytes32(0));
        assertFalse(ledger.positionExists(_termPosId(dealId, terminalHash, holderReceiver)));
    }

    function test_settle_rejectsActiveSourceWithPaidAssetsOrLocalHistory() public {
        CreditLedgerInvariantHarness harness =
            new CreditLedgerInvariantHarness(address(this), address(0xC0), uint64(block.chainid));
        ledger = CreditLedger(address(harness));
        escrow = address(this);

        bytes32 dealId = keccak256("deal-active-accounting-invariant");
        _fundDeal(dealId, 100, 0);
        _enterDeficit(50);
        bytes32 dealPosition = _dealPosId(dealId);
        bytes32 terminalHash = keccak256("terminal-active-accounting-invariant");
        TerminalAllocation[] memory allocations = new TerminalAllocation[](1);
        allocations[0] = TerminalAllocation({
            beneficiary: holderReceiver,
            amount: 100,
            positionId: _termPosId(dealId, terminalHash, holderReceiver)
        });

        harness.setActiveDeficitAccounting(
            dealPosition, 0, 1, ledger.deficitGeneration(address(token))
        );
        vm.expectRevert(PositionNotSplittable.selector);
        ledger.settleDealAndReservations(dealId, address(token), terminalHash, allocations);

        harness.setActiveDeficitAccounting(
            dealPosition, 1, 0, ledger.deficitGeneration(address(token))
        );
        vm.expectRevert(PositionNotSplittable.selector);
        ledger.settleDealAndReservations(dealId, address(token), terminalHash, allocations);
    }

    function test_withdraw_paysBeneficiary() public {
        bytes32 dealId = keccak256("deal6");
        _fundDeal(dealId, 100e18, 0);

        bytes32 terminalHash = keccak256("terminal");
        TerminalAllocation[] memory allocs = new TerminalAllocation[](1);
        allocs[0] = TerminalAllocation({
            beneficiary: holderReceiver,
            amount: 100e18,
            positionId: _termPosId(dealId, terminalHash, holderReceiver)
        });

        vm.prank(escrow);
        ledger.settleDealAndReservations(dealId, address(token), terminalHash, allocs);

        // Withdraw
        bytes32 holderTerm = _termPosId(dealId, terminalHash, holderReceiver);
        ledger.withdrawPosition(holderTerm, type(uint256).max);

        assertEq(token.balanceOf(holderReceiver), 100e18);
        assertTrue(ledger.positionConsumed(holderTerm));
        assertEq(ledger.accountedAssets(address(token)), 0);
        assertEq(ledger.nominalOutstanding(address(token)), 0);
    }

    function test_withdraw_activePosition_reverts() public {
        bytes32 dealId = keccak256("deal7");
        _fundDeal(dealId, 100e18, 0);

        // DEAL position is active, not withdrawable
        bytes32 dealPos = _dealPosId(dealId);
        vm.expectRevert(PositionNotClaimable.selector);
        ledger.withdrawPosition(dealPos, type(uint256).max);
    }

    function test_withdraw_nonexistent_reverts() public {
        vm.expectRevert(PositionNotFound.selector);
        ledger.withdrawPosition(bytes32(uint256(999)), type(uint256).max);
    }

    function test_reconciliation_surplusQuarantined() public {
        bytes32 dealId = keccak256("deal8");
        _fundDeal(dealId, 100e18, 0);

        // Send extra tokens to ledger (simulating a surplus)
        token.mint(address(ledger), 10e18);

        // Next preflight should quarantine the surplus
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        vm.prank(escrow);
        uint8[] memory statuses = ledger.preflightValueAction(tokens);
        assertEq(statuses[0], ReconciliationStatus.SurplusQuarantined);
        assertEq(ledger.quarantinedSurplus(address(token)), 10e18);
        assertEq(ledger.accountedAssets(address(token)), 100e18); // unchanged
    }

    function test_checkpointBoundary_unchangedReturnsStatusWithoutEvent() public {
        assertEq(ledger.boundaryCheckpointId(address(token)), bytes32(0));
        vm.recordLogs();
        uint8 status = ledger.checkpointBoundary(address(token));

        assertEq(status, ReconciliationStatus.Unchanged);
        _assertReconciliationLogs(0, "");
        assertEq(ledger.accountedAssets(address(token)), 0);
        assertEq(ledger.quarantinedSurplus(address(token)), 0);
    }

    function test_checkpointBoundary_surplusReturnsStatusAndPersistsQuarantine() public {
        _fundDeal(keccak256("checkpoint-surplus"), 100, 0);
        token.mint(address(ledger), 10);

        vm.recordLogs();
        uint8 status = ledger.checkpointBoundary(address(token));

        assertEq(status, ReconciliationStatus.SurplusQuarantined);
        bytes32 checkpointId = ledger.boundaryCheckpointId(address(token));
        assertEq(checkpointId, bytes32(0));
        _assertReconciliationLogs(
            1,
            abi.encode(
                ReconciliationStatus.SurplusQuarantined, 100, 110, 100, 100, 0, 10, checkpointId
            )
        );
        assertEq(ledger.accountedAssets(address(token)), 100);
        assertEq(ledger.quarantinedSurplus(address(token)), 10);
    }

    function test_checkpointBoundary_lossBelowQuarantineReturnsStatusThreeAndPersists() public {
        _fundDeal(keccak256("checkpoint-quarantine-partial"), 100, 0);
        token.burn(address(ledger), 50);
        assertEq(
            ledger.checkpointBoundary(address(token)), ReconciliationStatus.DeficitCheckpointed
        );
        bytes32 checkpointBefore = ledger.boundaryCheckpointId(address(token));
        assertNotEq(checkpointBefore, bytes32(0));
        assertEq(checkpointBefore, _expectedBoundaryCheckpointId());

        token.mint(address(ledger), 10);
        vm.recordLogs();
        assertEq(ledger.checkpointBoundary(address(token)), ReconciliationStatus.SurplusQuarantined);
        assertEq(ledger.boundaryCheckpointId(address(token)), checkpointBefore);
        _assertReconciliationLogs(
            1,
            abi.encode(
                ReconciliationStatus.SurplusQuarantined, 50, 60, 50, 50, 0, 10, checkpointBefore
            )
        );
        token.burn(address(ledger), 4);

        vm.recordLogs();
        uint8 status = ledger.checkpointBoundary(address(token));

        assertEq(status, ReconciliationStatus.QuarantineLossAbsorbed);
        bytes32 checkpointAfter = ledger.boundaryCheckpointId(address(token));
        assertEq(checkpointAfter, checkpointBefore);
        _assertReconciliationLogs(
            1,
            abi.encode(
                ReconciliationStatus.QuarantineLossAbsorbed, 60, 56, 50, 50, 10, 6, checkpointAfter
            )
        );
        assertEq(ledger.accountedAssets(address(token)), 50);
        assertEq(ledger.quarantinedSurplus(address(token)), 6);
        assertTrue(ledger.inDeficit(address(token)));
    }

    function test_checkpointBoundary_lossEqualToQuarantineReturnsStatusThreeAndPersists() public {
        _fundDeal(keccak256("checkpoint-quarantine-exact"), 100, 0);
        token.mint(address(ledger), 10);
        assertEq(_preflightToken(), ReconciliationStatus.SurplusQuarantined);
        token.burn(address(ledger), 10);

        vm.recordLogs();
        uint8 status = ledger.checkpointBoundary(address(token));

        assertEq(status, ReconciliationStatus.QuarantineLossAbsorbed);
        bytes32 checkpointId = ledger.boundaryCheckpointId(address(token));
        assertEq(checkpointId, bytes32(0));
        _assertReconciliationLogs(
            1,
            abi.encode(
                ReconciliationStatus.QuarantineLossAbsorbed, 110, 100, 100, 100, 10, 0, checkpointId
            )
        );
        assertEq(ledger.accountedAssets(address(token)), 100);
        assertEq(ledger.quarantinedSurplus(address(token)), 0);
        assertFalse(ledger.inDeficit(address(token)));
    }

    function test_checkpointBoundary_residualLossReturnsStatusFourAndPersistsDeficit() public {
        _fundDeal(keccak256("checkpoint-residual-loss"), 100, 0);
        token.burn(address(ledger), 50);
        assertEq(
            ledger.checkpointBoundary(address(token)), ReconciliationStatus.DeficitCheckpointed
        );
        bytes32 checkpointBefore = ledger.boundaryCheckpointId(address(token));
        assertNotEq(checkpointBefore, bytes32(0));

        token.mint(address(ledger), 10);
        assertEq(ledger.checkpointBoundary(address(token)), ReconciliationStatus.SurplusQuarantined);
        assertEq(ledger.boundaryCheckpointId(address(token)), checkpointBefore);
        token.burn(address(ledger), 15);

        vm.recordLogs();
        uint8 status = ledger.checkpointBoundary(address(token));

        assertEq(status, ReconciliationStatus.DeficitCheckpointed);
        bytes32 checkpointAfter = ledger.boundaryCheckpointId(address(token));
        assertNotEq(checkpointAfter, checkpointBefore);
        assertEq(checkpointAfter, _expectedBoundaryCheckpointId());
        Vm.Log[] memory logs = _assertReconciliationLogs(
            2,
            abi.encode(
                ReconciliationStatus.DeficitCheckpointed, 60, 45, 50, 45, 10, 0, checkpointAfter
            )
        );
        _assertLossCheckpointedLog(
            logs[1],
            address(ledger),
            address(token),
            checkpointAfter,
            _currentLossCheckpointFixture()
        );
        _assertNoEvent(logs, keccak256("DeficitEntered(address,uint256,uint256)"));
        assertEq(ledger.accountedAssets(address(token)), 45);
        assertEq(ledger.quarantinedSurplus(address(token)), 0);
        assertTrue(ledger.inDeficit(address(token)));
    }

    function test_lossCheckpointed_usesExactAbiFieldOrder() public {
        CreditLedgerInvariantHarness harness =
            new CreditLedgerInvariantHarness(address(this), address(0xC0), uint64(block.chainid));
        bytes32 checkpointId = keccak256("distinct-loss-checkpoint-fixture");
        LossCheckpointFixture memory expected = LossCheckpointFixture({
            accountedAssets: 11,
            nominalOutstanding: 22,
            deficitNominalUnits: 33,
            deficitPaidAssets: 44,
            deficitGapCoefficient: 55,
            deficitHistoryScale: 66,
            deficitHistoryTotal: 77,
            deficitGeneration: 88,
            deficitRoundingDust: 99,
            deficitPrecisionFloor: true
        });

        vm.recordLogs();
        harness.emitLossCheckpointFixture(address(token), checkpointId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 1);
        _assertLossCheckpointedLog(
            logs[0], address(harness), address(token), checkpointId, expected
        );
    }

    function test_checkpointBoundary_entersDeficit() public {
        bytes32 dealId = keccak256("deal9");
        _fundDeal(dealId, 100e18, 0);

        // Burn some tokens (simulating issuer loss)
        token.burn(address(ledger), 50e18);

        // Checkpoint should enter deficit
        ledger.checkpointBoundary(address(token));
        assertTrue(ledger.inDeficit(address(token)));
        assertEq(ledger.boundaryMode(address(token)), BoundaryMode.Deficit);
    }

    function test_fundDeal_inDeficit_reverts() public {
        bytes32 dealId = keccak256("deal10");
        _fundDeal(dealId, 100e18, 0);
        token.burn(address(ledger), 50e18);
        ledger.checkpointBoundary(address(token));

        // New funding should be rejected
        bytes32 dealId2 = keccak256("deal10b");
        token.mint(holder, 100e18);
        vm.prank(holder);
        token.approve(address(ledger), type(uint256).max);

        FundingSpec memory spec =
            _fundingSpec(FundingPurpose.Principal, address(token), 100e18, holder);
        bytes32 specHash = DealHashing.hashFundingSpec(spec);
        FundingAuth memory auth =
            _fundingAuth(bytes32(uint256(2)), specHash, FundingPurpose.Principal, holder, 1);
        bytes memory sig = _signFundingAuth(auth, authorityPk);

        vm.prank(escrow);
        uint8 status = ledger.fundDealAndReservations(
            bytes32(uint256(2)),
            dealId2,
            address(token),
            100e18,
            0,
            feeRecipient,
            spec,
            FundingSpec(0, 0, address(0), 0, address(0), bytes32(0), address(0)),
            auth,
            FundingAuth(bytes32(0), bytes32(0), 0, address(0), 0, 0),
            sig,
            ""
        );
        assertEq(status, ReconciliationStatus.DeficitCheckpointed);
        assertFalse(ledger.positionExists(_dealPosId(dealId2)));
    }

    function test_positionId_collisionRejects() public {
        bytes32 dealId = keccak256("deal11");
        _fundDeal(dealId, 100e18, 0);

        // Try to fund the same deal again → position already exists
        token.mint(holder, 100e18);
        vm.prank(holder);
        token.approve(address(ledger), type(uint256).max);

        FundingSpec memory spec =
            _fundingSpec(FundingPurpose.Principal, address(token), 100e18, holder);
        bytes32 specHash = DealHashing.hashFundingSpec(spec);
        // Use nonce 2 to avoid nonce replay
        FundingAuth memory auth = FundingAuth({
            termsHash: bytes32(uint256(1)),
            fundingSpecHash: specHash,
            purpose: FundingPurpose.Principal,
            authority: holder,
            nonce: 2,
            expiry: uint64(block.timestamp + 1 days)
        });
        bytes memory sig = _signFundingAuth(auth, authorityPk);

        vm.prank(escrow);
        vm.expectRevert(PositionAlreadyExists.selector);
        ledger.fundDealAndReservations(
            bytes32(uint256(1)),
            dealId,
            address(token),
            100e18,
            0,
            feeRecipient,
            spec,
            FundingSpec(0, 0, address(0), 0, address(0), bytes32(0), address(0)),
            auth,
            FundingAuth(bytes32(0), bytes32(0), 0, address(0), 0, 0),
            sig,
            ""
        );
    }

    function _createMaturedHolderPosition(bytes32 dealId) internal returns (bytes32 positionId) {
        _fundDeal(dealId, 100e18, 0);
        bytes32 terminalHash = keccak256(abi.encodePacked("terminal", dealId));
        positionId = _termPosId(dealId, terminalHash, holder);
        TerminalAllocation[] memory allocations = new TerminalAllocation[](1);
        allocations[0] =
            TerminalAllocation({beneficiary: holder, amount: 100e18, positionId: positionId});
        vm.prank(escrow);
        ledger.settleDealAndReservations(dealId, address(token), terminalHash, allocations);
    }

    function test_ledgerPositionFundingPreservesBoundaryTotals() public {
        bytes32 sourcePositionId = _createMaturedHolderPosition(keccak256("source-position"));
        assertEq(ledger.positionBeneficiary(sourcePositionId), holder);
        uint256 assetsBefore = ledger.accountedAssets(address(token));
        uint256 nominalBefore = ledger.nominalOutstanding(address(token));
        uint256 balanceBefore = token.balanceOf(address(ledger));

        FundingSpec memory principalSpec =
            _fundingSpec(FundingPurpose.Principal, address(token), 40e18, holder);
        principalSpec.sourceMode = FundingSourceMode.LedgerPosition;
        principalSpec.sourcePositionId = sourcePositionId;
        bytes32 termsHash = keccak256("same-vault-terms");
        FundingAuth memory principalAuth = _fundingAuth(
            termsHash,
            DealHashing.hashFundingSpec(principalSpec),
            FundingPurpose.Principal,
            holder,
            100
        );

        bytes memory signature = _signFundingAuth(principalAuth, authorityPk);
        vm.prank(escrow);
        uint8 status = ledger.fundDealAndReservations(
            termsHash,
            keccak256("same-vault-deal"),
            address(token),
            40e18,
            0,
            feeRecipient,
            principalSpec,
            FundingSpec(0, 0, address(0), 0, address(0), bytes32(0), address(0)),
            principalAuth,
            FundingAuth(bytes32(0), bytes32(0), 0, address(0), 0, 0),
            signature,
            ""
        );

        assertEq(status, ReconciliationStatus.Unchanged);
        assertEq(ledger.accountedAssets(address(token)), assetsBefore);
        assertEq(ledger.nominalOutstanding(address(token)), nominalBefore);
        assertEq(token.balanceOf(address(ledger)), balanceBefore);
        assertEq(ledger.positionNominal(sourcePositionId), 60e18);
        _assertComponents(sourcePositionId, 60e18, 60e18, 0, 60e18, 0);
    }

    function test_ledgerPositionFundingRejectsAmountAboveSourceNominal() public {
        bytes32 sourcePositionId =
            _createMaturedHolderPosition(keccak256("insufficient-source-position"));
        FundingSpec memory principalSpec =
            _fundingSpec(FundingPurpose.Principal, address(token), 100e18 + 1, holder);
        principalSpec.sourceMode = FundingSourceMode.LedgerPosition;
        principalSpec.sourcePositionId = sourcePositionId;
        FundingCall memory call = _prepareFundingCall(
            keccak256("insufficient-source-destination"),
            principalSpec,
            _fundingSpec(FundingPurpose.ActivationFee, address(token), 0, holder),
            101,
            102
        );

        vm.expectRevert(InvalidAmount.selector);
        _callFunding(call);

        assertEq(ledger.positionNominal(sourcePositionId), 100e18);
        assertFalse(ledger.positionExists(_dealPosId(call.dealId)));
    }

    function test_ledgerPositionActiveDealRejected() public {
        bytes32 sourceDeal = keccak256("active-source");
        _fundDeal(sourceDeal, 100e18, 0);
        bytes32 activePositionId = _dealPosId(sourceDeal);
        FundingSpec memory spec =
            _fundingSpec(FundingPurpose.Principal, address(token), 1e18, holder);
        spec.sourceMode = FundingSourceMode.LedgerPosition;
        spec.sourcePositionId = activePositionId;
        bytes32 termsHash = keccak256("active-position-terms");
        FundingAuth memory auth = _fundingAuth(
            termsHash, DealHashing.hashFundingSpec(spec), FundingPurpose.Principal, holder, 100
        );

        bytes memory signature = _signFundingAuth(auth, authorityPk);
        vm.prank(escrow);
        vm.expectRevert(InvalidPositionKind.selector);
        ledger.fundDealAndReservations(
            termsHash,
            keccak256("active-position-deal"),
            address(token),
            1e18,
            0,
            feeRecipient,
            spec,
            FundingSpec(0, 0, address(0), 0, address(0), bytes32(0), address(0)),
            auth,
            FundingAuth(bytes32(0), bytes32(0), 0, address(0), 0, 0),
            signature,
            ""
        );
    }

    function test_preflightRejectsDuplicateTokens() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(token);
        tokens[1] = address(token);
        vm.prank(escrow);
        vm.expectRevert(InvalidTokenList.selector);
        ledger.preflightValueAction(tokens);
    }

    function test_signedPayoutBindsActionAndTokenAndConsumesNonceAfterPayment() public {
        bytes32 positionId = _createMaturedHolderPosition(keccak256("signed-payout"));
        uint256 nonce = 200;
        uint64 expiry = uint64(block.timestamp + 1 days);
        PositionPayoutAuth memory auth = PositionPayoutAuth({
            action: 1,
            token: address(token),
            positionId: positionId,
            beneficiary: holder,
            to: providerReceiver,
            maxAmount: 40e18,
            nonce: nonce,
            expiry: expiry
        });
        bytes32 typeHash = keccak256(
            "PositionPayoutAuth(uint8 action,address token,bytes32 positionId,address beneficiary,address to,uint256 maxAmount,uint256 nonce,uint64 expiry)"
        );
        bytes32 digest_ = DealHashing.digest(
            ledger.DOMAIN_SEPARATOR(),
            keccak256(
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
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(holderPk, digest_);
        bytes memory signature = abi.encodePacked(r, s, v);

        PositionPayoutResult memory result = ledger.withdrawPositionTo(auth, signature);
        assertEq(result.code, 1);
        assertEq(result.reconciliationStatus, ReconciliationStatus.Unchanged);
        assertEq(result.positionId, positionId);
        assertEq(result.receiver, providerReceiver);
        assertEq(result.paidAmount, 40e18);
        assertEq(result.nominalRemaining, 60e18);

        vm.expectRevert(NonceUsed.selector);
        ledger.withdrawPositionTo(auth, signature);
    }

    function test_withdrawPositionTo_rejectsCoordinatorReceiver() public {
        bytes32 positionId = _createMaturedHolderPosition(keccak256("coordinator-payout"));
        PositionPayoutAuth memory auth = PositionPayoutAuth({
            action: 1,
            token: address(token),
            positionId: positionId,
            beneficiary: holder,
            to: address(deployer.coordinator()),
            maxAmount: 40e18,
            nonce: 202,
            expiry: uint64(block.timestamp + 1 days)
        });
        bytes memory signature = _signPayout(auth);

        vm.expectRevert(SelfReceiver.selector);
        ledger.withdrawPositionTo(auth, signature);

        assertEq(ledger.positionNominal(positionId), 100e18);
    }

    function test_signedPayoutZeroAmountDoesNotBurnNonce() public {
        bytes32 positionId = _createMaturedHolderPosition(keccak256("zero-payout"));
        PositionPayoutAuth memory auth = PositionPayoutAuth({
            action: 1,
            token: address(token),
            positionId: positionId,
            beneficiary: holder,
            to: providerReceiver,
            maxAmount: 0,
            nonce: 201,
            expiry: uint64(block.timestamp + 1 days)
        });
        vm.expectRevert(InvalidAmount.selector);
        ledger.withdrawPositionTo(auth, "");
    }

    function test_signedPayout_failedTransferRollsBackForRetry() public {
        bytes32 positionId = _createMaturedHolderPosition(keccak256("failed-transfer-retry"));
        address receiver = address(0x3333);
        token.setTransferRevert(receiver, true);

        PositionPayoutAuth memory auth = PositionPayoutAuth({
            action: 1,
            token: address(token),
            positionId: positionId,
            beneficiary: holder,
            to: receiver,
            maxAmount: type(uint256).max,
            nonce: 777,
            expiry: uint64(block.timestamp + 1 days)
        });
        bytes memory signature = _signPayout(auth);

        vm.expectRevert();
        ledger.withdrawPositionTo(auth, signature);

        assertEq(ledger.positionNominal(positionId), 100e18);
        assertFalse(ledger.positionConsumed(positionId));
        assertEq(token.balanceOf(receiver), 0);

        token.setTransferRevert(receiver, false);
        PositionPayoutResult memory result = ledger.withdrawPositionTo(auth, signature);
        assertEq(result.code, PayoutResultCode.HealthyFull);
        assertEq(result.paidAmount, 100e18);
        assertEq(result.nominalRemaining, 0);
        assertTrue(ledger.positionConsumed(positionId));
        assertEq(token.balanceOf(receiver), 100e18);
    }

    function _createSplitMaturedPositions(bytes32 dealId)
        internal
        returns (bytes32 holderPosition, bytes32 providerPosition)
    {
        _fundDeal(dealId, 100, 0);
        bytes32 terminalHash = keccak256(abi.encodePacked("deficit-terminal", dealId));
        holderPosition = _termPosId(dealId, terminalHash, holderReceiver);
        providerPosition = _termPosId(dealId, terminalHash, providerReceiver);
        TerminalAllocation[] memory allocations = new TerminalAllocation[](2);
        allocations[0] = TerminalAllocation({
            beneficiary: holderReceiver, amount: 60, positionId: holderPosition
        });
        allocations[1] = TerminalAllocation({
            beneficiary: providerReceiver, amount: 40, positionId: providerPosition
        });
        vm.prank(escrow);
        ledger.settleDealAndReservations(dealId, address(token), terminalHash, allocations);
    }

    function _enterDeficit(uint256 lostAmount) internal {
        token.burn(address(ledger), lostAmount);
        ledger.checkpointBoundary(address(token));
    }

    function _preflightToken() internal returns (uint8 status) {
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        vm.prank(escrow);
        uint8[] memory statuses = ledger.preflightValueAction(tokens);
        return statuses[0];
    }

    function _expectedBoundaryCheckpointId() internal view returns (bytes32) {
        if (!ledger.inDeficit(address(token))) return bytes32(0);
        return _expectedBoundaryCheckpointIdWithDust(ledger.deficitRoundingDust(address(token)));
    }

    function _expectedBoundaryCheckpointIdWithDust(uint256 roundingDust)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            bytes.concat(
                abi.encode(
                    keccak256(
                        "BoundaryCheckpointV1(uint64 chainId,address ledger,address token,uint256 accountedAssets,uint256 nominalOutstanding,uint256 deficitNominalUnits,uint256 deficitPaidAssets,uint256 deficitGapCoefficient,uint256 deficitHistoryScale,uint256 deficitHistoryTotal,uint256 deficitGeneration,uint256 deficitRoundingDust,bool deficitPrecisionFloor)"
                    ),
                    ledger.chainId(),
                    address(ledger),
                    address(token),
                    ledger.accountedAssets(address(token)),
                    ledger.nominalOutstanding(address(token)),
                    ledger.deficitNominalUnits(address(token))
                ),
                abi.encode(
                    ledger.deficitPaidAssets(address(token)),
                    ledger.deficitGapCoefficient(address(token)),
                    ledger.deficitHistoryScale(address(token)),
                    ledger.deficitHistoryTotal(address(token)),
                    ledger.deficitGeneration(address(token)),
                    roundingDust,
                    ledger.deficitPrecisionFloor(address(token))
                )
            )
        );
    }

    function _assertReconciliationLogs(uint256 expectedCount, bytes memory expectedData)
        internal
        view
        returns (Vm.Log[] memory logs)
    {
        logs = vm.getRecordedLogs();
        assertEq(logs.length, expectedCount);
        if (expectedCount == 0) return logs;
        assertEq(logs[0].emitter, address(ledger));
        assertEq(logs[0].topics.length, 2);
        assertEq(
            logs[0].topics[0],
            keccak256(
                "BoundaryReconciled(address,uint8,uint256,uint256,uint256,uint256,uint256,uint256,bytes32)"
            )
        );
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(address(token)))));
        assertEq(logs[0].data, expectedData);
    }

    function _assertNoEvent(Vm.Log[] memory logs, bytes32 forbiddenSignature) internal pure {
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(
                logs[i].topics.length == 0 || logs[i].topics[0] != forbiddenSignature,
                "forbidden event emitted"
            );
        }
    }

    function _assertInitialDeficitEntryLogs(bytes32 checkpointId) internal view {
        Vm.Log[] memory logs = _assertReconciliationLogs(
            2,
            abi.encode(
                ReconciliationStatus.DeficitCheckpointed,
                MAX_BOUNDARY_NOMINAL,
                MAX_BOUNDARY_NOMINAL - 1,
                MAX_BOUNDARY_NOMINAL,
                MAX_BOUNDARY_NOMINAL - 1,
                0,
                0,
                checkpointId
            )
        );
        assertEq(logs[1].emitter, address(ledger));
        assertEq(logs[1].topics.length, 2);
        assertEq(logs[1].topics[0], keccak256("DeficitEntered(address,uint256,uint256)"));
        assertEq(logs[1].topics[1], bytes32(uint256(uint160(address(token)))));
        assertEq(logs[1].data, abi.encode(MAX_BOUNDARY_NOMINAL, MAX_BOUNDARY_NOMINAL - 1));
        _assertNoEvent(
            logs,
            keccak256(
                "LossCheckpointed(address,bytes32,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,bool)"
            )
        );
    }

    function _assertLossCheckpointedLog(
        Vm.Log memory log,
        address expectedEmitter,
        address expectedToken,
        bytes32 checkpointId,
        LossCheckpointFixture memory expected
    ) internal pure {
        assertEq(log.emitter, expectedEmitter);
        assertEq(log.topics.length, 3);
        assertEq(
            log.topics[0],
            keccak256(
                "LossCheckpointed(address,bytes32,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,bool)"
            )
        );
        assertEq(log.topics[1], bytes32(uint256(uint160(expectedToken))));
        assertEq(log.topics[2], checkpointId);
        assertEq(
            log.data,
            abi.encode(
                expected.accountedAssets,
                expected.nominalOutstanding,
                expected.deficitNominalUnits,
                expected.deficitPaidAssets,
                expected.deficitGapCoefficient,
                expected.deficitHistoryScale,
                expected.deficitHistoryTotal,
                expected.deficitGeneration,
                expected.deficitRoundingDust,
                expected.deficitPrecisionFloor
            )
        );
    }

    function _currentLossCheckpointFixture()
        internal
        view
        returns (LossCheckpointFixture memory expected)
    {
        expected.accountedAssets = ledger.accountedAssets(address(token));
        expected.nominalOutstanding = ledger.nominalOutstanding(address(token));
        expected.deficitNominalUnits = ledger.deficitNominalUnits(address(token));
        expected.deficitPaidAssets = ledger.deficitPaidAssets(address(token));
        expected.deficitGapCoefficient = ledger.deficitGapCoefficient(address(token));
        expected.deficitHistoryScale = ledger.deficitHistoryScale(address(token));
        expected.deficitHistoryTotal = ledger.deficitHistoryTotal(address(token));
        expected.deficitGeneration = ledger.deficitGeneration(address(token));
        expected.deficitRoundingDust = ledger.deficitRoundingDust(address(token));
        expected.deficitPrecisionFloor = ledger.deficitPrecisionFloor(address(token));
    }

    function _approveRecovery(uint256 amount) internal {
        token.mint(address(this), amount);
        token.approve(address(ledger), amount);
    }

    function _signPayout(PositionPayoutAuth memory auth) internal view returns (bytes memory) {
        bytes32 typeHash = keccak256(
            "PositionPayoutAuth(uint8 action,address token,bytes32 positionId,address beneficiary,address to,uint256 maxAmount,uint256 nonce,uint64 expiry)"
        );
        bytes32 digest_ = DealHashing.digest(
            ledger.DOMAIN_SEPARATOR(),
            keccak256(
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
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(holderPk, digest_);
        return abi.encodePacked(r, s, v);
    }

    function test_recoveryClaimsUseConservativeProRataAndZeroVaultBalance() public {
        (bytes32 holderPosition, bytes32 providerPosition) =
            _createSplitMaturedPositions(keccak256("recovery-pro-rata"));
        _enterDeficit(50);

        _approveRecovery(25);
        ledger.depositRecovery(address(token), 25);

        PositionPayoutResult memory holderResult =
            ledger.claimRecovery(holderPosition, type(uint256).max);
        PositionPayoutResult memory providerResult =
            ledger.claimRecovery(providerPosition, type(uint256).max);

        assertEq(holderResult.code, 3);
        assertEq(providerResult.code, 3);
        assertEq(holderResult.paidAmount, 45);
        assertEq(providerResult.paidAmount, 30);
        assertEq(ledger.deficitPaidAssets(address(token)), 75);
        assertEq(ledger.accountedAssets(address(token)), 0);
        assertEq(ledger.nominalOutstanding(address(token)), 25);
        assertEq(token.balanceOf(address(ledger)), 0);
        assertEq(ledger.positionNominal(holderPosition), 60);
        assertEq(ledger.positionNominal(providerPosition), 40);
    }

    function test_recoveryFullDepositMakesAllRemainingUnitsClaimable() public {
        (bytes32 holderPosition, bytes32 providerPosition) =
            _createSplitMaturedPositions(keccak256("recovery-full"));
        _enterDeficit(50);

        _approveRecovery(50);
        ledger.depositRecovery(address(token), 50);

        ledger.claimRecovery(holderPosition, type(uint256).max);
        ledger.claimRecovery(providerPosition, type(uint256).max);

        assertEq(token.balanceOf(address(holderReceiver)), 60);
        assertEq(token.balanceOf(address(providerReceiver)), 40);
        assertEq(ledger.accountedAssets(address(token)), 0);
        assertEq(ledger.nominalOutstanding(address(token)), 0);
        assertTrue(ledger.positionConsumed(holderPosition));
        assertTrue(ledger.positionConsumed(providerPosition));
    }

    function test_recoveryCheckpointAfterClaimDoesNotClawBackPaidValue() public {
        (bytes32 holderPosition, bytes32 providerPosition) =
            _createSplitMaturedPositions(keccak256("recovery-repeated-loss"));
        _enterDeficit(50);

        _approveRecovery(25);
        ledger.depositRecovery(address(token), 25);
        PositionPayoutResult memory holderResult =
            ledger.claimRecovery(holderPosition, type(uint256).max);
        assertEq(holderResult.paidAmount, 45);

        token.burn(address(ledger), 15);
        PositionPayoutResult memory checkpoint =
            ledger.claimRecovery(providerPosition, type(uint256).max);
        assertEq(checkpoint.code, 6);
        assertEq(checkpoint.reconciliationStatus, ReconciliationStatus.DeficitCheckpointed);
        assertEq(token.balanceOf(holderReceiver), 45);

        PositionPayoutResult memory providerResult =
            ledger.claimRecovery(providerPosition, type(uint256).max);
        assertEq(providerResult.code, 3);
        assertEq(providerResult.paidAmount, 15);
        assertEq(token.balanceOf(holderReceiver), 45);
        assertEq(token.balanceOf(providerReceiver), 15);
        assertEq(ledger.accountedAssets(address(token)), 0);
        assertEq(ledger.nominalOutstanding(address(token)), 40);
    }

    function test_recoveryFullLossAndRecoveryStartsNewGeneration() public {
        (bytes32 holderPosition, bytes32 providerPosition) =
            _createSplitMaturedPositions(keccak256("recovery-generation"));
        _enterDeficit(100);
        assertEq(ledger.accountedAssets(address(token)), 0);

        _approveRecovery(100);
        uint8 status = ledger.depositRecovery(address(token), 100);
        assertEq(status, ReconciliationStatus.Unchanged);
        assertEq(ledger.deficitGapCoefficient(address(token)), 0);
        assertEq(ledger.deficitHistoryTotal(address(token)), 0);

        ledger.claimRecovery(holderPosition, type(uint256).max);
        ledger.claimRecovery(providerPosition, type(uint256).max);
        assertEq(token.balanceOf(holderReceiver), 60);
        assertEq(token.balanceOf(providerReceiver), 40);
        assertEq(ledger.nominalOutstanding(address(token)), 0);
    }

    function test_settlementInDeficitPreservesBoundaryExposure() public {
        bytes32 dealId = keccak256("recovery-settlement");
        _fundDeal(dealId, 100, 0);
        _enterDeficit(50);

        bytes32 terminalHash = keccak256("recovery-settlement-terminal");
        bytes32 holderPosition = _termPosId(dealId, terminalHash, holderReceiver);
        bytes32 providerPosition = _termPosId(dealId, terminalHash, providerReceiver);
        TerminalAllocation[] memory allocations = new TerminalAllocation[](2);
        allocations[0] = TerminalAllocation({
            beneficiary: holderReceiver, amount: 60, positionId: holderPosition
        });
        allocations[1] = TerminalAllocation({
            beneficiary: providerReceiver, amount: 40, positionId: providerPosition
        });

        vm.prank(escrow);
        uint8 status =
            ledger.settleDealAndReservations(dealId, address(token), terminalHash, allocations);
        assertEq(status, ReconciliationStatus.Unchanged);
        assertEq(ledger.nominalOutstanding(address(token)), 100);
        assertEq(ledger.accountedAssets(address(token)), 50);
        assertEq(ledger.positionNominal(holderPosition), 60);
        assertEq(ledger.positionNominal(providerPosition), 40);
    }

    function test_recoveryRejectsOverDepositAndCannotStartHealthy() public {
        vm.expectRevert(DeficitNotActive.selector);
        ledger.depositRecovery(address(token), 1);

        _createMaturedHolderPosition(keccak256("recovery-overdeposit"));
        _enterDeficit(50e18);
        _approveRecovery(50e18 + 1);
        vm.expectRevert(RecoveryExceedsGap.selector);
        ledger.depositRecovery(address(token), 50e18 + 1);
        assertEq(ledger.accountedAssets(address(token)), 50e18);
        assertEq(token.balanceOf(address(ledger)), 50e18);
    }

    function test_claimRecoveryTo_rejectsCoordinatorReceiver() public {
        bytes32 positionId = _createMaturedHolderPosition(keccak256("coordinator-recovery-payout"));
        _enterDeficit(50e18);
        PositionPayoutAuth memory auth = PositionPayoutAuth({
            action: 2,
            token: address(token),
            positionId: positionId,
            beneficiary: holder,
            to: address(deployer.coordinator()),
            maxAmount: 50e18,
            nonce: 901,
            expiry: uint64(block.timestamp + 1 days)
        });
        bytes memory signature = _signPayout(auth);

        vm.expectRevert(SelfReceiver.selector);
        ledger.claimRecoveryTo(auth, signature);

        assertEq(ledger.positionNominal(positionId), 100e18);
        assertEq(ledger.deficitPaidAssets(address(token)), 0);
    }

    function test_coreContractsRejectEtherByDefault() public {
        vm.deal(address(this), 4);
        address[2] memory targets = [address(ledger), escrow];

        for (uint256 i; i < targets.length; ++i) {
            (bool receiveSuccess,) = targets[i].call{value: 1}("");
            (bool fallbackSuccess,) = targets[i].call{value: 1}(hex"deadbeef");
            assertFalse(receiveSuccess);
            assertFalse(fallbackSuccess);
            assertEq(targets[i].balance, 0);
        }
    }

    function test_recoveryAttackerCannotSpendVictimLingeringLedgerAllowance() public {
        _createMaturedHolderPosition(keccak256("recovery-victim-allowance"));
        _enterDeficit(50e18);

        address attacker = address(0xBAD);
        uint256 victimBalance = 20e18;
        uint256 victimAllowance = 15e18;
        uint256 recoveryAmount = 10e18;
        token.mint(holder, victimBalance);
        vm.prank(holder);
        token.approve(address(ledger), victimAllowance);

        vm.prank(attacker);
        (bool relayedCallSucceeded,) = address(ledger)
            .call(
                abi.encodeWithSignature(
                    "depositRecovery(address,address,uint256)",
                    address(token),
                    holder,
                    recoveryAmount
                )
            );
        assertFalse(relayedCallSucceeded, "legacy relayed recovery remained callable");

        vm.prank(attacker);
        vm.expectRevert(ExactTransferFailed.selector);
        ledger.depositRecovery(address(token), recoveryAmount);

        assertEq(token.balanceOf(holder), victimBalance);
        assertEq(token.allowance(holder, address(ledger)), victimAllowance);
        assertEq(token.balanceOf(attacker), 0);
    }

    function test_recoveryPullsExactlyFromCaller() public {
        _createMaturedHolderPosition(keccak256("recovery-caller-funded"));
        _enterDeficit(50e18);

        address donor = address(0xD0A0);
        token.mint(donor, 15e18);
        vm.prank(donor);
        token.approve(address(ledger), 15e18);

        vm.prank(donor);
        uint8 status = ledger.depositRecovery(address(token), 10e18);

        assertEq(status, ReconciliationStatus.Unchanged);
        assertEq(token.balanceOf(donor), 5e18);
        assertEq(token.allowance(donor, address(ledger)), 5e18);
        assertEq(token.balanceOf(address(ledger)), 60e18);
        assertEq(ledger.accountedAssets(address(token)), 60e18);
    }

    function test_recoveryStatusFourCheckpointsBeforePull() public {
        _createMaturedHolderPosition(keccak256("recovery-status-four"));
        _enterDeficit(50e18);

        address donor = address(0xD0A0);
        token.mint(donor, 10e18);
        vm.prank(donor);
        token.approve(address(ledger), 10e18);
        token.burn(address(ledger), 10e18);

        vm.prank(donor);
        uint8 status = ledger.depositRecovery(address(token), 10e18);

        assertEq(status, ReconciliationStatus.DeficitCheckpointed);
        assertEq(token.balanceOf(donor), 10e18);
        assertEq(token.allowance(donor, address(ledger)), 10e18);
        assertEq(token.balanceOf(address(ledger)), 40e18);
        assertEq(ledger.accountedAssets(address(token)), 40e18);
    }

    function test_recoveryFailedPullRollsBackReconciliation() public {
        _createMaturedHolderPosition(keccak256("recovery-pull-rollback"));
        _enterDeficit(50e18);

        address donor = address(0xD0A0);
        token.mint(donor, 10e18);
        token.mint(address(ledger), 5e18);

        vm.prank(donor);
        vm.expectRevert(ExactTransferFailed.selector);
        ledger.depositRecovery(address(token), 10e18);

        assertEq(token.balanceOf(donor), 10e18);
        assertEq(token.balanceOf(address(ledger)), 55e18);
        assertEq(ledger.accountedAssets(address(token)), 50e18);
        assertEq(ledger.quarantinedSurplus(address(token)), 0);
    }

    function test_reconciliationOnlyDoesNotConsumeRecoveryNonce() public {
        bytes32 positionId = _createMaturedHolderPosition(keccak256("recovery-reconcile"));
        _enterDeficit(50);

        PositionPayoutAuth memory auth = PositionPayoutAuth({
            action: 2,
            token: address(token),
            positionId: positionId,
            beneficiary: holder,
            to: providerReceiver,
            maxAmount: 60,
            nonce: 900,
            expiry: uint64(block.timestamp + 1 days)
        });
        bytes memory signature = _signPayout(auth);

        token.burn(address(ledger), 10);
        PositionPayoutResult memory reconciliation = ledger.claimRecoveryTo(auth, signature);
        assertEq(reconciliation.code, 6);
        assertEq(reconciliation.reconciliationStatus, ReconciliationStatus.DeficitCheckpointed);
        assertEq(token.balanceOf(providerReceiver), 0);

        _approveRecovery(60);
        ledger.depositRecovery(address(token), 60);
        PositionPayoutResult memory paid = ledger.claimRecoveryTo(auth, signature);
        assertEq(paid.code, 3);
        assertEq(paid.paidAmount, 60);

        vm.expectRevert(NonceUsed.selector);
        ledger.claimRecoveryTo(auth, signature);
    }

    function test_getPosition_missingReturnsCanonicalZeroView() public view {
        bytes32 missingPositionId = keccak256("missing-position");
        PositionView memory position = ledger.getPosition(missingPositionId);

        assertEq(position.positionId, missingPositionId);
        assertFalse(position.exists);
        assertFalse(position.consumed);
        assertFalse(position.replaced);
        assertEq(position.replacementRoundingDust, 0);
        assertEq(position.kind, 0);
        assertEq(position.sourceId, bytes32(0));
        assertEq(position.terminalHash, bytes32(0));
        assertEq(position.beneficiary, address(0));
        assertEq(position.token, address(0));
        assertEq(position.deficitHistory, 0);
        assertEq(position.deficitGeneration, 0);
        assertEq(position.boundaryCheckpointId, bytes32(0));
        assertEq(position.boundaryMode, BoundaryMode.Healthy);
        _assertComponents(missingPositionId, 0, 0, 0, 0, 0);
    }

    function test_getPosition_healthyLifecycleTracksStoredNominal() public {
        bytes32 dealId = keccak256("position-view-healthy");
        bytes32 terminalHash = keccak256(abi.encodePacked("terminal", dealId));
        bytes32 positionId = _createMaturedHolderPosition(dealId);

        _assertComponents(positionId, 100e18, 100e18, 0, 100e18, 0);
        PositionView memory livePosition = ledger.getPosition(positionId);
        _assertLifecycle(livePosition, positionId, false, false);
        _assertProvenance(livePosition, PositionKind.DealTerminal, dealId, terminalHash, holder);
        assertEq(livePosition.boundaryMode, BoundaryMode.Healthy);
        assertEq(livePosition.boundaryCheckpointId, bytes32(0));

        ledger.withdrawPosition(positionId, 40e18);
        _assertComponents(positionId, 60e18, 60e18, 0, 60e18, 0);
        PositionView memory partialPosition = ledger.getPosition(positionId);
        _assertLifecycle(partialPosition, positionId, false, false);
        _assertProvenance(partialPosition, PositionKind.DealTerminal, dealId, terminalHash, holder);

        ledger.withdrawPosition(positionId, type(uint256).max);
        _assertComponents(positionId, 0, 0, 0, 0, 0);
        PositionView memory consumedPosition = ledger.getPosition(positionId);
        _assertLifecycle(consumedPosition, positionId, true, false);
        _assertProvenance(consumedPosition, PositionKind.DealTerminal, dealId, terminalHash, holder);
    }

    function test_getPosition_deficitEntryRecoveryAndClaimsPreserveIdentity() public {
        (bytes32 holderPosition, bytes32 providerPosition) =
            _createSplitMaturedPositions(keccak256("position-view-recovery"));

        _assertComponents(holderPosition, 60, 60, 0, 60, 0);
        _assertComponents(providerPosition, 40, 40, 0, 40, 0);

        _enterDeficit(50);
        _assertComponents(holderPosition, 60, 60, 0, 30, 30);
        _assertComponents(providerPosition, 40, 40, 0, 20, 20);
        PositionView memory enteredHolder = ledger.getPosition(holderPosition);
        PositionView memory enteredProvider = ledger.getPosition(providerPosition);
        assertEq(enteredHolder.boundaryMode, BoundaryMode.Deficit);
        assertEq(enteredHolder.boundaryCheckpointId, ledger.boundaryCheckpointId(address(token)));
        assertEq(enteredProvider.boundaryCheckpointId, enteredHolder.boundaryCheckpointId);

        _approveRecovery(25);
        ledger.depositRecovery(address(token), 25);
        _assertComponents(holderPosition, 60, 60, 0, 45, 15);
        _assertComponents(providerPosition, 40, 40, 0, 30, 10);

        _approveRecovery(25);
        ledger.depositRecovery(address(token), 25);
        _assertComponents(holderPosition, 60, 60, 0, 60, 0);
        _assertComponents(providerPosition, 40, 40, 0, 40, 0);

        ledger.claimRecovery(holderPosition, 20);
        _assertComponents(holderPosition, 60, 40, 20, 40, 0);
        PositionView memory partiallyClaimed = ledger.getPosition(holderPosition);
        assertEq(partiallyClaimed.deficitGeneration, ledger.deficitGeneration(address(token)));
        _assertComponents(providerPosition, 40, 40, 0, 40, 0);

        ledger.claimRecovery(holderPosition, type(uint256).max);
        _assertComponents(holderPosition, 60, 0, 60, 0, 0);
        PositionView memory tombstone = ledger.getPosition(holderPosition);
        assertTrue(tombstone.consumed);
        assertEq(tombstone.sourceId, keccak256("position-view-recovery"));
        assertEq(tombstone.beneficiary, holderReceiver);
        assertEq(tombstone.token, address(token));
    }

    function test_getPosition_repeatedLossKeepsPaidAssetsFinal() public {
        (bytes32 holderPosition, bytes32 providerPosition) =
            _createSplitMaturedPositions(keccak256("position-view-repeated-loss"));
        _enterDeficit(50);

        _approveRecovery(25);
        ledger.depositRecovery(address(token), 25);
        ledger.claimRecovery(holderPosition, type(uint256).max);
        _assertComponents(holderPosition, 60, 15, 45, 0, 15);
        PositionView memory claimedHolder = ledger.getPosition(holderPosition);
        assertGt(claimedHolder.deficitHistory, 0);
        assertEq(claimedHolder.deficitGeneration, ledger.deficitGeneration(address(token)));
        _assertComponents(providerPosition, 40, 40, 0, 30, 10);

        token.burn(address(ledger), 15);
        bytes32 checkpointBefore = ledger.boundaryCheckpointId(address(token));
        PositionPayoutResult memory reconciliation =
            ledger.claimRecovery(providerPosition, type(uint256).max);
        assertEq(reconciliation.code, 6);
        assertNotEq(ledger.boundaryCheckpointId(address(token)), checkpointBefore);
        _assertComponents(holderPosition, 60, 15, 45, 0, 15);
        _assertComponents(providerPosition, 40, 40, 0, 15, 25);

        ledger.claimRecovery(providerPosition, type(uint256).max);
        _assertComponents(holderPosition, 60, 15, 45, 0, 15);
        _assertComponents(providerPosition, 40, 25, 15, 0, 25);
    }

    function test_getPosition_terminalSplitBeforeRecoveryConservesComponents() public {
        bytes32 dealId = keccak256("position-view-split-before-recovery");
        _fundDeal(dealId, 100, 0);
        bytes32 dealPosition = _dealPosId(dealId);
        _enterDeficit(50);

        _assertComponents(dealPosition, 100, 100, 0, 50, 50);
        PositionView memory active = ledger.getPosition(dealPosition);
        assertEq(active.kind, PositionKind.ActiveDeal);
        vm.expectRevert(PositionNotClaimable.selector);
        ledger.claimRecovery(dealPosition, type(uint256).max);

        bytes32 terminalHash = keccak256("position-view-split-before-terminal");
        (bytes32 holderPosition, bytes32 providerPosition) =
            _settleSplit(dealId, terminalHash, holderReceiver, providerReceiver);
        _assertComponents(dealPosition, 100, 100, 0, 50, 50);
        PositionView memory parent = ledger.getPosition(dealPosition);
        assertTrue(parent.consumed);
        assertTrue(parent.replaced);
        assertEq(parent.replacementRoundingDust, 0);
        assertEq(parent.terminalHash, terminalHash);
        _assertComponents(holderPosition, 60, 60, 0, 30, 30);
        _assertComponents(providerPosition, 40, 40, 0, 20, 20);

        _approveRecovery(25);
        ledger.depositRecovery(address(token), 25);
        _assertComponents(holderPosition, 60, 60, 0, 45, 15);
        _assertComponents(providerPosition, 40, 40, 0, 30, 10);
    }

    function test_getPosition_terminalSplitAfterRecoveryConservesComponents() public {
        bytes32 dealId = keccak256("position-view-split-after-recovery");
        _fundDeal(dealId, 100, 0);
        bytes32 dealPosition = _dealPosId(dealId);
        _enterDeficit(50);

        _approveRecovery(25);
        ledger.depositRecovery(address(token), 25);
        _assertComponents(dealPosition, 100, 100, 0, 75, 25);

        bytes32 checkpointBefore = ledger.boundaryCheckpointId(address(token));
        bytes32 terminalHash = keccak256("position-view-split-after-terminal");
        (bytes32 holderPosition, bytes32 providerPosition) =
            _settleSplit(dealId, terminalHash, holderReceiver, providerReceiver);

        assertEq(ledger.boundaryCheckpointId(address(token)), checkpointBefore);
        _assertComponents(dealPosition, 100, 100, 0, 75, 25);
        PositionView memory parent = ledger.getPosition(dealPosition);
        assertTrue(parent.replaced);
        assertEq(parent.replacementRoundingDust, 0);
        _assertComponents(holderPosition, 60, 60, 0, 45, 15);
        _assertComponents(providerPosition, 40, 40, 0, 30, 10);
        PositionView memory holderChild = ledger.getPosition(holderPosition);
        PositionView memory providerChild = ledger.getPosition(providerPosition);
        _assertReplacementConservation(parent, holderChild, providerChild);
    }

    function test_getPosition_healthyReplacementFreezesBeforeLaterLossAndRecovery() public {
        bytes32 dealId = keccak256("position-view-healthy-frozen-parent");
        _fundDeal(dealId, 100, 0);
        bytes32 dealPosition = _dealPosId(dealId);
        bytes32 terminalHash = keccak256("position-view-healthy-frozen-parent-terminal");
        (bytes32 holderPosition, bytes32 providerPosition) =
            _settleSplit(dealId, terminalHash, holderReceiver, providerReceiver);

        _assertComponents(dealPosition, 100, 100, 0, 100, 0);
        PositionView memory parent = ledger.getPosition(dealPosition);
        assertTrue(parent.consumed);
        assertTrue(parent.replaced);
        assertEq(parent.replacementRoundingDust, 0);
        PositionView memory holderChild = ledger.getPosition(holderPosition);
        PositionView memory providerChild = ledger.getPosition(providerPosition);
        _assertReplacementConservation(parent, holderChild, providerChild);

        ledger.withdrawPosition(holderPosition, 20);
        _assertComponents(dealPosition, 100, 100, 0, 100, 0);

        token.burn(address(ledger), 40);
        ledger.checkpointBoundary(address(token));
        _assertComponents(dealPosition, 100, 100, 0, 100, 0);
        PositionView memory deficitParent = ledger.getPosition(dealPosition);
        assertEq(deficitParent.boundaryMode, BoundaryMode.Deficit);

        _approveRecovery(40);
        ledger.depositRecovery(address(token), 40);
        _assertComponents(dealPosition, 100, 100, 0, 100, 0);
    }

    function test_getPosition_deficitReplacementFreezesAcrossChildClaimsRecoveryAndLoss() public {
        bytes32 dealId = keccak256("position-view-frozen-parent");
        _fundDeal(dealId, 100, 0);
        bytes32 dealPosition = _dealPosId(dealId);
        _enterDeficit(50);

        bytes32 terminalHash = keccak256("position-view-frozen-parent-terminal");
        (bytes32 holderPosition, bytes32 providerPosition) =
            _settleSplit(dealId, terminalHash, holderReceiver, providerReceiver);
        _assertComponents(dealPosition, 100, 100, 0, 50, 50);
        PositionView memory parent = ledger.getPosition(dealPosition);
        assertTrue(parent.consumed);
        assertTrue(parent.replaced);
        assertEq(parent.replacementRoundingDust, 0);
        PositionView memory holderChild = ledger.getPosition(holderPosition);
        PositionView memory providerChild = ledger.getPosition(providerPosition);
        _assertReplacementConservation(parent, holderChild, providerChild);

        ledger.claimRecovery(holderPosition, 10);
        _assertComponents(dealPosition, 100, 100, 0, 50, 50);

        _approveRecovery(25);
        ledger.depositRecovery(address(token), 25);
        _assertComponents(dealPosition, 100, 100, 0, 50, 50);

        token.burn(address(ledger), 10);
        ledger.checkpointBoundary(address(token));
        _assertComponents(dealPosition, 100, 100, 0, 50, 50);

        PositionPayoutResult memory childClaim =
            ledger.claimRecovery(providerPosition, type(uint256).max);
        assertGt(childClaim.paidAmount, 0);
        _assertComponents(dealPosition, 100, 100, 0, 50, 50);
    }

    function test_getPosition_sameBeneficiaryPositionsRemainIndependent() public {
        feeRecipient = holder;
        bytes32 dealId = keccak256("position-view-same-beneficiary");
        _fundDeal(dealId, 100e18, 100e18);
        bytes32 boundaryId =
            DealHashing.custodyBoundaryId(ledger.chainId(), 2, address(ledger), address(token));
        bytes32 firstPosition = DealHashing.positionId(
            boundaryId, PositionKind.ActivationFee, dealId, bytes32(0), holder
        );
        bytes32 terminalHash = keccak256("position-view-same-beneficiary-terminal");
        bytes32 secondPosition = _termPosId(dealId, terminalHash, holder);
        TerminalAllocation[] memory allocations = new TerminalAllocation[](1);
        allocations[0] =
            TerminalAllocation({beneficiary: holder, amount: 100e18, positionId: secondPosition});
        vm.prank(escrow);
        ledger.settleDealAndReservations(dealId, address(token), terminalHash, allocations);
        assertNotEq(firstPosition, secondPosition);
        assertEq(ledger.getPosition(firstPosition).kind, PositionKind.ActivationFee);
        assertEq(ledger.getPosition(secondPosition).kind, PositionKind.DealTerminal);

        _enterDeficit(100e18);
        _assertComponents(firstPosition, 100e18, 100e18, 0, 50e18, 50e18);
        _assertComponents(secondPosition, 100e18, 100e18, 0, 50e18, 50e18);

        ledger.claimRecovery(firstPosition, 20e18);
        _assertComponents(firstPosition, 100e18, 80e18, 20e18, 30e18, 50e18);
        _assertComponents(secondPosition, 100e18, 100e18, 0, 50e18, 50e18);
        assertEq(ledger.getPosition(firstPosition).beneficiary, holder);
        assertEq(ledger.getPosition(secondPosition).beneficiary, holder);
    }

    function test_getPosition_readOnlyCallsDoNotMutateCheckpointOrState() public {
        (bytes32 holderPosition,) =
            _createSplitMaturedPositions(keccak256("position-view-read-only"));
        _enterDeficit(50);
        _approveRecovery(25);
        ledger.depositRecovery(address(token), 25);
        ledger.claimRecovery(holderPosition, 20);

        bytes32 checkpointBefore = ledger.boundaryCheckpointId(address(token));
        bytes32 stateBefore = _ledgerStateHash(holderPosition);
        PositionView memory first = ledger.getPosition(holderPosition);
        assertEq(ledger.positionNominal(holderPosition), 60);
        assertEq(ledger.positionNominalRemaining(holderPosition), 40);
        PositionView memory second = ledger.getPosition(holderPosition);

        assertEq(_positionViewHash(first), _positionViewHash(second));
        assertEq(ledger.boundaryCheckpointId(address(token)), checkpointBefore);
        assertEq(_ledgerStateHash(holderPosition), stateBefore);
    }

    function _settleSplit(
        bytes32 dealId,
        bytes32 terminalHash,
        address firstBeneficiary,
        address secondBeneficiary
    ) internal returns (bytes32 firstPosition, bytes32 secondPosition) {
        return _settleTwo(dealId, terminalHash, firstBeneficiary, secondBeneficiary, 60, 40);
    }

    function _settleTwo(
        bytes32 dealId,
        bytes32 terminalHash,
        address firstBeneficiary,
        address secondBeneficiary,
        uint256 firstAmount,
        uint256 secondAmount
    ) internal returns (bytes32 firstPosition, bytes32 secondPosition) {
        firstPosition = _termPosId(dealId, terminalHash, firstBeneficiary);
        secondPosition = _termPosId(dealId, terminalHash, secondBeneficiary);
        TerminalAllocation[] memory allocations = new TerminalAllocation[](2);
        allocations[0] = TerminalAllocation({
            beneficiary: firstBeneficiary, amount: firstAmount, positionId: firstPosition
        });
        allocations[1] = TerminalAllocation({
            beneficiary: secondBeneficiary, amount: secondAmount, positionId: secondPosition
        });
        vm.prank(escrow);
        ledger.settleDealAndReservations(dealId, address(token), terminalHash, allocations);
    }

    function _assertComponents(
        bytes32 positionId,
        uint256 nominalUnits,
        uint256 nominalRemaining,
        uint256 paidAssets,
        uint256 fundedEntitlement,
        uint256 unfundedGap
    ) internal view {
        PositionView memory position = ledger.getPosition(positionId);
        _assertComponentValues(
            position.components,
            nominalUnits,
            nominalRemaining,
            paidAssets,
            fundedEntitlement,
            unfundedGap
        );
        _assertPositionScalars(position, positionId, nominalUnits, nominalRemaining);
    }

    function _assertComponentValues(
        DeficitComponents memory components,
        uint256 nominalUnits,
        uint256 nominalRemaining,
        uint256 paidAssets,
        uint256 fundedEntitlement,
        uint256 unfundedGap
    ) internal pure {
        assertEq(components.nominalUnits, nominalUnits);
        assertEq(components.nominalRemaining, nominalRemaining);
        assertEq(components.paidAssets, paidAssets);
        assertEq(components.fundedEntitlement, fundedEntitlement);
        assertEq(components.unfundedGap, unfundedGap);
        assertEq(
            components.nominalUnits,
            components.paidAssets + components.fundedEntitlement + components.unfundedGap
        );
    }

    function _assertPositionScalars(
        PositionView memory position,
        bytes32 positionId,
        uint256 nominalUnits,
        uint256 nominalRemaining
    ) internal view {
        assertEq(ledger.positionNominal(positionId), nominalUnits);
        assertEq(ledger.positionNominalRemaining(positionId), nominalRemaining);
        if (!position.replaced) assertEq(position.replacementRoundingDust, 0);
        if (position.exists) {
            assertEq(position.boundaryMode, ledger.boundaryMode(position.token));
            assertEq(position.boundaryCheckpointId, ledger.boundaryCheckpointId(position.token));
        }
    }

    function _assertLifecycle(
        PositionView memory position,
        bytes32 positionId,
        bool consumed,
        bool replaced
    ) internal pure {
        assertEq(position.positionId, positionId);
        assertTrue(position.exists);
        assertEq(position.consumed, consumed);
        assertEq(position.replaced, replaced);
    }

    function _assertProvenance(
        PositionView memory position,
        uint8 kind,
        bytes32 sourceId,
        bytes32 terminalHash,
        address beneficiary
    ) internal view {
        assertEq(position.kind, kind);
        assertEq(position.sourceId, sourceId);
        assertEq(position.terminalHash, terminalHash);
        assertEq(position.beneficiary, beneficiary);
        assertEq(position.token, address(token));
    }

    function _assertReplacementConservation(
        PositionView memory parent,
        PositionView memory firstChild,
        PositionView memory secondChild
    ) internal pure {
        assertTrue(parent.replaced);
        assertFalse(firstChild.replaced);
        assertFalse(secondChild.replaced);
        assertEq(
            parent.components.nominalUnits,
            firstChild.components.nominalUnits + secondChild.components.nominalUnits
        );
        assertEq(
            parent.components.paidAssets,
            firstChild.components.paidAssets + secondChild.components.paidAssets
        );
        assertEq(
            parent.components.nominalRemaining,
            firstChild.components.nominalRemaining + secondChild.components.nominalRemaining
        );
        assertEq(
            parent.components.fundedEntitlement,
            firstChild.components.fundedEntitlement + secondChild.components.fundedEntitlement
        );
        assertEq(
            parent.components.unfundedGap,
            firstChild.components.unfundedGap + secondChild.components.unfundedGap
        );
    }

    function _ledgerStateHash(bytes32 positionId) internal view returns (bytes32) {
        bytes32 boundaryCoreHash = keccak256(
            abi.encode(
                ledger.boundaryMode(address(token)),
                ledger.boundaryCheckpointId(address(token)),
                ledger.accountedAssets(address(token)),
                ledger.nominalOutstanding(address(token)),
                ledger.quarantinedSurplus(address(token)),
                ledger.deficitPaidAssets(address(token))
            )
        );
        bytes32 boundaryIndexHash = keccak256(
            abi.encode(
                ledger.deficitNominalUnits(address(token)),
                ledger.deficitGapCoefficient(address(token)),
                ledger.deficitHistoryScale(address(token)),
                ledger.deficitHistoryTotal(address(token)),
                ledger.deficitGeneration(address(token)),
                ledger.deficitRoundingDust(address(token)),
                ledger.deficitPrecisionFloor(address(token))
            )
        );
        bytes32 positionHash = _storedPositionViewHash(positionId);
        return keccak256(
            abi.encode(
                boundaryCoreHash, boundaryIndexHash, token.balanceOf(address(ledger)), positionHash
            )
        );
    }

    function _storedPositionViewHash(bytes32 positionId) internal view returns (bytes32) {
        return _positionViewHash(ledger.getPosition(positionId));
    }

    function _positionViewHash(PositionView memory position) internal pure returns (bytes32) {
        bytes32 lifecycleHash = keccak256(
            abi.encode(
                position.positionId,
                position.exists,
                position.consumed,
                position.replaced,
                position.kind
            )
        );
        bytes32 provenanceHash = keccak256(
            abi.encode(
                position.sourceId, position.terminalHash, position.beneficiary, position.token
            )
        );
        bytes32 componentsHash = keccak256(
            abi.encode(
                position.components.nominalUnits,
                position.components.nominalRemaining,
                position.components.paidAssets,
                position.components.fundedEntitlement,
                position.components.unfundedGap,
                position.replacementRoundingDust
            )
        );
        return keccak256(
            abi.encode(
                lifecycleHash,
                provenanceHash,
                componentsHash,
                position.deficitHistory,
                position.deficitGeneration,
                position.boundaryCheckpointId,
                position.boundaryMode
            )
        );
    }
}
