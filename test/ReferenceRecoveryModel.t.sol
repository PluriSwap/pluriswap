// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReferenceRecoveryModel} from "./helpers/ReferenceRecoveryModel.sol";

contract ReferenceRecoveryModelTest is Test {
    bytes32 internal constant ALICE = keccak256("alice-position");
    bytes32 internal constant BOB = keccak256("bob-position");
    bytes32 internal constant CAROL = keccak256("carol-position");
    bytes32 internal constant DEAL = keccak256("active-deal");
    bytes32 internal constant HOLDER = keccak256("holder-child");
    bytes32 internal constant PROVIDER = keccak256("provider-child");
    bytes32 internal constant FEE = keccak256("fee-child");
    uint256 internal constant UNLIMITED_CLAIM = type(uint256).max;

    function test_twoEqualPositions_claimLossAndTwoRecoveriesReconcile() public {
        ReferenceRecoveryModel model = new ReferenceRecoveryModel();
        model.addHealthyPosition(ALICE, 500, false);
        _assertInvariants(model);
        model.addHealthyPosition(BOB, 500, false);
        _assertInvariants(model);

        model.enterDeficit(600);
        _assertInvariants(model);
        _assertPosition(model, ALICE, 500, 1, 0, 1, 300, 1, 200, 1, false, false, false);
        _assertPosition(model, BOB, 500, 1, 0, 1, 300, 1, 200, 1, false, false, false);

        assertEq(model.claim(ALICE, UNLIMITED_CLAIM), 300);
        _assertInvariants(model);
        _assertPosition(model, ALICE, 500, 1, 300, 1, 0, 1, 200, 1, false, false, false);

        assertTrue(model.observeAttributableAssets(150));
        _assertInvariants(model);
        _assertPosition(model, ALICE, 500, 1, 300, 1, 0, 1, 200, 1, false, false, false);
        _assertPosition(model, BOB, 500, 1, 0, 1, 150, 1, 350, 1, false, false, false);

        uint256 nominalBeforeRecovery = model.aggregateNominalUnits();
        model.depositRecovery(275);
        _assertInvariants(model);
        _assertPosition(model, ALICE, 500, 1, 300, 1, 100, 1, 100, 1, false, false, false);
        _assertPosition(model, BOB, 500, 1, 0, 1, 325, 1, 175, 1, false, false, false);

        model.depositRecovery(275);
        _assertInvariants(model);
        assertEq(model.aggregateNominalUnits(), nominalBeforeRecovery);
        _assertPosition(model, ALICE, 500, 1, 300, 1, 200, 1, 0, 1, false, false, false);
        _assertPosition(model, BOB, 500, 1, 0, 1, 500, 1, 0, 1, false, false, false);

        assertEq(model.claim(ALICE, UNLIMITED_CLAIM), 200);
        _assertInvariants(model);
        _assertPosition(model, ALICE, 500, 1, 500, 1, 0, 1, 0, 1, false, true, false);
        assertEq(model.claim(BOB, UNLIMITED_CLAIM), 500);
        _assertInvariants(model);
        _assertPosition(model, BOB, 500, 1, 500, 1, 0, 1, 0, 1, false, true, false);
        assertEq(model.claim(ALICE, UNLIMITED_CLAIM), 0);
        _assertInvariants(model);

        assertEq(model.aggregatePaidAssets(), 1_000);
        assertEq(model.accountedAssets(), 0);
        assertEq(model.aggregateGap(), 0);
        assertEq(model.aggregateNominalUnits(), 1_000);
    }

    function test_activeDealAtSixtyPercentSplitsWithoutRoundingComponents() public {
        ReferenceRecoveryModel model = new ReferenceRecoveryModel();
        model.addHealthyPosition(DEAL, 500, true);
        _assertInvariants(model);
        model.enterDeficit(300);
        _assertInvariants(model);
        _assertPosition(model, DEAL, 500, 1, 0, 1, 300, 1, 200, 1, true, false, false);

        vm.expectRevert(ReferenceRecoveryModel.PositionNotClaimable.selector);
        model.claim(DEAL, UNLIMITED_CLAIM);
        _assertInvariants(model);

        bytes32[] memory childIds = new bytes32[](3);
        childIds[0] = HOLDER;
        childIds[1] = PROVIDER;
        childIds[2] = FEE;
        uint256[] memory childNominals = new uint256[](3);
        childNominals[0] = 300;
        childNominals[1] = 130;
        childNominals[2] = 70;

        model.splitActivePosition(DEAL, childIds, childNominals);
        _assertInvariants(model);

        ReferenceRecoveryModel.Position memory parent = model.getPosition(DEAL);
        _assertPosition(model, DEAL, 500, 1, 0, 1, 300, 1, 200, 1, false, true, true);
        assertEq(model.positionCount(), 4);
        _assertPosition(model, HOLDER, 300, 1, 0, 1, 180, 1, 120, 1, false, false, false);
        _assertPosition(model, PROVIDER, 130, 1, 0, 1, 78, 1, 52, 1, false, false, false);
        _assertPosition(model, FEE, 70, 1, 0, 1, 42, 1, 28, 1, false, false, false);

        _assertChildWithinParent(model.getPosition(HOLDER), parent);
        _assertChildWithinParent(model.getPosition(PROVIDER), parent);
        _assertChildWithinParent(model.getPosition(FEE), parent);

        vm.expectRevert(ReferenceRecoveryModel.PositionNotSplittable.selector);
        model.splitActivePosition(DEAL, childIds, childNominals);
        _assertInvariants(model);
    }

    function test_claimOrderIndependentForThreeBeneficiariesWithFloorDust() public {
        _assertClaimPermutation(0, 1, 2);
        _assertClaimPermutation(0, 2, 1);
        _assertClaimPermutation(1, 0, 2);
        _assertClaimPermutation(1, 2, 0);
        _assertClaimPermutation(2, 0, 1);
        _assertClaimPermutation(2, 1, 0);
    }

    function test_recoveryAfterAsymmetricClaims_thenRepeatedLossPreservesPayments() public {
        ReferenceRecoveryModel model = new ReferenceRecoveryModel();
        model.addHealthyPosition(ALICE, 100, false);
        _assertInvariants(model);
        model.addHealthyPosition(BOB, 300, false);
        _assertInvariants(model);
        model.enterDeficit(200);
        _assertInvariants(model);

        assertEq(model.claim(ALICE, 20), 20);
        _assertInvariants(model);
        assertEq(model.claim(BOB, UNLIMITED_CLAIM), 150);
        _assertInvariants(model);

        model.depositRecovery(40);
        _assertInvariants(model);
        _assertPosition(model, ALICE, 100, 1, 20, 1, 40, 1, 40, 1, false, false, false);
        _assertPosition(model, BOB, 300, 1, 150, 1, 30, 1, 120, 1, false, false, false);

        assertTrue(model.observeAttributableAssets(35));
        _assertInvariants(model);
        _assertPosition(model, ALICE, 100, 1, 20, 1, 20, 1, 60, 1, false, false, false);
        _assertPosition(model, BOB, 300, 1, 150, 1, 15, 1, 135, 1, false, false, false);
        assertEq(model.aggregatePaidAssets(), 170);
    }

    function test_fullLossDuplicateObservationFullRecoveryAndOverRecoveryRejection() public {
        ReferenceRecoveryModel model = new ReferenceRecoveryModel();
        model.addHealthyPosition(ALICE, 40, false);
        _assertInvariants(model);
        model.addHealthyPosition(BOB, 60, false);
        _assertInvariants(model);
        model.enterDeficit(30);
        _assertInvariants(model);

        vm.expectRevert(ReferenceRecoveryModel.DeficitAlreadyEntered.selector);
        model.enterDeficit(29);
        _assertInvariants(model);

        assertTrue(model.observeAttributableAssets(0));
        _assertInvariants(model);
        assertFalse(model.observeAttributableAssets(0));
        _assertInvariants(model);
        assertEq(model.accountedAssets(), 0);
        assertEq(model.aggregateGap(), 100);

        vm.expectRevert(ReferenceRecoveryModel.RecoveryExceedsGap.selector);
        model.depositRecovery(101);
        _assertInvariants(model);

        uint256 nominalBeforeRecovery = model.aggregateNominalUnits();
        model.depositRecovery(100);
        _assertInvariants(model);
        assertEq(model.aggregateNominalUnits(), nominalBeforeRecovery);
        assertEq(model.accountedAssets(), 100);
        assertEq(model.aggregateGap(), 0);
        assertTrue(model.deficitEntered());
        _assertPosition(model, ALICE, 40, 1, 0, 1, 40, 1, 0, 1, false, false, false);
        _assertPosition(model, BOB, 60, 1, 0, 1, 60, 1, 0, 1, false, false, false);

        vm.expectRevert(ReferenceRecoveryModel.RecoveryExceedsGap.selector);
        model.depositRecovery(1);
        vm.expectRevert(ReferenceRecoveryModel.NewExposureForbidden.selector);
        model.addHealthyPosition(CAROL, 1, false);
        _assertInvariants(model);
    }

    function test_invalidSplitCannotCreateOversizedChildOrReuseIds() public {
        ReferenceRecoveryModel model = new ReferenceRecoveryModel();
        model.addHealthyPosition(DEAL, 500, true);
        _assertInvariants(model);
        model.enterDeficit(300);
        _assertInvariants(model);

        bytes32[] memory childIds = new bytes32[](1);
        childIds[0] = HOLDER;
        uint256[] memory oversized = new uint256[](1);
        oversized[0] = 501;
        vm.expectRevert(ReferenceRecoveryModel.InvalidSplit.selector);
        model.splitActivePosition(DEAL, childIds, oversized);
        _assertInvariants(model);

        bytes32[] memory duplicateIds = new bytes32[](2);
        duplicateIds[0] = HOLDER;
        duplicateIds[1] = HOLDER;
        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 250;
        allocations[1] = 250;
        vm.expectRevert(ReferenceRecoveryModel.DuplicatePosition.selector);
        model.splitActivePosition(DEAL, duplicateIds, allocations);
        _assertInvariants(model);
    }

    function test_exactFractionsNormalizeAndInputsAreExplicitlyBounded() public {
        ReferenceRecoveryModel model = new ReferenceRecoveryModel();
        model.addHealthyPosition(ALICE, 2, false);
        _assertInvariants(model);
        model.addHealthyPosition(BOB, 4, false);
        _assertInvariants(model);
        model.enterDeficit(2);
        _assertInvariants(model);

        _assertPosition(model, ALICE, 2, 1, 0, 1, 2, 3, 4, 3, false, false, false);
        _assertPosition(model, BOB, 4, 1, 0, 1, 4, 3, 8, 3, false, false, false);

        ReferenceRecoveryModel boundedModel = new ReferenceRecoveryModel();
        uint256 firstOutOfRangeAmount = boundedModel.MAX_AGGREGATE_AMOUNT() + 1;
        vm.expectRevert(ReferenceRecoveryModel.AmountOutOfRange.selector);
        boundedModel.addHealthyPosition(ALICE, firstOutOfRangeAmount, false);
    }

    function test_fractionalTerminalSplitClaimsChildrenAndPreservesLifecycle() public {
        ReferenceRecoveryModel model = new ReferenceRecoveryModel();
        model.addHealthyPosition(DEAL, 5, true);
        _assertInvariants(model);
        model.enterDeficit(2);
        _assertInvariants(model);
        _assertPosition(model, DEAL, 5, 1, 0, 1, 2, 1, 3, 1, true, false, false);

        bytes32[] memory childIds = new bytes32[](2);
        childIds[0] = HOLDER;
        childIds[1] = PROVIDER;
        uint256[] memory childNominals = new uint256[](2);
        childNominals[0] = 2;
        childNominals[1] = 3;
        model.splitActivePosition(DEAL, childIds, childNominals);
        _assertInvariants(model);

        _assertPosition(model, DEAL, 5, 1, 0, 1, 2, 1, 3, 1, false, true, true);
        _assertPosition(model, HOLDER, 2, 1, 0, 1, 4, 5, 6, 5, false, false, false);
        _assertPosition(model, PROVIDER, 3, 1, 0, 1, 6, 5, 9, 5, false, false, false);

        vm.expectRevert(ReferenceRecoveryModel.PositionNotSplittable.selector);
        model.splitActivePosition(DEAL, childIds, childNominals);
        _assertInvariants(model);

        assertEq(model.claim(HOLDER, UNLIMITED_CLAIM), 0);
        _assertInvariants(model);
        _assertPosition(model, HOLDER, 2, 1, 0, 1, 4, 5, 6, 5, false, false, false);

        assertEq(model.claim(PROVIDER, UNLIMITED_CLAIM), 1);
        _assertInvariants(model);
        _assertPosition(model, PROVIDER, 3, 1, 1, 1, 1, 5, 9, 5, false, false, false);

        model.depositRecovery(3);
        _assertInvariants(model);
        _assertPosition(model, HOLDER, 2, 1, 0, 1, 2, 1, 0, 1, false, false, false);
        _assertPosition(model, PROVIDER, 3, 1, 1, 1, 2, 1, 0, 1, false, false, false);

        assertEq(model.claim(HOLDER, UNLIMITED_CLAIM), 2);
        _assertInvariants(model);
        assertEq(model.claim(PROVIDER, UNLIMITED_CLAIM), 2);
        _assertInvariants(model);
        _assertPosition(model, HOLDER, 2, 1, 2, 1, 0, 1, 0, 1, false, true, false);
        _assertPosition(model, PROVIDER, 3, 1, 3, 1, 0, 1, 0, 1, false, true, false);

        assertEq(model.claim(HOLDER, UNLIMITED_CLAIM), 0);
        assertEq(model.claim(PROVIDER, UNLIMITED_CLAIM), 0);
        _assertInvariants(model);
    }

    function test_compatibleNearBoundarySequenceRemainsExactAcrossCheckpoints() public {
        ReferenceRecoveryModel model = new ReferenceRecoveryModel();
        uint256 totalNominal = uint256(1) << 60;
        uint256 largeNominal = totalNominal - 1;
        uint256 entryAssets = (uint256(1) << 59) - 1;
        uint256 entryGap = totalNominal - entryAssets;

        model.addHealthyPosition(ALICE, largeNominal, false);
        _assertInvariants(model);
        model.addHealthyPosition(BOB, 1, false);
        _assertInvariants(model);
        model.enterDeficit(entryAssets);
        _assertInvariants(model);

        _assertPosition(
            model,
            ALICE,
            largeNominal,
            1,
            0,
            1,
            largeNominal * entryAssets,
            totalNominal,
            largeNominal * entryGap,
            totalNominal,
            false,
            false,
            false
        );

        uint256 observedAssets = entryAssets - 1;
        assertTrue(model.observeAttributableAssets(observedAssets));
        _assertInvariants(model);
        _assertPosition(
            model,
            ALICE,
            largeNominal,
            1,
            0,
            1,
            largeNominal * (observedAssets / 2),
            totalNominal / 2,
            largeNominal * ((totalNominal - observedAssets) / 2),
            totalNominal / 2,
            false,
            false,
            false
        );

        model.depositRecovery(1);
        _assertInvariants(model);
        _assertPosition(
            model,
            ALICE,
            largeNominal,
            1,
            0,
            1,
            largeNominal * entryAssets,
            totalNominal,
            largeNominal * entryGap,
            totalNominal,
            false,
            false,
            false
        );
    }

    function test_incompatibleEntryFailsDomainPreflightWithoutMutation() public {
        ReferenceRecoveryModel model = new ReferenceRecoveryModel();
        uint256 largeNominal = uint256(1) << 64;
        uint256 totalNominal = largeNominal + 1;

        model.addHealthyPosition(ALICE, largeNominal, false);
        _assertInvariants(model);
        model.addHealthyPosition(BOB, 1, false);
        _assertInvariants(model);

        vm.expectRevert(ReferenceRecoveryModel.OracleDomainExceeded.selector);
        model.enterDeficit(largeNominal - 1);

        assertFalse(model.deficitEntered());
        assertEq(model.fixedNominalUnits(), 0);
        assertEq(model.accountedAssets(), totalNominal);
        _assertPosition(
            model, ALICE, largeNominal, 1, 0, 1, largeNominal, 1, 0, 1, false, false, false
        );
        _assertInvariants(model);
    }

    function test_laterCheckpointOutsideDomainFailsPreflightWithoutMutation() public {
        ReferenceRecoveryModel model = new ReferenceRecoveryModel();
        uint256 totalNominal = uint256(1) << 95;
        uint256 largeNominal = totalNominal - 1;
        uint256 entryAssets = uint256(1) << 94;

        model.addHealthyPosition(ALICE, largeNominal, false);
        _assertInvariants(model);
        model.addHealthyPosition(BOB, 1, false);
        _assertInvariants(model);
        model.enterDeficit(entryAssets);
        _assertInvariants(model);
        _assertPosition(
            model,
            ALICE,
            largeNominal,
            1,
            0,
            1,
            largeNominal,
            2,
            largeNominal,
            2,
            false,
            false,
            false
        );

        vm.expectRevert(ReferenceRecoveryModel.OracleDomainExceeded.selector);
        model.observeAttributableAssets(entryAssets - 1);

        assertEq(model.accountedAssets(), entryAssets);
        _assertPosition(
            model,
            ALICE,
            largeNominal,
            1,
            0,
            1,
            largeNominal,
            2,
            largeNominal,
            2,
            false,
            false,
            false
        );
        _assertInvariants(model);
    }

    function _assertClaimPermutation(uint8 first, uint8 second, uint8 third) internal {
        ReferenceRecoveryModel model = new ReferenceRecoveryModel();
        bytes32[3] memory ids = [ALICE, BOB, CAROL];
        uint256[3] memory nominals = [uint256(5), uint256(7), uint256(11)];
        uint256[3] memory expectedPayouts = [uint256(2), uint256(3), uint256(4)];

        for (uint256 i; i < ids.length; ++i) {
            model.addHealthyPosition(ids[i], nominals[i], false);
            _assertInvariants(model);
        }
        model.enterDeficit(10);
        _assertInvariants(model);

        uint8[3] memory order = [first, second, third];
        for (uint256 i; i < order.length; ++i) {
            uint8 beneficiary = order[i];
            assertEq(model.claim(ids[beneficiary], UNLIMITED_CLAIM), expectedPayouts[beneficiary]);
            _assertInvariants(model);
        }

        assertEq(model.aggregatePaidAssets(), 9);
        assertEq(model.accountedAssets(), 1);
        assertEq(model.aggregateGap(), 13);
        assertEq(model.aggregateNominalUnits(), 23);
    }

    function _assertInvariants(ReferenceRecoveryModel model) internal view {
        model.assertInvariants();
    }

    function _assertPosition(
        ReferenceRecoveryModel model,
        bytes32 id,
        uint256 nominalNumerator,
        uint256 nominalDenominator,
        uint256 paidNumerator,
        uint256 paidDenominator,
        uint256 fundedNumerator,
        uint256 fundedDenominator,
        uint256 gapNumerator,
        uint256 gapDenominator,
        bool active,
        bool consumed,
        bool replaced
    ) internal view {
        ReferenceRecoveryModel.Position memory position = model.getPosition(id);
        _assertRational(position.nominalUnits, nominalNumerator, nominalDenominator);
        _assertRational(position.paidAssets, paidNumerator, paidDenominator);
        _assertRational(position.fundedEntitlement, fundedNumerator, fundedDenominator);
        _assertRational(position.unfundedGap, gapNumerator, gapDenominator);
        assertEq(position.active, active);
        assertEq(position.consumed, consumed);
        assertEq(position.replaced, replaced);
    }

    function _assertRational(
        ReferenceRecoveryModel.Rational memory value,
        uint256 expectedNumerator,
        uint256 expectedDenominator
    ) internal pure {
        assertEq(value.numerator, expectedNumerator);
        assertEq(value.denominator, expectedDenominator);
    }

    function _assertChildWithinParent(
        ReferenceRecoveryModel.Position memory child,
        ReferenceRecoveryModel.Position memory parent
    ) internal pure {
        _assertRationalLeq(child.nominalUnits, parent.nominalUnits);
        _assertRationalLeq(child.fundedEntitlement, parent.fundedEntitlement);
        _assertRationalLeq(child.unfundedGap, parent.unfundedGap);
    }

    function _assertRationalLeq(
        ReferenceRecoveryModel.Rational memory left,
        ReferenceRecoveryModel.Rational memory right
    ) internal pure {
        assertLe(left.numerator * right.denominator, right.numerator * left.denominator);
    }
}
