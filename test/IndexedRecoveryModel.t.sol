// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IndexedRecoveryModel} from "./helpers/IndexedRecoveryModel.sol";
import {ReferenceRecoveryModel} from "./helpers/ReferenceRecoveryModel.sol";

contract IndexedRecoveryModelTest is Test {
    bytes32 internal constant ALICE = keccak256("alice-position");
    bytes32 internal constant BOB = keccak256("bob-position");
    bytes32 internal constant CAROL = keccak256("carol-position");
    bytes32 internal constant DEAL = keccak256("active-deal");
    bytes32 internal constant HOLDER = keccak256("holder-child");
    bytes32 internal constant PROVIDER = keccak256("provider-child");
    bytes32 internal constant FEE = keccak256("fee-child");
    uint256 internal constant UNLIMITED_CLAIM = type(uint256).max;

    function test_differential_asymmetricClaimsRecoveryAndRepeatedLoss() public {
        (IndexedRecoveryModel indexedModel, ReferenceRecoveryModel referenceModel) = _newModels();
        _addHealthyPosition(indexedModel, referenceModel, ALICE, 100, false);
        _addHealthyPosition(indexedModel, referenceModel, BOB, 300, false);
        _enterDeficit(indexedModel, referenceModel, 200);

        assertEq(_claim(indexedModel, referenceModel, ALICE, 20), 20);
        assertEq(_claim(indexedModel, referenceModel, BOB, UNLIMITED_CLAIM), 150);
        _depositRecovery(indexedModel, referenceModel, 40);
        assertTrue(_observe(indexedModel, referenceModel, 35));

        assertEq(_claim(indexedModel, referenceModel, ALICE, 7), 7);
        _depositRecovery(indexedModel, referenceModel, 15);
        assertTrue(_observe(indexedModel, referenceModel, 21));
    }

    function test_differential_fullLossFullRecoveryDuplicateAndOverRecovery() public {
        (IndexedRecoveryModel indexedModel, ReferenceRecoveryModel referenceModel) = _newModels();
        _addHealthyPosition(indexedModel, referenceModel, ALICE, 40, false);
        _addHealthyPosition(indexedModel, referenceModel, BOB, 60, false);
        _enterDeficit(indexedModel, referenceModel, 30);

        assertTrue(_observe(indexedModel, referenceModel, 0));
        assertFalse(_observe(indexedModel, referenceModel, 0));

        vm.expectRevert(IndexedRecoveryModel.RecoveryExceedsGap.selector);
        indexedModel.depositRecovery(101);
        vm.expectRevert(ReferenceRecoveryModel.RecoveryExceedsGap.selector);
        referenceModel.depositRecovery(101);
        _assertEquivalent(indexedModel, referenceModel);

        _depositRecovery(indexedModel, referenceModel, 100);
        assertEq(indexedModel.generation(), 3);

        vm.expectRevert(IndexedRecoveryModel.RecoveryExceedsGap.selector);
        indexedModel.depositRecovery(1);
        vm.expectRevert(ReferenceRecoveryModel.RecoveryExceedsGap.selector);
        referenceModel.depositRecovery(1);
        _assertEquivalent(indexedModel, referenceModel);

        vm.expectRevert(IndexedRecoveryModel.NewExposureForbidden.selector);
        indexedModel.addHealthyPosition(CAROL, 1, false);
        vm.expectRevert(ReferenceRecoveryModel.NewExposureForbidden.selector);
        referenceModel.addHealthyPosition(CAROL, 1, false);
        _assertEquivalent(indexedModel, referenceModel);

        assertEq(_claim(indexedModel, referenceModel, ALICE, UNLIMITED_CLAIM), 40);
        assertEq(_claim(indexedModel, referenceModel, BOB, UNLIMITED_CLAIM), 60);
    }

    function test_differential_fractionalEntryUsesNormalizedExactComponents() public {
        (IndexedRecoveryModel indexedModel, ReferenceRecoveryModel referenceModel) = _newModels();
        _addHealthyPosition(indexedModel, referenceModel, ALICE, 2, false);
        _addHealthyPosition(indexedModel, referenceModel, BOB, 4, false);
        _enterDeficit(indexedModel, referenceModel, 2);

        IndexedRecoveryModel.Position memory alice = indexedModel.getPosition(ALICE);
        _assertIndexedRational(alice.fundedEntitlement, 2, 3);
        _assertIndexedRational(alice.unfundedGap, 4, 3);
        IndexedRecoveryModel.Position memory bob = indexedModel.getPosition(BOB);
        _assertIndexedRational(bob.fundedEntitlement, 4, 3);
        _assertIndexedRational(bob.unfundedGap, 8, 3);

        assertEq(_claim(indexedModel, referenceModel, ALICE, UNLIMITED_CLAIM), 0);
        assertEq(_claim(indexedModel, referenceModel, BOB, UNLIMITED_CLAIM), 1);
        _depositRecovery(indexedModel, referenceModel, 1);
    }

    function test_differential_terminalSplitBeforeAndAfterRecovery() public {
        {
            (IndexedRecoveryModel indexedModel, ReferenceRecoveryModel referenceModel) =
                _newModels();
            _addHealthyPosition(indexedModel, referenceModel, DEAL, 5, true);
            _enterDeficit(indexedModel, referenceModel, 2);
            _split(indexedModel, referenceModel, DEAL, _twoChildIds(), _twoChildNominals(2, 3));
            _depositRecovery(indexedModel, referenceModel, 3);
            assertEq(_claim(indexedModel, referenceModel, HOLDER, UNLIMITED_CLAIM), 2);
            assertEq(_claim(indexedModel, referenceModel, PROVIDER, UNLIMITED_CLAIM), 3);
        }

        {
            (IndexedRecoveryModel indexedModel, ReferenceRecoveryModel referenceModel) =
                _newModels();
            _addHealthyPosition(indexedModel, referenceModel, DEAL, 10, true);
            _enterDeficit(indexedModel, referenceModel, 4);
            _depositRecovery(indexedModel, referenceModel, 2);
            _split(indexedModel, referenceModel, DEAL, _twoChildIds(), _twoChildNominals(4, 6));
            assertEq(_claim(indexedModel, referenceModel, HOLDER, UNLIMITED_CLAIM), 2);
            assertEq(_claim(indexedModel, referenceModel, PROVIDER, UNLIMITED_CLAIM), 3);
            _depositRecovery(indexedModel, referenceModel, 4);
        }
    }

    function test_differential_threeWaySplitAfterClaimRecoveryAndLoss() public {
        (IndexedRecoveryModel indexedModel, ReferenceRecoveryModel referenceModel) = _newModels();
        _addHealthyPosition(indexedModel, referenceModel, ALICE, 100, false);
        _addHealthyPosition(indexedModel, referenceModel, DEAL, 500, true);
        _enterDeficit(indexedModel, referenceModel, 300);
        assertEq(_claim(indexedModel, referenceModel, ALICE, 25), 25);
        _depositRecovery(indexedModel, referenceModel, 75);
        assertTrue(_observe(indexedModel, referenceModel, 175));

        bytes32[] memory childIds = new bytes32[](3);
        childIds[0] = HOLDER;
        childIds[1] = PROVIDER;
        childIds[2] = FEE;
        uint256[] memory childNominals = new uint256[](3);
        childNominals[0] = 300;
        childNominals[1] = 130;
        childNominals[2] = 70;
        _split(indexedModel, referenceModel, DEAL, childIds, childNominals);
    }

    function test_differential_dustAndAllClaimOrderPermutations() public {
        _assertClaimPermutation(0, 1, 2);
        _assertClaimPermutation(0, 2, 1);
        _assertClaimPermutation(1, 0, 2);
        _assertClaimPermutation(1, 2, 0);
        _assertClaimPermutation(2, 0, 1);
        _assertClaimPermutation(2, 1, 0);
    }

    function test_domainDistinction_referenceRejectsWideEntry_indexedMaterializesExactly() public {
        (IndexedRecoveryModel indexedModel, ReferenceRecoveryModel referenceModel) = _newModels();
        uint256 largeNominal = uint256(1) << 64;
        uint256 totalNominal = largeNominal + 1;
        uint256 entryAssets = largeNominal - 1;
        _addHealthyPosition(indexedModel, referenceModel, ALICE, largeNominal, false);
        _addHealthyPosition(indexedModel, referenceModel, BOB, 1, false);

        // The iterative oracle rejects because one materialized position numerator exceeds its
        // artificial uint120 bound. The affine model's boundary index remains small and valid.
        vm.expectRevert(ReferenceRecoveryModel.OracleDomainExceeded.selector);
        referenceModel.enterDeficit(entryAssets);
        assertFalse(referenceModel.deficitEntered());
        assertEq(referenceModel.accountedAssets(), totalNominal);
        referenceModel.assertInvariants();

        indexedModel.enterDeficit(entryAssets);
        indexedModel.assertInvariants();
        IndexedRecoveryModel.Position memory alice = indexedModel.getPosition(ALICE);
        _assertIndexedRational(alice.fundedEntitlement, largeNominal * entryAssets, totalNominal);
        _assertIndexedRational(alice.unfundedGap, largeNominal * 2, totalNominal);
        assertGt(alice.fundedEntitlement.numerator, indexedModel.MAX_RATIONAL_PART());
        assertEq(indexedModel.accountedAssets(), entryAssets);
        assertEq(indexedModel.aggregateGap(), 2);
    }

    function test_domainDistinction_referenceRejectsWideCheckpoint_indexedRemainsExact() public {
        (IndexedRecoveryModel indexedModel, ReferenceRecoveryModel referenceModel) = _newModels();
        uint256 totalNominal = uint256(1) << 95;
        uint256 largeNominal = totalNominal - 1;
        uint256 entryAssets = uint256(1) << 94;
        uint256 observedAssets = entryAssets - 1;
        _addHealthyPosition(indexedModel, referenceModel, ALICE, largeNominal, false);
        _addHealthyPosition(indexedModel, referenceModel, BOB, 1, false);
        _enterDeficit(indexedModel, referenceModel, entryAssets);

        // The reference transition is outside its per-position uint120 domain. This is not a
        // differential transition: the affine indices still fit and lazy uint256 materialization
        // preserves the exact wider components.
        vm.expectRevert(ReferenceRecoveryModel.OracleDomainExceeded.selector);
        referenceModel.observeAttributableAssets(observedAssets);
        assertEq(referenceModel.accountedAssets(), entryAssets);
        referenceModel.assertInvariants();

        assertTrue(indexedModel.observeAttributableAssets(observedAssets));
        indexedModel.assertInvariants();
        IndexedRecoveryModel.Position memory alice = indexedModel.getPosition(ALICE);
        _assertIndexedRational(alice.fundedEntitlement, largeNominal * observedAssets, totalNominal);
        _assertIndexedRational(
            alice.unfundedGap, largeNominal * (totalNominal - observedAssets), totalNominal
        );
        assertGt(alice.fundedEntitlement.numerator, indexedModel.MAX_RATIONAL_PART());
        assertEq(indexedModel.accountedAssets(), observedAssets);
        assertEq(indexedModel.aggregateGap(), totalNominal - observedAssets);
    }

    function test_adversarialDenominatorGrowthRejectsBeforeMutation() public {
        (IndexedRecoveryModel indexedModel, ReferenceRecoveryModel referenceModel) = _newModels();
        _addHealthyPosition(indexedModel, referenceModel, ALICE, 2, false);
        _addHealthyPosition(indexedModel, referenceModel, BOB, 2, false);
        _enterDeficit(indexedModel, referenceModel, 2);
        assertEq(_claim(indexedModel, referenceModel, ALICE, 1), 1);

        for (uint256 i; i < 59; ++i) {
            _depositRecovery(indexedModel, referenceModel, 1);
            assertTrue(_observe(indexedModel, referenceModel, 1));
        }

        IndexedRecoveryModel.Rational memory coefficientBefore = indexedModel.gapCoefficient();
        IndexedRecoveryModel.Rational memory scaleBefore = indexedModel.historyScale();
        IndexedRecoveryModel.Position memory aliceBefore = indexedModel.getPosition(ALICE);
        assertEq(coefficientBefore.denominator, uint256(1) << 119);
        assertEq(scaleBefore.numerator, 1);
        assertEq(scaleBefore.denominator, uint256(1) << 118);

        uint256 generationBefore = indexedModel.generation();
        uint256 accountedBefore = indexedModel.accountedAssets();
        uint256 gapBefore = indexedModel.aggregateGap();
        vm.expectRevert(IndexedRecoveryModel.OracleDomainExceeded.selector);
        indexedModel.depositRecovery(1);

        _assertIndexedRational(indexedModel.gapCoefficient(), coefficientBefore);
        _assertIndexedRational(indexedModel.historyScale(), scaleBefore);
        _assertIndexedPosition(indexedModel.getPosition(ALICE), aliceBefore);
        assertEq(indexedModel.generation(), generationBefore);
        assertEq(indexedModel.accountedAssets(), accountedBefore);
        assertEq(indexedModel.aggregateGap(), gapBefore);
        indexedModel.assertInvariants();

        // The independent oracle can still represent this next semantic transition. The affine
        // boundary index exhausts its deliberately bounded exact domain first and rejects safely.
        referenceModel.depositRecovery(1);
        referenceModel.assertInvariants();
        assertEq(referenceModel.accountedAssets(), 2);
    }

    function _assertClaimPermutation(uint8 first, uint8 second, uint8 third) internal {
        (IndexedRecoveryModel indexedModel, ReferenceRecoveryModel referenceModel) = _newModels();
        bytes32[3] memory ids = [ALICE, BOB, CAROL];
        uint256[3] memory nominals = [uint256(5), uint256(7), uint256(11)];
        uint256[3] memory expectedPayouts = [uint256(2), uint256(3), uint256(4)];

        for (uint256 i; i < ids.length; ++i) {
            _addHealthyPosition(indexedModel, referenceModel, ids[i], nominals[i], false);
        }
        _enterDeficit(indexedModel, referenceModel, 10);

        uint8[3] memory order = [first, second, third];
        for (uint256 i; i < order.length; ++i) {
            uint8 beneficiary = order[i];
            assertEq(
                _claim(indexedModel, referenceModel, ids[beneficiary], UNLIMITED_CLAIM),
                expectedPayouts[beneficiary]
            );
        }

        assertEq(indexedModel.aggregatePaidAssets(), 9);
        assertEq(indexedModel.accountedAssets(), 1);
        assertEq(indexedModel.aggregateGap(), 13);
    }

    function _newModels()
        internal
        returns (IndexedRecoveryModel indexedModel, ReferenceRecoveryModel referenceModel)
    {
        indexedModel = new IndexedRecoveryModel();
        referenceModel = new ReferenceRecoveryModel();
        _assertEquivalent(indexedModel, referenceModel);
    }

    function _addHealthyPosition(
        IndexedRecoveryModel indexedModel,
        ReferenceRecoveryModel referenceModel,
        bytes32 positionId,
        uint256 nominalUnits,
        bool active
    ) internal {
        indexedModel.addHealthyPosition(positionId, nominalUnits, active);
        referenceModel.addHealthyPosition(positionId, nominalUnits, active);
        _assertEquivalent(indexedModel, referenceModel);
    }

    function _enterDeficit(
        IndexedRecoveryModel indexedModel,
        ReferenceRecoveryModel referenceModel,
        uint256 attributableAssets
    ) internal {
        indexedModel.enterDeficit(attributableAssets);
        referenceModel.enterDeficit(attributableAssets);
        _assertEquivalent(indexedModel, referenceModel);
    }

    function _observe(
        IndexedRecoveryModel indexedModel,
        ReferenceRecoveryModel referenceModel,
        uint256 observedAssets
    ) internal returns (bool changed) {
        changed = indexedModel.observeAttributableAssets(observedAssets);
        assertEq(changed, referenceModel.observeAttributableAssets(observedAssets));
        _assertEquivalent(indexedModel, referenceModel);
    }

    function _depositRecovery(
        IndexedRecoveryModel indexedModel,
        ReferenceRecoveryModel referenceModel,
        uint256 amount
    ) internal {
        indexedModel.depositRecovery(amount);
        referenceModel.depositRecovery(amount);
        _assertEquivalent(indexedModel, referenceModel);
    }

    function _claim(
        IndexedRecoveryModel indexedModel,
        ReferenceRecoveryModel referenceModel,
        bytes32 positionId,
        uint256 maxAmount
    ) internal returns (uint256 paidAmount) {
        paidAmount = indexedModel.claim(positionId, maxAmount);
        assertEq(paidAmount, referenceModel.claim(positionId, maxAmount));
        _assertEquivalent(indexedModel, referenceModel);
    }

    function _split(
        IndexedRecoveryModel indexedModel,
        ReferenceRecoveryModel referenceModel,
        bytes32 parentId,
        bytes32[] memory childIds,
        uint256[] memory childNominalUnits
    ) internal {
        indexedModel.splitActivePosition(parentId, childIds, childNominalUnits);
        referenceModel.splitActivePosition(parentId, childIds, childNominalUnits);
        _assertEquivalent(indexedModel, referenceModel);
    }

    function _assertEquivalent(
        IndexedRecoveryModel indexedModel,
        ReferenceRecoveryModel referenceModel
    ) internal view {
        indexedModel.assertInvariants();
        referenceModel.assertInvariants();
        assertEq(indexedModel.deficitEntered(), referenceModel.deficitEntered());
        assertEq(indexedModel.accountedAssets(), referenceModel.accountedAssets());
        assertEq(indexedModel.aggregateNominalUnits(), referenceModel.aggregateNominalUnits());
        assertEq(indexedModel.aggregatePaidAssets(), referenceModel.aggregatePaidAssets());
        assertEq(indexedModel.fixedNominalUnits(), referenceModel.fixedNominalUnits());
        assertEq(indexedModel.aggregateGap(), referenceModel.aggregateGap());

        uint256 count = indexedModel.positionCount();
        assertEq(count, referenceModel.positionCount());
        for (uint256 i; i < count; ++i) {
            bytes32 positionId = indexedModel.positionIdAt(i);
            assertEq(positionId, referenceModel.positionIdAt(i));
            _assertEquivalentPosition(
                indexedModel.getPosition(positionId), referenceModel.getPosition(positionId)
            );
        }

        (
            IndexedRecoveryModel.Rational memory indexedNominal,
            IndexedRecoveryModel.Rational memory indexedPaid,
            IndexedRecoveryModel.Rational memory indexedFunded,
            IndexedRecoveryModel.Rational memory indexedGap
        ) = indexedModel.aggregateComponents();
        (
            ReferenceRecoveryModel.Rational memory referenceNominal,
            ReferenceRecoveryModel.Rational memory referencePaid,
            ReferenceRecoveryModel.Rational memory referenceFunded,
            ReferenceRecoveryModel.Rational memory referenceGap
        ) = referenceModel.aggregateComponents();
        _assertRationalEqual(indexedNominal, referenceNominal);
        _assertRationalEqual(indexedPaid, referencePaid);
        _assertRationalEqual(indexedFunded, referenceFunded);
        _assertRationalEqual(indexedGap, referenceGap);
    }

    function _assertEquivalentPosition(
        IndexedRecoveryModel.Position memory indexedModel,
        ReferenceRecoveryModel.Position memory referenceModel
    ) internal pure {
        _assertRationalEqual(indexedModel.nominalUnits, referenceModel.nominalUnits);
        _assertRationalEqual(indexedModel.paidAssets, referenceModel.paidAssets);
        _assertRationalEqual(indexedModel.fundedEntitlement, referenceModel.fundedEntitlement);
        _assertRationalEqual(indexedModel.unfundedGap, referenceModel.unfundedGap);
        assertEq(indexedModel.active, referenceModel.active);
        assertEq(indexedModel.consumed, referenceModel.consumed);
        assertEq(indexedModel.replaced, referenceModel.replaced);
        assertEq(indexedModel.exists, referenceModel.exists);
    }

    function _assertRationalEqual(
        IndexedRecoveryModel.Rational memory indexedModel,
        ReferenceRecoveryModel.Rational memory referenceModel
    ) internal pure {
        assertEq(indexedModel.numerator, referenceModel.numerator);
        assertEq(indexedModel.denominator, referenceModel.denominator);
    }

    function _assertIndexedRational(
        IndexedRecoveryModel.Rational memory actual,
        IndexedRecoveryModel.Rational memory expected
    ) internal pure {
        assertEq(actual.numerator, expected.numerator);
        assertEq(actual.denominator, expected.denominator);
    }

    function _assertIndexedRational(
        IndexedRecoveryModel.Rational memory actual,
        uint256 expectedNumerator,
        uint256 expectedDenominator
    ) internal pure {
        assertEq(actual.numerator, expectedNumerator);
        assertEq(actual.denominator, expectedDenominator);
    }

    function _assertIndexedPosition(
        IndexedRecoveryModel.Position memory actual,
        IndexedRecoveryModel.Position memory expected
    ) internal pure {
        _assertIndexedRational(actual.nominalUnits, expected.nominalUnits);
        _assertIndexedRational(actual.paidAssets, expected.paidAssets);
        _assertIndexedRational(actual.fundedEntitlement, expected.fundedEntitlement);
        _assertIndexedRational(actual.unfundedGap, expected.unfundedGap);
        assertEq(actual.active, expected.active);
        assertEq(actual.consumed, expected.consumed);
        assertEq(actual.replaced, expected.replaced);
        assertEq(actual.exists, expected.exists);
    }

    function _twoChildIds() internal pure returns (bytes32[] memory childIds) {
        childIds = new bytes32[](2);
        childIds[0] = HOLDER;
        childIds[1] = PROVIDER;
    }

    function _twoChildNominals(uint256 first, uint256 second)
        internal
        pure
        returns (uint256[] memory childNominals)
    {
        childNominals = new uint256[](2);
        childNominals[0] = first;
        childNominals[1] = second;
    }
}
