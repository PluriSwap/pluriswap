// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CoreDeployer} from "../src/CoreDeployer.sol";
import {CoreEscrow} from "../src/CoreEscrow.sol";
import {CreditLedger} from "../src/CreditLedger.sol";
import {Coordinator} from "../src/Coordinator.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {ReferenceRecoveryModel} from "./helpers/ReferenceRecoveryModel.sol";
import {DealHashing} from "../src/libraries/DealHashing.sol";
import {

    FundingAuth,
    FundingPurpose,
    FundingSourceMode,
    FundingSpec,
    PositionKind,
    PositionPayoutResult,
    PositionView,
    TerminalAllocation
} from "../src/libraries/DealTypes.sol";
import {PositionNotSplittable} from "../src/libraries/CoreErrors.sol";
import {CoreDeploymentIntentOffchain} from "../src/libraries/ManifestTypes.sol";

contract CreditLedgerRecoveryDifferentialTest is Test {
    uint256 internal constant HOLDER_PK = 0xA11CE;
    uint256 internal constant VIEW_GAS_TOLERANCE = 3_000;
    // Mutation paths include SSTORE/log variance; still far below historical iteration cost.
    uint256 internal constant MUTATION_GAS_TOLERANCE = 30_000;
    // Fixed release seed: three matured credits, one-unit-above exact entry, claim-order vector.
    uint256 internal constant PERM_NOMINAL_A = 5;
    uint256 internal constant PERM_NOMINAL_B = 7;
    uint256 internal constant PERM_NOMINAL_C = 11;
    uint256 internal constant PERM_ENTRY_ASSETS = 10;
    uint256 internal constant PERM_PAYOUT_A = 2;
    uint256 internal constant PERM_PAYOUT_B = 3;
    uint256 internal constant PERM_PAYOUT_C = 4;
    address internal constant FEE_BENEFICIARY = address(0xFEE);
    address internal constant HOLDER_RECEIVER = address(0x1111);
    address internal constant PROVIDER_RECEIVER = address(0x2222);
    address internal constant THIRD_RECEIVER = address(0x3333);

    CreditLedger internal ledger;
    MockERC20 internal token;
    ReferenceRecoveryModel internal referenceModel;
    address internal escrow;
    address internal holder;

    struct SplitComponentTotals {
        uint256 nominalUnits;
        uint256 nominalRemaining;
        uint256 paidAssets;
        uint256 fundedEntitlement;
        uint256 unfundedGap;
    }

    function setUp() public {
        holder = vm.addr(HOLDER_PK);
        (, ledger, escrow) = _deployCore(keccak256("differential-ledger"));
        token = new MockERC20();
        referenceModel = new ReferenceRecoveryModel();
    }

    function test_productionLedgerMatchesReferenceAcrossExactRecoverySequence() public {
        bytes32 dealId = keccak256("production-reference-sequence");
        _fundDeal(ledger, token, escrow, dealId, 200, 200, 1);
        bytes32 dealPosition = _dealPositionId(ledger, token, dealId);
        bytes32 feePosition = _feePositionId(ledger, token, dealId, FEE_BENEFICIARY);

        referenceModel.addHealthyPosition(dealPosition, 200, true);
        referenceModel.addHealthyPosition(feePosition, 200, false);
        _assertEquivalent(dealPosition);
        _assertEquivalent(feePosition);

        token.burn(address(ledger), 200);
        ledger.checkpointBoundary(address(token));
        referenceModel.enterDeficit(200);
        _assertEquivalent(dealPosition);
        _assertEquivalent(feePosition);

        PositionPayoutResult memory feeClaim = ledger.claimRecovery(feePosition, 40);
        uint256 referenceFeeClaim = referenceModel.claim(feePosition, 40);
        assertEq(feeClaim.paidAmount, referenceFeeClaim);
        assertEq(feeClaim.paidAmount, 40);
        assertEq(
            feeClaim.nominalRemaining, ledger.getPosition(feePosition).components.nominalRemaining
        );
        _assertEquivalent(dealPosition);
        _assertEquivalent(feePosition);

        _depositRecovery(ledger, token, 100);
        referenceModel.depositRecovery(100);
        _assertEquivalent(dealPosition);
        _assertEquivalent(feePosition);

        token.burn(address(ledger), 130);
        ledger.checkpointBoundary(address(token));
        assertTrue(referenceModel.observeAttributableAssets(130));
        _assertEquivalent(dealPosition);
        _assertEquivalent(feePosition);

        bytes32 terminalHash = keccak256("production-reference-terminal");
        (bytes32 holderPosition, bytes32 providerPosition) =
            _settleSplit(ledger, token, escrow, dealId, terminalHash, 120, 80);
        bytes32[] memory childIds = new bytes32[](2);
        childIds[0] = holderPosition;
        childIds[1] = providerPosition;
        uint256[] memory childNominals = new uint256[](2);
        childNominals[0] = 120;
        childNominals[1] = 80;
        referenceModel.splitActivePosition(dealPosition, childIds, childNominals);

        _assertEquivalent(dealPosition);
        _assertEquivalent(feePosition);
        _assertEquivalent(holderPosition);
        _assertEquivalent(providerPosition);

        PositionPayoutResult memory holderClaim =
            ledger.claimRecovery(holderPosition, type(uint256).max);
        uint256 referenceHolderClaim = referenceModel.claim(holderPosition, type(uint256).max);
        assertEq(holderClaim.paidAmount, referenceHolderClaim);
        assertEq(holderClaim.paidAmount, 45);
        assertEq(
            holderClaim.nominalRemaining,
            ledger.getPosition(holderPosition).components.nominalRemaining
        );
        _assertEquivalent(dealPosition);
        _assertEquivalent(feePosition);
        _assertEquivalent(holderPosition);
        _assertEquivalent(providerPosition);

        assertEq(referenceModel.aggregateGap(), 230);
        _depositRecovery(ledger, token, 230);
        referenceModel.depositRecovery(230);
        _assertEquivalent(dealPosition);
        _assertEquivalent(feePosition);
        _assertEquivalent(holderPosition);
        _assertEquivalent(providerPosition);

        token.burn(address(ledger), 315);
        ledger.checkpointBoundary(address(token));
        assertTrue(referenceModel.observeAttributableAssets(0));
        _assertEquivalent(dealPosition);
        _assertEquivalent(feePosition);
        _assertEquivalent(holderPosition);
        _assertEquivalent(providerPosition);
    }

    function test_productionLedgerOddSplitDivergesOnlyByReportedReplacementDust() public {
        bytes32 dealId = keccak256("production-reference-odd-split");
        _fundDeal(ledger, token, escrow, dealId, 10, 0, 1);
        bytes32 parentId = _dealPositionId(ledger, token, dealId);
        referenceModel.addHealthyPosition(parentId, 10, true);

        token.burn(address(ledger), 5);
        ledger.checkpointBoundary(address(token));
        referenceModel.enterDeficit(5);
        _assertEquivalent(parentId);

        bytes32 terminalHash = keccak256("production-reference-odd-terminal");
        (bytes32 firstChild, bytes32 secondChild) =
            _settleSplit(ledger, token, escrow, dealId, terminalHash, 3, 7);
        bytes32[] memory childIds = new bytes32[](2);
        childIds[0] = firstChild;
        childIds[1] = secondChild;
        uint256[] memory childNominals = new uint256[](2);
        childNominals[0] = 3;
        childNominals[1] = 7;
        referenceModel.splitActivePosition(parentId, childIds, childNominals);

        PositionView memory parent = ledger.getPosition(parentId);
        PositionView memory first = ledger.getPosition(firstChild);
        PositionView memory second = ledger.getPosition(secondChild);
        ReferenceRecoveryModel.Position memory exactParent = referenceModel.getPosition(parentId);
        ReferenceRecoveryModel.Position memory exactFirst = referenceModel.getPosition(firstChild);
        ReferenceRecoveryModel.Position memory exactSecond = referenceModel.getPosition(secondChild);

        _assertRational(exactParent.fundedEntitlement, 5, 1);
        _assertRational(exactParent.unfundedGap, 5, 1);
        _assertRational(exactFirst.fundedEntitlement, 3, 2);
        _assertRational(exactFirst.unfundedGap, 3, 2);
        _assertRational(exactSecond.fundedEntitlement, 7, 2);
        _assertRational(exactSecond.unfundedGap, 7, 2);
        assertEq(first.components.fundedEntitlement, 1);
        assertEq(first.components.unfundedGap, 2);
        assertEq(second.components.fundedEntitlement, 3);
        assertEq(second.components.unfundedGap, 4);
        assertEq(parent.components.fundedEntitlement, 4);
        assertEq(parent.components.unfundedGap, 6);
        assertEq(parent.replacementRoundingDust, 1);
        assertEq(
            parent.components.fundedEntitlement,
            first.components.fundedEntitlement + second.components.fundedEntitlement
        );
        assertEq(
            parent.components.unfundedGap,
            first.components.unfundedGap + second.components.unfundedGap
        );

        PositionPayoutResult memory firstClaim = ledger.claimRecovery(firstChild, type(uint256).max);
        PositionPayoutResult memory secondClaim =
            ledger.claimRecovery(secondChild, type(uint256).max);
        assertEq(firstClaim.paidAmount, referenceModel.claim(firstChild, type(uint256).max));
        assertEq(secondClaim.paidAmount, referenceModel.claim(secondChild, type(uint256).max));
        assertEq(firstClaim.paidAmount + secondClaim.paidAmount, 4);

        PositionView memory parentAfterClaims = ledger.getPosition(parentId);
        ReferenceRecoveryModel.Position memory exactFirstAfter =
            referenceModel.getPosition(firstChild);
        ReferenceRecoveryModel.Position memory exactSecondAfter =
            referenceModel.getPosition(secondChild);
        _assertRational(exactFirstAfter.fundedEntitlement, 1, 2);
        _assertRational(exactSecondAfter.fundedEntitlement, 1, 2);
        assertEq(ledger.getPosition(firstChild).components.fundedEntitlement, 0);
        assertEq(ledger.getPosition(secondChild).components.fundedEntitlement, 0);
        assertEq(parentAfterClaims.replacementRoundingDust, 1);
        assertEq(
            keccak256(abi.encode(parentAfterClaims.components)),
            keccak256(abi.encode(parent.components))
        );
    }

    function test_productionLedgerSeparatesPreexistingQ128ErrorFromSplitDust() public {
        bytes32 dealId = keccak256("production-reference-preexisting-q128-error");
        _fundDeal(ledger, token, escrow, dealId, 3, 0, 1);
        bytes32 parentId = _dealPositionId(ledger, token, dealId);
        referenceModel.addHealthyPosition(parentId, 3, true);

        token.burn(address(ledger), 1);
        ledger.checkpointBoundary(address(token));
        referenceModel.enterDeficit(2);

        PositionView memory productionPreSplit = ledger.getPosition(parentId);
        ReferenceRecoveryModel.Position memory exactPreSplit = referenceModel.getPosition(parentId);
        _assertRational(exactPreSplit.fundedEntitlement, 2, 1);
        _assertRational(exactPreSplit.unfundedGap, 1, 1);
        assertEq(productionPreSplit.components.fundedEntitlement, 1);
        assertEq(productionPreSplit.components.unfundedGap, 2);
        uint256 preexistingError = exactPreSplit.fundedEntitlement.numerator
            - productionPreSplit.components.fundedEntitlement;
        assertEq(preexistingError, 1);
        assertEq(
            productionPreSplit.components.unfundedGap - exactPreSplit.unfundedGap.numerator,
            preexistingError
        );

        bytes32 terminalHash = keccak256("production-reference-preexisting-q128-terminal");
        bytes32[] memory childIds = _settleBoundedSplit(dealId, terminalHash, 3, 3, 0, 0);
        uint256[] memory childNominals = new uint256[](3);
        childNominals[0] = 1;
        childNominals[1] = 1;
        childNominals[2] = 1;
        referenceModel.splitActivePosition(parentId, childIds, childNominals);

        SplitComponentTotals memory productionChildren = _sumChildComponents(childIds);
        PositionView memory replacedParent = ledger.getPosition(parentId);
        for (uint256 i; i < childIds.length; ++i) {
            ReferenceRecoveryModel.Position memory exactChild =
                referenceModel.getPosition(childIds[i]);
            _assertRational(exactChild.fundedEntitlement, 2, 3);
            _assertRational(exactChild.unfundedGap, 1, 3);
        }
        assertEq(productionChildren.nominalUnits, 3);
        assertEq(productionChildren.paidAssets, 0);
        assertEq(productionChildren.fundedEntitlement, 0);
        assertEq(productionChildren.unfundedGap, 3);

        uint256 splitDust = replacedParent.replacementRoundingDust;
        assertEq(splitDust, 1);
        assertEq(
            productionPreSplit.components.fundedEntitlement - productionChildren.fundedEntitlement,
            splitDust
        );
        assertEq(
            productionChildren.unfundedGap - productionPreSplit.components.unfundedGap, splitDust
        );

        uint256 postSplitFundedError =
            exactPreSplit.fundedEntitlement.numerator - productionChildren.fundedEntitlement;
        uint256 postSplitGapError =
            productionChildren.unfundedGap - exactPreSplit.unfundedGap.numerator;
        assertEq(postSplitFundedError, preexistingError + splitDust);
        assertEq(postSplitGapError, preexistingError + splitDust);
        assertEq(postSplitFundedError - preexistingError, splitDust);
        assertEq(replacedParent.components.fundedEntitlement, productionChildren.fundedEntitlement);
        assertEq(replacedParent.components.unfundedGap, productionChildren.unfundedGap);
    }

    function test_productionLedgerClaimOrderPermutationsAreOrderIndependent() public {
        uint256[3] memory firstOrder = _runProductionClaimPermutation(0, 1, 2);
        assertEq(firstOrder[0], PERM_PAYOUT_A);
        assertEq(firstOrder[1], PERM_PAYOUT_B);
        assertEq(firstOrder[2], PERM_PAYOUT_C);

        _assertProductionClaimPermutationMatches(0, 2, 1, firstOrder);
        _assertProductionClaimPermutationMatches(1, 0, 2, firstOrder);
        _assertProductionClaimPermutationMatches(1, 2, 0, firstOrder);
        _assertProductionClaimPermutationMatches(2, 0, 1, firstOrder);
        _assertProductionClaimPermutationMatches(2, 1, 0, firstOrder);
    }

    function test_productionLedgerAlternatingLossRecoveryAndFullRefillGenerations() public {
        bytes32 dealId = keccak256("production-alternating-generations");
        _fundDeal(ledger, token, escrow, dealId, 100, 0, 1);
        bytes32 dealPosition = _dealPositionId(ledger, token, dealId);

        token.burn(address(ledger), 50);
        ledger.checkpointBoundary(address(token));
        uint256 generationAfterEntry = ledger.deficitGeneration(address(token));
        assertEq(generationAfterEntry, 1);
        assertTrue(ledger.inDeficit(address(token)));

        bytes32 terminalHash = keccak256("production-alternating-terminal");
        (bytes32 holderPosition, bytes32 providerPosition) =
            _settleSplit(ledger, token, escrow, dealId, terminalHash, 60, 40);
        assertTrue(ledger.getPosition(dealPosition).replaced);
        assertEq(ledger.positionNominal(holderPosition), 60);
        assertEq(ledger.positionNominal(providerPosition), 40);

        _depositRecovery(ledger, token, 20);
        PositionPayoutResult memory firstClaim = ledger.claimRecovery(holderPosition, 30);
        assertEq(firstClaim.paidAmount, 30);
        assertEq(token.balanceOf(HOLDER_RECEIVER), 30);

        uint256 assetsAfterClaim = ledger.accountedAssets(address(token));
        token.burn(address(ledger), assetsAfterClaim / 2);
        ledger.checkpointBoundary(address(token));
        assertEq(ledger.deficitGeneration(address(token)), generationAfterEntry);
        assertEq(token.balanceOf(HOLDER_RECEIVER), 30);
        assertEq(ledger.getPosition(holderPosition).components.paidAssets, 30);

        // Full attributable loss resets the generation and clears history while preserving paid.
        uint256 paidBeforeFullLoss = ledger.deficitPaidAssets(address(token));
        token.burn(address(ledger), ledger.accountedAssets(address(token)));
        ledger.checkpointBoundary(address(token));
        assertEq(ledger.accountedAssets(address(token)), 0);
        assertEq(ledger.deficitPaidAssets(address(token)), paidBeforeFullLoss);
        assertEq(ledger.deficitGeneration(address(token)), generationAfterEntry + 1);
        assertEq(ledger.deficitGapCoefficient(address(token)), uint256(1) << 128);
        assertFalse(ledger.deficitPrecisionFloor(address(token)));
        assertEq(token.balanceOf(HOLDER_RECEIVER), 30);

        uint256 gap =
            ledger.deficitNominalUnits(address(token)) - ledger.deficitPaidAssets(address(token));
        _depositRecovery(ledger, token, gap);
        assertEq(ledger.deficitGapCoefficient(address(token)), 0);
        assertEq(ledger.deficitGeneration(address(token)), generationAfterEntry + 2);
        assertTrue(ledger.inDeficit(address(token)));

        // Full gap refill does not reopen healthy exposure on an irreversible deficit boundary.
        bytes32 blockedDealId = keccak256("production-no-new-exposure");
        uint256 nominalBefore = ledger.nominalOutstanding(address(token));
        _fundDeal(ledger, token, escrow, blockedDealId, 1, 0, 2);
        assertFalse(ledger.positionExists(_dealPositionId(ledger, token, blockedDealId)));
        assertEq(ledger.nominalOutstanding(address(token)), nominalBefore);
        assertTrue(ledger.inDeficit(address(token)));
    }

    function test_productionLedgerPrecisionFloorEventuallySetsAndClaimsRemainConservative() public {
        bytes32 dealId = keccak256("production-precision-floor");
        _fundDeal(ledger, token, escrow, dealId, 4, 0, 1);
        (bytes32 alice, bytes32 bob) =
            _settleSplit(ledger, token, escrow, dealId, keccak256("floor-terminal"), 2, 2);

        token.burn(address(ledger), 2);
        ledger.checkpointBoundary(address(token));
        assertFalse(ledger.deficitPrecisionFloor(address(token)));

        PositionPayoutResult memory first = ledger.claimRecovery(alice, 1);
        assertEq(first.paidAmount, 1);

        bool floored;
        for (uint256 i; i < 200; ++i) {
            _depositRecovery(ledger, token, 1);
            token.burn(address(ledger), 1);
            ledger.checkpointBoundary(address(token));
            if (ledger.deficitPrecisionFloor(address(token))) {
                floored = true;
                break;
            }
        }
        assertTrue(floored);

        uint256 assetsBefore = ledger.accountedAssets(address(token));
        uint256 bobBalanceBefore = token.balanceOf(PROVIDER_RECEIVER);
        PositionPayoutResult memory later = ledger.claimRecovery(bob, type(uint256).max);
        // Precision floor may leave a position with zero payable funded entitlement.
        assertTrue(later.code == 3 || later.code == 4);
        assertLe(later.paidAmount, assetsBefore);
        if (later.code == 3) assertGt(later.paidAmount, 0);
        if (later.code == 4) assertEq(later.paidAmount, 0);
        assertEq(token.balanceOf(PROVIDER_RECEIVER), bobBalanceBefore + later.paidAmount);
        assertEq(ledger.accountedAssets(address(token)), assetsBefore - later.paidAmount);
        assertLe(
            ledger.getPosition(bob).components.fundedEntitlement,
            ledger.getPosition(bob).components.nominalRemaining
        );
    }

    function test_withdrawAndSettlementGasDoesNotGrowWithUnrelatedPositionsOrCheckpoints() public {
        bytes32 smallDealId = keccak256("withdraw-settle-gas-small");
        _fundDeal(ledger, token, escrow, smallDealId, 100, 0, 1);
        (bytes32 smallTerminal,) = _settleSplit(
            ledger, token, escrow, smallDealId, keccak256("withdraw-settle-small"), 60, 40
        );

        (, CreditLedger largeLedger, address largeEscrow) =
            _deployCore(keccak256("withdraw-settle-gas-large"));
        MockERC20 largeToken = new MockERC20();
        bytes32 largeTerminal;
        for (uint256 i; i < 16; ++i) {
            bytes32 dealId = keccak256(abi.encode("withdraw-settle-deal", i));
            _fundDeal(largeLedger, largeToken, largeEscrow, dealId, 100, 0, i + 1);
            if (i == 0) {
                (largeTerminal,) = _settleSplit(
                    largeLedger,
                    largeToken,
                    largeEscrow,
                    dealId,
                    keccak256("withdraw-settle-large"),
                    60,
                    40
                );
            } else {
                _settleSplit(
                    largeLedger,
                    largeToken,
                    largeEscrow,
                    dealId,
                    keccak256(abi.encode("withdraw-settle-other", i)),
                    60,
                    40
                );
            }
        }

        (uint256 smallWithdrawGas, uint256 smallSettleGas) =
            _measureWithdrawAndSettleGas(ledger, token, escrow, smallTerminal, "small");
        (uint256 largeWithdrawGas, uint256 largeSettleGas) = _measureWithdrawAndSettleGas(
            largeLedger, largeToken, largeEscrow, largeTerminal, "large"
        );

        emit log_named_uint("small withdrawPosition gas", smallWithdrawGas);
        emit log_named_uint("large withdrawPosition gas", largeWithdrawGas);
        emit log_named_uint("small settleDeal gas", smallSettleGas);
        emit log_named_uint("large settleDeal gas", largeSettleGas);

        assertLe(largeWithdrawGas, smallWithdrawGas + MUTATION_GAS_TOLERANCE);
        assertLe(largeSettleGas, smallSettleGas + MUTATION_GAS_TOLERANCE);
    }

    function test_mutationPathGasDoesNotGrowWithUnrelatedPositionsOrCheckpoints() public {
        bytes32 smallDealId = keccak256("mutation-gas-small");
        _fundDeal(ledger, token, escrow, smallDealId, 100, 100, 1);
        bytes32 smallTarget = _feePositionId(ledger, token, smallDealId, FEE_BENEFICIARY);
        token.burn(address(ledger), 100);
        ledger.checkpointBoundary(address(token));

        (, CreditLedger largeLedger, address largeEscrow) =
            _deployCore(keccak256("mutation-gas-large"));
        MockERC20 largeToken = new MockERC20();
        bytes32 largeTarget;
        for (uint256 i; i < 16; ++i) {
            bytes32 dealId = keccak256(abi.encode("mutation-gas-deal", i));
            _fundDeal(largeLedger, largeToken, largeEscrow, dealId, 100, 100, i + 1);
            if (i == 0) {
                largeTarget = _feePositionId(largeLedger, largeToken, dealId, FEE_BENEFICIARY);
            }
        }
        largeToken.burn(address(largeLedger), 1_600);
        largeLedger.checkpointBoundary(address(largeToken));
        largeToken.mint(address(this), 16);
        largeToken.approve(address(largeLedger), 16);
        for (uint256 i; i < 16; ++i) {
            largeLedger.depositRecovery(address(largeToken), 1);
            largeToken.burn(address(largeLedger), 1);
            largeLedger.checkpointBoundary(address(largeToken));
        }

        (uint256 smallClaimGas, uint256 smallCheckpointGas, uint256 smallRecoveryGas) =
            _measureMutationPaths(ledger, token, smallTarget);
        (uint256 largeClaimGas, uint256 largeCheckpointGas, uint256 largeRecoveryGas) =
            _measureMutationPaths(largeLedger, largeToken, largeTarget);

        emit log_named_uint("small claimRecovery gas", smallClaimGas);
        emit log_named_uint("large claimRecovery gas", largeClaimGas);
        emit log_named_uint("small checkpointBoundary gas", smallCheckpointGas);
        emit log_named_uint("large checkpointBoundary gas", largeCheckpointGas);
        emit log_named_uint("small depositRecovery gas", smallRecoveryGas);
        emit log_named_uint("large depositRecovery gas", largeRecoveryGas);

        assertLe(largeClaimGas, smallClaimGas + MUTATION_GAS_TOLERANCE);
        assertLe(largeCheckpointGas, smallCheckpointGas + MUTATION_GAS_TOLERANCE);
        assertLe(largeRecoveryGas, smallRecoveryGas + MUTATION_GAS_TOLERANCE);
    }
    function test_getPositionGasDoesNotGrowWithUnrelatedPositionsOrCheckpoints() public {
        bytes32 smallDealId = keccak256("gas-small-target");
        _fundDeal(ledger, token, escrow, smallDealId, 100, 100, 1);
        bytes32 smallTarget = _feePositionId(ledger, token, smallDealId, FEE_BENEFICIARY);
        token.burn(address(ledger), 100);
        ledger.checkpointBoundary(address(token));

        (, CreditLedger largeLedger, address largeEscrow) =
            _deployCore(keccak256("gas-large-ledger"));
        MockERC20 largeToken = new MockERC20();
        bytes32 largeTarget;
        for (uint256 i; i < 16; ++i) {
            bytes32 dealId = keccak256(abi.encode("gas-large-deal", i));
            _fundDeal(largeLedger, largeToken, largeEscrow, dealId, 100, 100, i + 1);
            if (i == 0) {
                largeTarget = _feePositionId(largeLedger, largeToken, dealId, FEE_BENEFICIARY);
            }
        }
        largeToken.burn(address(largeLedger), 1_600);
        largeLedger.checkpointBoundary(address(largeToken));

        largeToken.mint(address(this), 16);
        largeToken.approve(address(largeLedger), 16);
        for (uint256 i; i < 16; ++i) {
            largeLedger.depositRecovery(address(largeToken), 1);
            largeToken.burn(address(largeLedger), 1);
            largeLedger.checkpointBoundary(address(largeToken));
        }

        (uint256 smallColdGas, uint256 smallWarmGas) = _measureColdAndWarmView(ledger, smallTarget);
        (uint256 largeColdGas, uint256 largeWarmGas) =
            _measureColdAndWarmView(largeLedger, largeTarget);

        emit log_named_uint("small getPosition cold gas", smallColdGas);
        emit log_named_uint("large getPosition cold gas", largeColdGas);
        emit log_named_uint("small getPosition warm gas", smallWarmGas);
        emit log_named_uint("large getPosition warm gas", largeWarmGas);

        // The tolerance covers fixed ABI/memory and value-dependent arithmetic differences.
        // Iterating the 32-position / 16-checkpoint history exceeds it in cold and warm cases.
        assertLe(largeColdGas, smallColdGas + VIEW_GAS_TOLERANCE);
        assertLe(largeWarmGas, smallWarmGas + VIEW_GAS_TOLERANCE);
    }

    function testFuzz_malformedDeficitSplitRollsBackParentChildrenAndReplacementSnapshot(
        uint96 nominalSeed,
        uint96 assetsSeed,
        uint8 childCountSeed,
        uint96 firstShareSeed,
        uint96 secondShareSeed
    ) public {
        uint256 childCount = bound(childCountSeed, 1, 3);
        uint256 minimumNominal = childCount > 2 ? childCount : 2;
        uint256 nominal = bound(nominalSeed, minimumNominal, 1e12);
        uint256 assets = bound(assetsSeed, 1, nominal - 1);
        bytes32 dealId = keccak256(
            abi.encode(
                "malformed-deficit-split",
                nominal,
                assets,
                childCount,
                firstShareSeed,
                secondShareSeed
            )
        );
        _fundDeal(ledger, token, escrow, dealId, nominal, 0, 1);
        bytes32 parentId = _dealPositionId(ledger, token, dealId);
        token.burn(address(ledger), nominal - assets);
        ledger.checkpointBoundary(address(token));

        PositionView memory parentBefore = ledger.getPosition(parentId);
        bytes32 checkpointBefore = ledger.boundaryCheckpointId(address(token));
        bytes32 terminalHash = keccak256(abi.encode("malformed-deficit-terminal", dealId));
        bytes32 boundaryId =
            DealHashing.custodyBoundaryId(ledger.chainId(), 2, address(ledger), address(token));
        uint256[] memory childNominals =
            _partitionNominal(nominal, childCount, firstShareSeed, secondShareSeed);
        TerminalAllocation[] memory allocations = new TerminalAllocation[](childCount);
        for (uint256 i; i < childCount; ++i) {
            address beneficiary = address(uint160(0x2000 + i));
            allocations[i] = TerminalAllocation({
                beneficiary: beneficiary,
                amount: childNominals[i],
                positionId: DealHashing.positionId(
                    boundaryId, PositionKind.DealTerminal, dealId, terminalHash, beneficiary
                )
            });
        }
        ++allocations[0].amount;

        vm.prank(escrow);
        vm.expectRevert(PositionNotSplittable.selector);
        ledger.settleDealAndReservations(dealId, address(token), terminalHash, allocations);

        PositionView memory parentAfter = ledger.getPosition(parentId);
        assertEq(keccak256(abi.encode(parentAfter)), keccak256(abi.encode(parentBefore)));
        assertEq(ledger.boundaryCheckpointId(address(token)), checkpointBefore);
        for (uint256 i; i < childCount; ++i) {
            assertFalse(ledger.positionExists(allocations[i].positionId));
        }
    }

    function test_overCountSplitRollsBackBeforeReconciliationOrReplacement() public {
        bytes32 dealId = keccak256("over-count-deficit-split");
        _fundDeal(ledger, token, escrow, dealId, 4, 0, 1);
        bytes32 parentId = _dealPositionId(ledger, token, dealId);
        token.burn(address(ledger), 2);

        PositionView memory parentBefore = ledger.getPosition(parentId);
        bytes32 checkpointBefore = ledger.boundaryCheckpointId(address(token));
        bytes32 terminalHash = keccak256("over-count-deficit-terminal");
        bytes32 boundaryId =
            DealHashing.custodyBoundaryId(ledger.chainId(), 2, address(ledger), address(token));
        TerminalAllocation[] memory allocations = new TerminalAllocation[](4);
        for (uint256 i; i < allocations.length; ++i) {
            address beneficiary = address(uint160(0x3000 + i));
            allocations[i] = TerminalAllocation({
                beneficiary: beneficiary,
                amount: 1,
                positionId: DealHashing.positionId(
                    boundaryId, PositionKind.DealTerminal, dealId, terminalHash, beneficiary
                )
            });
        }

        vm.prank(escrow);
        vm.expectRevert(PositionNotSplittable.selector);
        ledger.settleDealAndReservations(dealId, address(token), terminalHash, allocations);

        assertEq(
            keccak256(abi.encode(ledger.getPosition(parentId))), keccak256(abi.encode(parentBefore))
        );
        assertEq(ledger.boundaryCheckpointId(address(token)), checkpointBefore);
        assertFalse(ledger.inDeficit(address(token)));
        assertEq(ledger.accountedAssets(address(token)), 4);
        assertEq(token.balanceOf(address(ledger)), 2);
        for (uint256 i; i < allocations.length; ++i) {
            assertFalse(ledger.positionExists(allocations[i].positionId));
        }
    }

    function testFuzz_replacementDustIsConservativeBoundedAndUnclaimable(
        uint96 nominalSeed,
        uint96 assetsSeed,
        uint8 childCountSeed,
        uint96 firstShareSeed,
        uint96 secondShareSeed
    ) public {
        uint256 childCount = bound(childCountSeed, 1, 3);
        uint256 minimumNominal = childCount > 2 ? childCount : 2;
        uint256 nominal = bound(nominalSeed, minimumNominal, 1e12);
        uint256 assets = bound(assetsSeed, 1, nominal - 1);
        bytes32 dealId = keccak256(
            abi.encode(
                "replacement-dust-fuzz",
                nominal,
                assets,
                childCount,
                firstShareSeed,
                secondShareSeed
            )
        );
        _fundDeal(ledger, token, escrow, dealId, nominal, 0, 1);
        bytes32 parentId = _dealPositionId(ledger, token, dealId);

        token.burn(address(ledger), nominal - assets);
        ledger.checkpointBoundary(address(token));
        PositionView memory preSplit = ledger.getPosition(parentId);

        bytes32 terminalHash = keccak256(abi.encode("replacement-dust-terminal", dealId));
        bytes32[] memory childIds = _settleBoundedSplit(
            dealId, terminalHash, nominal, childCount, firstShareSeed, secondShareSeed
        );
        SplitComponentTotals memory children = _sumChildComponents(childIds);
        PositionView memory replacedParent = ledger.getPosition(parentId);
        uint256 dust = replacedParent.replacementRoundingDust;

        assertEq(children.nominalUnits, preSplit.components.nominalUnits);
        assertEq(children.nominalRemaining, preSplit.components.nominalRemaining);
        assertEq(children.paidAssets, preSplit.components.paidAssets);
        assertLe(children.fundedEntitlement, preSplit.components.fundedEntitlement);
        assertGe(children.unfundedGap, preSplit.components.unfundedGap);
        assertEq(dust, preSplit.components.fundedEntitlement - children.fundedEntitlement);
        assertEq(dust, children.unfundedGap - preSplit.components.unfundedGap);
        assertLe(dust, childCount - 1);
        assertLe(dust, 2);
        assertEq(replacedParent.components.nominalUnits, children.nominalUnits);
        assertEq(replacedParent.components.nominalRemaining, children.nominalRemaining);
        assertEq(replacedParent.components.paidAssets, children.paidAssets);
        assertEq(replacedParent.components.fundedEntitlement, children.fundedEntitlement);
        assertEq(replacedParent.components.unfundedGap, children.unfundedGap);

        uint256 totalClaimed;
        for (uint256 i; i < childIds.length; ++i) {
            uint256 fundedBefore = ledger.getPosition(childIds[i]).components.fundedEntitlement;
            PositionPayoutResult memory result =
                ledger.claimRecovery(childIds[i], type(uint256).max);
            assertEq(result.paidAmount, fundedBefore);
            totalClaimed += result.paidAmount;
        }
        assertEq(totalClaimed, children.fundedEntitlement);
        assertEq(totalClaimed + dust, preSplit.components.fundedEntitlement);
        assertGe(token.balanceOf(address(ledger)), dust);

        PositionView memory parentAfterClaims = ledger.getPosition(parentId);
        assertTrue(parentAfterClaims.replaced);
        assertEq(parentAfterClaims.replacementRoundingDust, dust);
        assertEq(
            keccak256(abi.encode(parentAfterClaims.components)),
            keccak256(abi.encode(replacedParent.components))
        );
    }

    function _assertEquivalent(bytes32 positionId) internal view {
        PositionView memory actual = ledger.getPosition(positionId);
        ReferenceRecoveryModel.Position memory expected = referenceModel.getPosition(positionId);

        assertEq(actual.positionId, positionId);
        assertEq(actual.exists, expected.exists);
        assertEq(actual.consumed, expected.consumed);
        assertEq(actual.replaced, expected.replaced);
        assertEq(actual.replacementRoundingDust, 0);
        assertEq(actual.components.nominalUnits, _integer(expected.nominalUnits));
        assertEq(actual.components.paidAssets, _integer(expected.paidAssets));
        assertEq(actual.components.fundedEntitlement, _integer(expected.fundedEntitlement));
        assertEq(actual.components.unfundedGap, _integer(expected.unfundedGap));
        assertEq(
            actual.components.nominalRemaining,
            actual.components.nominalUnits - actual.components.paidAssets
        );
        assertEq(
            actual.components.nominalUnits,
            actual.components.paidAssets + actual.components.fundedEntitlement
                + actual.components.unfundedGap
        );
        assertEq(ledger.positionNominal(positionId), actual.components.nominalUnits);
        assertEq(ledger.positionNominalRemaining(positionId), actual.components.nominalRemaining);
    }

    function _integer(ReferenceRecoveryModel.Rational memory value)
        internal
        pure
        returns (uint256)
    {
        assertEq(value.denominator, 1);
        return value.numerator;
    }

    function _assertRational(
        ReferenceRecoveryModel.Rational memory value,
        uint256 numerator,
        uint256 denominator
    ) internal pure {
        assertEq(value.numerator, numerator);
        assertEq(value.denominator, denominator);
    }

    function _measureColdAndWarmView(CreditLedger target, bytes32 positionId)
        internal
        returns (uint256 coldGas, uint256 warmGas)
    {
        vm.cool(address(target));
        uint256 gasBefore = gasleft();
        PositionView memory cold = target.getPosition(positionId);
        coldGas = gasBefore - gasleft();

        gasBefore = gasleft();
        PositionView memory warm = target.getPosition(positionId);
        warmGas = gasBefore - gasleft();

        assertTrue(cold.exists);
        assertEq(keccak256(abi.encode(cold)), keccak256(abi.encode(warm)));
    }

    function _assertProductionClaimPermutationMatches(
        uint8 first,
        uint8 second,
        uint8 third,
        uint256[3] memory expected
    ) internal {
        uint256[3] memory actual = _runProductionClaimPermutation(first, second, third);
        assertEq(actual[0], expected[0]);
        assertEq(actual[1], expected[1]);
        assertEq(actual[2], expected[2]);
    }

    function _runProductionClaimPermutation(uint8 first, uint8 second, uint8 third)
        internal
        returns (uint256[3] memory payouts)
    {
        (, CreditLedger localLedger, address localEscrow) =
            _deployCore(keccak256(abi.encode("claim-order", first, second, third)));
        MockERC20 localToken = new MockERC20();

        bytes32 dealId = keccak256(abi.encode("claim-order-deal", first, second, third));
        uint256 totalNominal = PERM_NOMINAL_A + PERM_NOMINAL_B + PERM_NOMINAL_C;
        _fundDeal(localLedger, localToken, localEscrow, dealId, totalNominal, 0, 1);

        localToken.burn(address(localLedger), totalNominal - PERM_ENTRY_ASSETS);
        localLedger.checkpointBoundary(address(localToken));

        bytes32 terminalHash = keccak256(abi.encode("claim-order-terminal", first, second, third));
        (bytes32 positionA, bytes32 positionB, bytes32 positionC) = _settleThreeWay(
            localLedger,
            localToken,
            localEscrow,
            dealId,
            terminalHash,
            PERM_NOMINAL_A,
            PERM_NOMINAL_B,
            PERM_NOMINAL_C
        );

        bytes32[3] memory ids = [positionA, positionB, positionC];
        uint8[3] memory order = [first, second, third];
        for (uint256 i; i < order.length; ++i) {
            uint8 beneficiary = order[i];
            PositionPayoutResult memory paid =
                localLedger.claimRecovery(ids[beneficiary], type(uint256).max);
            payouts[beneficiary] = paid.paidAmount;
        }

        assertEq(
            localLedger.deficitPaidAssets(address(localToken)), payouts[0] + payouts[1] + payouts[2]
        );
        assertEq(
            localLedger.accountedAssets(address(localToken)),
            PERM_ENTRY_ASSETS - (payouts[0] + payouts[1] + payouts[2])
        );
    }

    function _measureWithdrawAndSettleGas(
        CreditLedger target,
        MockERC20 asset,
        address targetEscrow,
        bytes32 terminalPosition,
        string memory label
    ) internal returns (uint256 withdrawGas, uint256 settleGas) {
        vm.cool(address(target));
        uint256 gasBefore = gasleft();
        PositionPayoutResult memory withdrawn = target.withdrawPosition(terminalPosition, 1);
        withdrawGas = gasBefore - gasleft();
        assertEq(withdrawn.paidAmount, 1);

        bytes32 dealId = keccak256(abi.encode("settle-gas", label));
        _fundDeal(target, asset, targetEscrow, dealId, 50, 0, uint256(keccak256(bytes(label))));
        bytes32 terminalHash = keccak256(abi.encode("settle-gas-terminal", label));
        bytes32 boundaryId =
            DealHashing.custodyBoundaryId(target.chainId(), 2, address(target), address(asset));
        bytes32 child = DealHashing.positionId(
            boundaryId, PositionKind.DealTerminal, dealId, terminalHash, HOLDER_RECEIVER
        );
        TerminalAllocation[] memory allocations = new TerminalAllocation[](1);
        allocations[0] =
            TerminalAllocation({beneficiary: HOLDER_RECEIVER, amount: 50, positionId: child});
        vm.cool(address(target));
        gasBefore = gasleft();
        vm.prank(targetEscrow);
        target.settleDealAndReservations(dealId, address(asset), terminalHash, allocations);
        settleGas = gasBefore - gasleft();
        assertTrue(target.positionExists(child));
    }

    function _measureMutationPaths(CreditLedger target, MockERC20 asset, bytes32 positionId)
        internal
        returns (uint256 claimGas, uint256 checkpointGas, uint256 recoveryGas)
    {
        vm.cool(address(target));
        uint256 gasBefore = gasleft();
        PositionPayoutResult memory claimed = target.claimRecovery(positionId, 1);
        claimGas = gasBefore - gasleft();
        assertEq(claimed.paidAmount, 1);

        asset.burn(address(target), 1);
        vm.cool(address(target));
        gasBefore = gasleft();
        uint8 status = target.checkpointBoundary(address(asset));
        checkpointGas = gasBefore - gasleft();
        assertEq(status, 4);

        asset.mint(address(this), 1);
        asset.approve(address(target), 1);
        vm.cool(address(target));
        gasBefore = gasleft();
        target.depositRecovery(address(asset), 1);
        recoveryGas = gasBefore - gasleft();
    }

    function _settleThreeWay(
        CreditLedger target,
        MockERC20 asset,
        address targetEscrow,
        bytes32 dealId,
        bytes32 terminalHash,
        uint256 amountA,
        uint256 amountB,
        uint256 amountC
    ) internal returns (bytes32 positionA, bytes32 positionB, bytes32 positionC) {
        bytes32 boundaryId =
            DealHashing.custodyBoundaryId(target.chainId(), 2, address(target), address(asset));
        positionA = DealHashing.positionId(
            boundaryId, PositionKind.DealTerminal, dealId, terminalHash, HOLDER_RECEIVER
        );
        positionB = DealHashing.positionId(
            boundaryId, PositionKind.DealTerminal, dealId, terminalHash, PROVIDER_RECEIVER
        );
        positionC = DealHashing.positionId(
            boundaryId, PositionKind.DealTerminal, dealId, terminalHash, THIRD_RECEIVER
        );
        TerminalAllocation[] memory allocations = new TerminalAllocation[](3);
        allocations[0] = TerminalAllocation({
            beneficiary: HOLDER_RECEIVER, amount: amountA, positionId: positionA
        });
        allocations[1] = TerminalAllocation({
            beneficiary: PROVIDER_RECEIVER, amount: amountB, positionId: positionB
        });
        allocations[2] = TerminalAllocation({
            beneficiary: THIRD_RECEIVER, amount: amountC, positionId: positionC
        });
        vm.prank(targetEscrow);
        target.settleDealAndReservations(dealId, address(asset), terminalHash, allocations);
    }
    function _settleBoundedSplit(
        bytes32 dealId,
        bytes32 terminalHash,
        uint256 nominal,
        uint256 childCount,
        uint256 firstShareSeed,
        uint256 secondShareSeed
    ) internal returns (bytes32[] memory childIds) {
        uint256[] memory childNominals = _partitionNominal(
            nominal, childCount, firstShareSeed, secondShareSeed
        );
        TerminalAllocation[] memory allocations = new TerminalAllocation[](childCount);
        childIds = new bytes32[](childCount);
        bytes32 boundaryId =
            DealHashing.custodyBoundaryId(ledger.chainId(), 2, address(ledger), address(token));
        for (uint256 i; i < childCount; ++i) {
            address beneficiary = address(uint160(0x1000 + i));
            bytes32 childId = DealHashing.positionId(
                boundaryId, PositionKind.DealTerminal, dealId, terminalHash, beneficiary
            );
            childIds[i] = childId;
            allocations[i] = TerminalAllocation({
                beneficiary: beneficiary, amount: childNominals[i], positionId: childId
            });
        }
        vm.prank(escrow);
        ledger.settleDealAndReservations(dealId, address(token), terminalHash, allocations);
    }

    function _partitionNominal(
        uint256 nominal,
        uint256 childCount,
        uint256 firstShareSeed,
        uint256 secondShareSeed
    ) internal pure returns (uint256[] memory childNominals) {
        childNominals = new uint256[](childCount);
        if (childCount == 1) {
            childNominals[0] = nominal;
            return childNominals;
        }

        uint256 first = 1 + (firstShareSeed % (nominal - childCount + 1));
        childNominals[0] = first;
        if (childCount == 2) {
            childNominals[1] = nominal - first;
            return childNominals;
        }

        uint256 remaining = nominal - first;
        uint256 second = 1 + (secondShareSeed % (remaining - 1));
        childNominals[1] = second;
        childNominals[2] = remaining - second;
    }

    function _sumChildComponents(bytes32[] memory childIds)
        internal
        view
        returns (SplitComponentTotals memory totals)
    {
        for (uint256 i; i < childIds.length; ++i) {
            PositionView memory child = ledger.getPosition(childIds[i]);
            assertFalse(child.replaced);
            assertEq(child.replacementRoundingDust, 0);
            totals.nominalUnits += child.components.nominalUnits;
            totals.nominalRemaining += child.components.nominalRemaining;
            totals.paidAssets += child.components.paidAssets;
            totals.fundedEntitlement += child.components.fundedEntitlement;
            totals.unfundedGap += child.components.unfundedGap;
        }
    }

    function _fundDeal(
        CreditLedger target,
        MockERC20 asset,
        address targetEscrow,
        bytes32 dealId,
        uint256 principal,
        uint256 activationFee,
        uint256 nonce
    ) internal {
        uint256 total = principal + activationFee;
        asset.mint(holder, total);
        vm.prank(holder);
        asset.approve(address(target), type(uint256).max);

        FundingSpec memory principalSpec = FundingSpec({
            purpose: FundingPurpose.Principal,
            sourceMode: FundingSourceMode.WalletPull,
            token: address(asset),
            amount: principal,
            source: holder,
            sourcePositionId: bytes32(0),
            authority: holder
        });
        FundingSpec memory feeSpec = FundingSpec({
            purpose: FundingPurpose.ActivationFee,
            sourceMode: FundingSourceMode.WalletPull,
            token: address(asset),
            amount: activationFee,
            source: holder,
            sourcePositionId: bytes32(0),
            authority: holder
        });
        bytes32 termsHash = keccak256(abi.encode("recovery-differential", dealId));
        FundingAuth memory principalAuth = FundingAuth({
            termsHash: termsHash,
            fundingSpecHash: DealHashing.hashFundingSpec(principalSpec),
            purpose: FundingPurpose.Principal,
            authority: holder,
            nonce: nonce,
            expiry: uint64(block.timestamp + 1 days)
        });
        FundingAuth memory feeAuth = FundingAuth({
            termsHash: termsHash,
            fundingSpecHash: DealHashing.hashFundingSpec(feeSpec),
            purpose: FundingPurpose.ActivationFee,
            authority: holder,
            nonce: nonce,
            expiry: uint64(block.timestamp + 1 days)
        });
        bytes memory principalSig = _signFundingAuth(target, principalAuth);
        bytes memory feeSig = _signFundingAuth(target, feeAuth);

        vm.prank(targetEscrow);
        target.fundDealAndReservations(
            termsHash,
            dealId,
            address(asset),
            principal,
            activationFee,
            FEE_BENEFICIARY,
            principalSpec,
            feeSpec,
            principalAuth,
            feeAuth,
            principalSig,
            feeSig
        );
    }

    function _signFundingAuth(CreditLedger target, FundingAuth memory auth)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest =
            DealHashing.digest(target.DOMAIN_SEPARATOR(), DealHashing.hashFundingAuth(auth));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(HOLDER_PK, digest);
        return abi.encodePacked(r, s, v);
    }

    function _settleSplit(
        CreditLedger target,
        MockERC20 asset,
        address targetEscrow,
        bytes32 dealId,
        bytes32 terminalHash,
        uint256 holderAmount,
        uint256 providerAmount
    ) internal returns (bytes32 holderPosition, bytes32 providerPosition) {
        bytes32 boundaryId =
            DealHashing.custodyBoundaryId(target.chainId(), 2, address(target), address(asset));
        holderPosition = DealHashing.positionId(
            boundaryId, PositionKind.DealTerminal, dealId, terminalHash, HOLDER_RECEIVER
        );
        providerPosition = DealHashing.positionId(
            boundaryId, PositionKind.DealTerminal, dealId, terminalHash, PROVIDER_RECEIVER
        );
        TerminalAllocation[] memory allocations = new TerminalAllocation[](2);
        allocations[0] = TerminalAllocation({
            beneficiary: HOLDER_RECEIVER, amount: holderAmount, positionId: holderPosition
        });
        allocations[1] = TerminalAllocation({
            beneficiary: PROVIDER_RECEIVER, amount: providerAmount, positionId: providerPosition
        });
        vm.prank(targetEscrow);
        target.settleDealAndReservations(dealId, address(asset), terminalHash, allocations);
    }

    function _depositRecovery(CreditLedger target, MockERC20 asset, uint256 amount) internal {
        asset.mint(address(this), amount);
        asset.approve(address(target), amount);
        target.depositRecovery(address(asset), amount);
    }

    function _dealPositionId(CreditLedger target, MockERC20 asset, bytes32 dealId)
        internal
        view
        returns (bytes32)
    {
        bytes32 boundaryId =
            DealHashing.custodyBoundaryId(target.chainId(), 2, address(target), address(asset));
        return
            DealHashing.positionId(
                boundaryId, PositionKind.ActiveDeal, dealId, bytes32(0), address(0)
            );
    }

    function _feePositionId(
        CreditLedger target,
        MockERC20 asset,
        bytes32 dealId,
        address beneficiary
    ) internal view returns (bytes32) {
        bytes32 boundaryId = DealHashing.custodyBoundaryId(
            target.chainId(), 2, address(target), address(asset)
        );
        return DealHashing.positionId(
            boundaryId, PositionKind.ActivationFee, dealId, bytes32(0), beneficiary
        );
    }

    function _deployCore(bytes32 salt)
        internal
        returns (CoreDeployer deployer, CreditLedger deployedLedger, address deployedEscrow)
    {
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
        deployedLedger = deployer.ledger();
        deployedEscrow = address(deployer.escrow());
    }
}
