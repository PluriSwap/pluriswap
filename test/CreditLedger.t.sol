// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CreditLedger} from "../src/CreditLedger.sol";
import {CoreDeployer} from "../src/CoreDeployer.sol";
import {CoreEscrow} from "../src/CoreEscrow.sol";
import {Coordinator} from "../src/Coordinator.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {DealHashing} from "../src/libraries/DealHashing.sol";
import {
    FundingSpec,
    FundingAuth,
    PositionPayoutAuth,
    PositionPayoutResult,
    TerminalAllocation,
    FundingPurpose,
    FundingSourceMode,
    PositionKind,
    CoreManifestOffchain,
    BoundaryMode,
    ReconciliationStatus
} from "../src/libraries/DealTypes.sol";
import {
    PositionAlreadyConsumed,
    PositionAlreadyExists,
    PositionNotFound,
    ReconciliationFailed,
    Unauthorized,
    InvalidPositionKind,
    InvalidTokenList,
    InvalidAmount,
    NonceUsed,
    RecoveryExceedsGap,
    DeficitNotActive
} from "../src/libraries/CoreErrors.sol";

/// @dev Tests the CreditLedger as sole vault with positions and reconciliation.
/// Uses vm.prank(escrow) to simulate escrow calls since CoreEscrow is a stub (Wave 3).
contract CreditLedgerTest is Test {
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
            CoreManifestOffchain(
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
        return DealHashing.positionId(boundaryId, PositionKind.Deal, dealId, bytes32(0), address(0));
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
        assertEq(ledger.positionKind(dealPos), PositionKind.Deal);
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

        vm.prank(escrow);
        ledger.settleDealAndReservations(dealId, address(token), terminalHash, allocs);

        // Deal position consumed
        bytes32 dealPos = _dealPosId(dealId);
        assertTrue(ledger.positionConsumed(dealPos));

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

    function test_settle_coalescesEqualBeneficiaries() public {
        bytes32 dealId = keccak256("deal4");
        _fundDeal(dealId, 100e18, 0);

        bytes32 terminalHash = keccak256("terminal");
        // Two allocations to the same beneficiary → coalesced
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

        vm.prank(escrow);
        ledger.settleDealAndReservations(dealId, address(token), terminalHash, allocs);

        // Only one terminal position, coalesced
        bytes32 holderTerm = _termPosId(dealId, terminalHash, holderReceiver);
        assertEq(ledger.positionNominal(holderTerm), 100e18);
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

        // Second settlement on consumed deal → reverts
        vm.prank(escrow);
        vm.expectRevert(PositionAlreadyConsumed.selector);
        ledger.settleDealAndReservations(dealId, address(token), terminalHash, allocs);
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
        vm.expectRevert(PositionAlreadyConsumed.selector);
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
        ledger.depositRecovery(address(token), address(this), 25);

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
        assertEq(ledger.positionNominal(holderPosition), 15);
        assertEq(ledger.positionNominal(providerPosition), 10);
    }

    function test_recoveryFullDepositMakesAllRemainingUnitsClaimable() public {
        (bytes32 holderPosition, bytes32 providerPosition) =
            _createSplitMaturedPositions(keccak256("recovery-full"));
        _enterDeficit(50);

        _approveRecovery(50);
        ledger.depositRecovery(address(token), address(this), 50);

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
        ledger.depositRecovery(address(token), address(this), 25);
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
        uint8 status = ledger.depositRecovery(address(token), address(this), 100);
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
        ledger.depositRecovery(address(token), address(this), 1);

        _createMaturedHolderPosition(keccak256("recovery-overdeposit"));
        _enterDeficit(50e18);
        _approveRecovery(50e18 + 1);
        vm.expectRevert(RecoveryExceedsGap.selector);
        ledger.depositRecovery(address(token), address(this), 50e18 + 1);
        assertEq(ledger.accountedAssets(address(token)), 50e18);
        assertEq(token.balanceOf(address(ledger)), 50e18);
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
        ledger.depositRecovery(address(token), address(this), 60);
        PositionPayoutResult memory paid = ledger.claimRecoveryTo(auth, signature);
        assertEq(paid.code, 3);
        assertEq(paid.paidAmount, 60);

        vm.expectRevert(NonceUsed.selector);
        ledger.claimRecoveryTo(auth, signature);
    }
}
