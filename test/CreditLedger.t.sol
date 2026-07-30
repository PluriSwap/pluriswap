// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CreditLedger} from "../src/CreditLedger.sol";
import {CoreDeployer} from "../src/CoreDeployer.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {DealHashing} from "../src/libraries/DealHashing.sol";
import {
    FundingSpec,
    FundingAuth,
    TerminalAllocation,
    FundingPurpose,
    FundingSourceMode,
    PositionKind,
    BoundaryMode,
    ReconciliationStatus
} from "../src/libraries/DealTypes.sol";
import {
    PositionAlreadyConsumed,
    PositionAlreadyExists,
    PositionNotFound,
    ReconciliationFailed,
    Unauthorized
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
            2, keccak256("charter"), keccak256("tech"), address(this)
        );
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

    function _fundingAuth(bytes32 termsHash, bytes32 specHash, uint8 purpose, address authority, uint256 nonce)
        internal
        view
        returns (FundingAuth memory)
    {
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
        bytes32 digest_ = DealHashing.digest(ledger.DOMAIN_SEPARATOR(), DealHashing.hashFundingAuth(auth));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest_);
        return abi.encodePacked(r, s, v);
    }

    function _fundDeal(
        bytes32 dealId,
        uint256 principal,
        uint256 activationFee
    ) internal {
        token.mint(holder, principal + activationFee);
        vm.prank(holder);
        token.approve(address(ledger), type(uint256).max);

        FundingSpec memory principalSpec = _fundingSpec(
            FundingPurpose.Principal, address(token), principal, holder
        );
        FundingSpec memory feeSpec = _fundingSpec(
            FundingPurpose.ActivationFee, address(token), activationFee, holder
        );
        bytes32 principalSpecHash = DealHashing.hashFundingSpec(principalSpec);
        bytes32 feeSpecHash = DealHashing.hashFundingSpec(feeSpec);

        FundingAuth memory principalAuth = _fundingAuth(
            bytes32(uint256(1)), principalSpecHash, FundingPurpose.Principal, holder, 1
        );
        FundingAuth memory feeAuth = activationFee > 0
            ? _fundingAuth(bytes32(uint256(1)), feeSpecHash, FundingPurpose.ActivationFee, holder, 2)
            : _fundingAuth(bytes32(uint256(1)), bytes32(0), FundingPurpose.ActivationFee, holder, 2);

        bytes memory principalSig = _signFundingAuth(principalAuth, authorityPk);
        bytes memory feeSig = activationFee > 0
            ? _signFundingAuth(feeAuth, authorityPk)
            : new bytes(0);

        vm.prank(escrow);
        ledger.fundDealAndReservations(
            dealId, address(token), principal, activationFee, feeRecipient,
            principalSpec, feeSpec, principalAuth, feeAuth, principalSig, feeSig
        );
    }

    function _dealPosId(bytes32 dealId) internal view returns (bytes32) {
        bytes32 boundaryId = DealHashing.custodyBoundaryId(
            ledger.chainId(), 2, address(ledger), address(token)
        );
        return DealHashing.positionId(boundaryId, PositionKind.Deal, dealId, bytes32(0), address(0));
    }

    function _termPosId(bytes32 dealId, bytes32 terminalHash, address beneficiary)
        internal
        view
        returns (bytes32)
    {
        bytes32 boundaryId = DealHashing.custodyBoundaryId(
            ledger.chainId(), 2, address(ledger), address(token)
        );
        return DealHashing.positionId(boundaryId, PositionKind.DealTerminal, dealId, terminalHash, beneficiary);
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
        bytes32 boundaryId = DealHashing.custodyBoundaryId(
            ledger.chainId(), 2, address(ledger), address(token)
        );
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
            bytes32(0), address(token), 0, 0, address(0),
            FundingSpec(0, 0, address(0), 0, address(0), bytes32(0), address(0)),
            FundingSpec(0, 0, address(0), 0, address(0), bytes32(0), address(0)),
            FundingAuth(bytes32(0), bytes32(0), 0, address(0), 0, 0),
            FundingAuth(bytes32(0), bytes32(0), 0, address(0), 0, 0),
            "", ""
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

        FundingSpec memory spec = _fundingSpec(
            FundingPurpose.Principal, address(token), 100e18, holder
        );
        bytes32 specHash = DealHashing.hashFundingSpec(spec);
        FundingAuth memory auth = _fundingAuth(
            bytes32(uint256(2)), specHash, FundingPurpose.Principal, holder, 1
        );
        bytes memory sig = _signFundingAuth(auth, authorityPk);

        vm.prank(escrow);
        vm.expectRevert();
        ledger.fundDealAndReservations(
            dealId2, address(token), 100e18, 0, feeRecipient,
            spec,
            FundingSpec(0, 0, address(0), 0, address(0), bytes32(0), address(0)),
            auth,
            FundingAuth(bytes32(0), bytes32(0), 0, address(0), 0, 0),
            sig, ""
        );
    }

    function test_positionId_collisionRejects() public {
        bytes32 dealId = keccak256("deal11");
        _fundDeal(dealId, 100e18, 0);

        // Try to fund the same deal again → position already exists
        token.mint(holder, 100e18);
        vm.prank(holder);
        token.approve(address(ledger), type(uint256).max);

        FundingSpec memory spec = _fundingSpec(
            FundingPurpose.Principal, address(token), 100e18, holder
        );
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
            dealId, address(token), 100e18, 0, feeRecipient,
            spec,
            FundingSpec(0, 0, address(0), 0, address(0), bytes32(0), address(0)),
            auth,
            FundingAuth(bytes32(0), bytes32(0), 0, address(0), 0, 0),
            sig, ""
        );
    }
}
