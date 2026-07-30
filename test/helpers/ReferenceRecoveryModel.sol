// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Independent, test-only exact-rational oracle for irreversible deficit accounting.
/// @dev This is a bounded partial exact model, not an oracle for every uint256 input sequence.
/// Aggregate integer amounts may not exceed MAX_AGGREGATE_AMOUNT, every normalized rational
/// numerator and denominator must fit MAX_RATIONAL_PART, and historical IDs are capped by
/// MAX_POSITIONS. The rational domain is sequence-dependent: each operation preflights every
/// resulting component and rejects the whole transition with OracleDomainExceeded if any result
/// would leave it. Thus every accepted transition is exact and leaves the model closed for the
/// next preflight. These bounds also keep addition/subtraction cross-products below 2^241 and
/// rational-times-amount products below 2^216; checked arithmetic remains as a defensive guard.
/// The model deliberately materializes every position, shares no production accounting or index
/// implementation, and is not intended to satisfy production gas-complexity requirements.
contract ReferenceRecoveryModel {
    uint256 public constant MAX_AGGREGATE_AMOUNT = type(uint96).max;
    uint256 public constant MAX_RATIONAL_PART = type(uint120).max;
    uint256 public constant MAX_POSITIONS = 128;

    struct Rational {
        uint256 numerator;
        uint256 denominator;
    }

    struct Position {
        Rational nominalUnits;
        Rational paidAssets;
        Rational fundedEntitlement;
        Rational unfundedGap;
        bool active;
        bool consumed;
        bool replaced;
        bool exists;
    }

    error AmountOutOfRange();
    error DeficitAlreadyEntered();
    error DeficitNotEntered();
    error DuplicatePosition();
    error InvalidClaimCap();
    error InvalidDeficitAssets();
    error InvalidLossCheckpoint();
    error InvalidPosition();
    error InvalidRecoveryAmount();
    error InvalidSplit();
    error InvariantViolation(uint8 code);
    error NewExposureForbidden();
    error OracleDomainExceeded();
    error PositionNotClaimable();
    error PositionNotFound();
    error PositionNotSplittable();
    error RationalOutOfRange();
    error RationalOverflow();
    error RationalUnderflow();
    error RecoveryExceedsGap();
    error TooManyPositions();

    mapping(bytes32 positionId => Position position) private _positions;
    bytes32[] private _positionIds;

    bool public deficitEntered;
    uint256 public accountedAssets;
    uint256 public aggregateNominalUnits;
    uint256 public aggregatePaidAssets;
    uint256 public fixedNominalUnits;

    function addHealthyPosition(bytes32 positionId, uint256 nominalUnits, bool active) external {
        if (deficitEntered) revert NewExposureForbidden();
        if (positionId == bytes32(0) || nominalUnits == 0) revert InvalidPosition();
        _requireAggregateAmount(nominalUnits);
        if (_positions[positionId].exists) revert DuplicatePosition();
        if (_positionIds.length == MAX_POSITIONS) revert TooManyPositions();

        uint256 nextNominal = _checkedAdd(aggregateNominalUnits, nominalUnits);
        if (nextNominal > MAX_AGGREGATE_AMOUNT) revert AmountOutOfRange();

        Rational memory nominal = _fromUint(nominalUnits);
        _positions[positionId] = Position({
            nominalUnits: nominal,
            paidAssets: _zero(),
            fundedEntitlement: nominal,
            unfundedGap: _zero(),
            active: active,
            consumed: false,
            replaced: false,
            exists: true
        });
        _positionIds.push(positionId);
        aggregateNominalUnits = nextNominal;
        accountedAssets = nextNominal;
    }

    function enterDeficit(uint256 attributableAssets) external {
        if (deficitEntered) revert DeficitAlreadyEntered();
        _requireAggregateAmount(attributableAssets);
        if (_positionIds.length == 0 || attributableAssets >= aggregateNominalUnits) {
            revert InvalidDeficitAssets();
        }

        uint256 nominalAtEntry = aggregateNominalUnits;
        uint256 positionLength = _positionIds.length;
        Rational[] memory positionFundedAfter = new Rational[](positionLength);
        Rational[] memory positionGapAfter = new Rational[](positionLength);
        for (uint256 i; i < positionLength; ++i) {
            Position storage position = _positions[_positionIds[i]];
            positionFundedAfter[i] =
                _mulRatio(position.nominalUnits, attributableAssets, nominalAtEntry);
            positionGapAfter[i] = _sub(position.nominalUnits, positionFundedAfter[i]);
        }
        _preflightFundedAndGapTotals(
            positionFundedAfter,
            positionGapAfter,
            attributableAssets,
            nominalAtEntry - attributableAssets
        );

        fixedNominalUnits = nominalAtEntry;
        accountedAssets = attributableAssets;
        deficitEntered = true;
        for (uint256 i; i < positionLength; ++i) {
            Position storage position = _positions[_positionIds[i]];
            position.fundedEntitlement = positionFundedAfter[i];
            position.unfundedGap = positionGapAfter[i];
        }
    }

    /// @notice Checkpoints an observed attributable asset balance.
    /// @return changed False for a duplicate observation, true for a newly observed loss.
    function observeAttributableAssets(uint256 observedAssets) external returns (bool changed) {
        if (!deficitEntered) revert DeficitNotEntered();
        _requireAggregateAmount(observedAssets);

        uint256 accountedBefore = accountedAssets;
        if (observedAssets == accountedBefore) return false;
        if (observedAssets > accountedBefore) revert InvalidLossCheckpoint();

        uint256 positionLength = _positionIds.length;
        Rational[] memory positionFundedAfter = new Rational[](positionLength);
        Rational[] memory positionGapAfter = new Rational[](positionLength);
        for (uint256 i; i < positionLength; ++i) {
            Position storage position = _positions[_positionIds[i]];
            if (position.replaced) continue;

            Rational memory positionFundedBefore = position.fundedEntitlement;
            positionFundedAfter[i] =
                _mulRatio(positionFundedBefore, observedAssets, accountedBefore);
            positionGapAfter[i] =
                _add(position.unfundedGap, _sub(positionFundedBefore, positionFundedAfter[i]));
        }
        _preflightFundedAndGapTotals(
            positionFundedAfter,
            positionGapAfter,
            observedAssets,
            fixedNominalUnits - aggregatePaidAssets - observedAssets
        );

        for (uint256 i; i < positionLength; ++i) {
            Position storage position = _positions[_positionIds[i]];
            if (position.replaced) continue;
            position.fundedEntitlement = positionFundedAfter[i];
            position.unfundedGap = positionGapAfter[i];
        }

        accountedAssets = observedAssets;
        return true;
    }

    function depositRecovery(uint256 amount) external {
        if (!deficitEntered) revert DeficitNotEntered();
        if (amount == 0) revert InvalidRecoveryAmount();
        _requireAggregateAmount(amount);

        uint256 aggregateGapBefore = aggregateGap();
        if (amount > aggregateGapBefore) revert RecoveryExceedsGap();
        uint256 aggregateGapAfter = aggregateGapBefore - amount;
        uint256 accountedAfter = _checkedAdd(accountedAssets, amount);

        uint256 positionLength = _positionIds.length;
        Rational[] memory positionFundedAfter = new Rational[](positionLength);
        Rational[] memory positionGapAfter = new Rational[](positionLength);
        for (uint256 i; i < positionLength; ++i) {
            Position storage position = _positions[_positionIds[i]];
            if (position.replaced) continue;

            Rational memory positionGapBefore = position.unfundedGap;
            positionGapAfter[i] =
                _mulRatio(positionGapBefore, aggregateGapAfter, aggregateGapBefore);
            positionFundedAfter[i] =
                _add(position.fundedEntitlement, _sub(positionGapBefore, positionGapAfter[i]));
        }
        _preflightFundedAndGapTotals(
            positionFundedAfter, positionGapAfter, accountedAfter, aggregateGapAfter
        );

        for (uint256 i; i < positionLength; ++i) {
            Position storage position = _positions[_positionIds[i]];
            if (position.replaced) continue;
            position.unfundedGap = positionGapAfter[i];
            position.fundedEntitlement = positionFundedAfter[i];
        }

        accountedAssets = accountedAfter;
    }

    function claim(bytes32 positionId, uint256 maxAmount) external returns (uint256 paidAmount) {
        if (!deficitEntered) revert DeficitNotEntered();
        if (maxAmount == 0) revert InvalidClaimCap();
        if (maxAmount != type(uint256).max) _requireAggregateAmount(maxAmount);

        Position storage position = _position(positionId);
        if (position.consumed) return 0;
        if (position.active || position.replaced) revert PositionNotClaimable();

        uint256 available = _floor(position.fundedEntitlement);
        paidAmount = maxAmount < available ? maxAmount : available;
        if (paidAmount == 0) return 0;

        Rational memory payment = _fromUint(paidAmount);
        Rational memory paidAfter = _add(position.paidAssets, payment);
        Rational memory fundedAfter = _sub(position.fundedEntitlement, payment);
        uint256 accountedAfter = accountedAssets - paidAmount;
        uint256 aggregatePaidAfter = _checkedAdd(aggregatePaidAssets, paidAmount);
        _preflightClaimTotals(
            positionId, paidAfter, fundedAfter, aggregatePaidAfter, accountedAfter
        );

        position.paidAssets = paidAfter;
        position.fundedEntitlement = fundedAfter;
        accountedAssets = accountedAfter;
        aggregatePaidAssets = aggregatePaidAfter;

        if (_isZero(fundedAfter) && _isZero(position.unfundedGap)) {
            position.consumed = true;
        }
    }

    function splitActivePosition(
        bytes32 parentId,
        bytes32[] calldata childIds,
        uint256[] calldata childNominalUnits
    ) external {
        if (!deficitEntered) revert DeficitNotEntered();

        Position storage parent = _position(parentId);
        if (!parent.active || parent.consumed || parent.replaced || !_isZero(parent.paidAssets)) {
            revert PositionNotSplittable();
        }

        uint256 childCount = childIds.length;
        if (childCount == 0 || childCount > 3 || childCount != childNominalUnits.length) {
            revert InvalidSplit();
        }
        if (_positionIds.length + childCount > MAX_POSITIONS) revert TooManyPositions();

        uint256 parentNominal = _integerValue(parent.nominalUnits);
        uint256 totalChildNominal;
        for (uint256 i; i < childCount; ++i) {
            bytes32 childId = childIds[i];
            uint256 childNominal = childNominalUnits[i];
            if (childId == bytes32(0) || childNominal == 0) revert InvalidSplit();
            _requireAggregateAmount(childNominal);
            if (_positions[childId].exists) revert DuplicatePosition();
            for (uint256 j; j < i; ++j) {
                if (childIds[j] == childId) revert DuplicatePosition();
            }

            totalChildNominal = _checkedAdd(totalChildNominal, childNominal);
            if (totalChildNominal > parentNominal) revert InvalidSplit();
        }
        if (totalChildNominal != parentNominal) revert InvalidSplit();

        Rational memory parentFundedBefore = parent.fundedEntitlement;
        Rational memory parentGapBefore = parent.unfundedGap;
        Rational[] memory childFunded = new Rational[](childCount);
        Rational[] memory childGap = new Rational[](childCount);
        for (uint256 i; i < childCount; ++i) {
            uint256 childNominal = childNominalUnits[i];
            childFunded[i] = _mulRatio(parentFundedBefore, childNominal, parentNominal);
            childGap[i] = _mulRatio(parentGapBefore, childNominal, parentNominal);
        }
        _preflightSplitTotals(parentId, childNominalUnits, childFunded, childGap);

        parent.active = false;
        parent.consumed = true;
        parent.replaced = true;

        for (uint256 i; i < childCount; ++i) {
            uint256 childNominal = childNominalUnits[i];
            bytes32 childId = childIds[i];
            _positions[childId] = Position({
                nominalUnits: _fromUint(childNominal),
                paidAssets: _zero(),
                fundedEntitlement: childFunded[i],
                unfundedGap: childGap[i],
                active: false,
                consumed: false,
                replaced: false,
                exists: true
            });
            _positionIds.push(childId);
        }
    }

    function getPosition(bytes32 positionId) external view returns (Position memory) {
        return _position(positionId);
    }

    function positionCount() external view returns (uint256) {
        return _positionIds.length;
    }

    function positionIdAt(uint256 index) external view returns (bytes32) {
        return _positionIds[index];
    }

    function aggregateGap() public view returns (uint256) {
        if (!deficitEntered) return 0;
        uint256 paidAndFunded = _checkedAdd(aggregatePaidAssets, accountedAssets);
        if (paidAndFunded > fixedNominalUnits) revert InvariantViolation(20);
        return fixedNominalUnits - paidAndFunded;
    }

    function aggregateComponents()
        external
        view
        returns (
            Rational memory nominal,
            Rational memory paid,
            Rational memory funded,
            Rational memory gap
        )
    {
        return _aggregateComponents();
    }

    function checkInvariants() external view returns (bool) {
        return _invariantCode() == 0;
    }

    function assertInvariants() external view {
        uint8 code = _invariantCode();
        if (code != 0) revert InvariantViolation(code);
    }

    function floorOf(Rational calldata value) external pure returns (uint256) {
        if (!_isValidRational(value)) revert RationalOutOfRange();
        return _floor(value);
    }

    function _aggregateComponents()
        internal
        view
        returns (
            Rational memory nominal,
            Rational memory paid,
            Rational memory funded,
            Rational memory gap
        )
    {
        nominal = _zero();
        paid = _zero();
        funded = _zero();
        gap = _zero();

        for (uint256 i; i < _positionIds.length; ++i) {
            Position storage position = _positions[_positionIds[i]];
            if (position.replaced) continue;
            nominal = _add(nominal, position.nominalUnits);
            paid = _add(paid, position.paidAssets);
            funded = _add(funded, position.fundedEntitlement);
            gap = _add(gap, position.unfundedGap);
        }
    }

    function _preflightFundedAndGapTotals(
        Rational[] memory positionFundedAfter,
        Rational[] memory positionGapAfter,
        uint256 expectedFunded,
        uint256 expectedGap
    ) internal view {
        Rational memory totalFunded = _zero();
        Rational memory totalGap = _zero();
        for (uint256 i; i < _positionIds.length; ++i) {
            Position storage position = _positions[_positionIds[i]];
            if (position.replaced) continue;
            _preflightPositionComponents(
                position.nominalUnits,
                position.paidAssets,
                positionFundedAfter[i],
                positionGapAfter[i]
            );
            totalFunded = _add(totalFunded, positionFundedAfter[i]);
            totalGap = _add(totalGap, positionGapAfter[i]);
        }
        if (!_equal(totalFunded, _fromUint(expectedFunded))) revert InvariantViolation(21);
        if (!_equal(totalGap, _fromUint(expectedGap))) revert InvariantViolation(22);
    }

    function _preflightClaimTotals(
        bytes32 claimedPositionId,
        Rational memory claimedPaidAfter,
        Rational memory claimedFundedAfter,
        uint256 expectedPaid,
        uint256 expectedFunded
    ) internal view {
        Rational memory totalPaid = _zero();
        Rational memory totalFunded = _zero();
        for (uint256 i; i < _positionIds.length; ++i) {
            bytes32 positionId = _positionIds[i];
            Position storage position = _positions[positionId];
            if (position.replaced) continue;
            Rational memory positionPaidAfter =
                positionId == claimedPositionId ? claimedPaidAfter : position.paidAssets;
            Rational memory positionFundedAfter =
                positionId == claimedPositionId ? claimedFundedAfter : position.fundedEntitlement;
            _preflightPositionComponents(
                position.nominalUnits, positionPaidAfter, positionFundedAfter, position.unfundedGap
            );
            totalPaid = _add(totalPaid, positionPaidAfter);
            totalFunded = _add(totalFunded, positionFundedAfter);
        }
        if (!_equal(totalPaid, _fromUint(expectedPaid))) revert InvariantViolation(23);
        if (!_equal(totalFunded, _fromUint(expectedFunded))) revert InvariantViolation(24);
    }

    function _preflightSplitTotals(
        bytes32 parentId,
        uint256[] calldata childNominalUnits,
        Rational[] memory childFunded,
        Rational[] memory childGap
    ) internal view {
        Rational memory totalNominal = _zero();
        Rational memory totalPaid = _zero();
        Rational memory totalFunded = _zero();
        Rational memory totalGap = _zero();
        for (uint256 i; i < _positionIds.length; ++i) {
            bytes32 positionId = _positionIds[i];
            Position storage position = _positions[positionId];
            if (position.replaced || positionId == parentId) continue;
            totalNominal = _add(totalNominal, position.nominalUnits);
            totalPaid = _add(totalPaid, position.paidAssets);
            totalFunded = _add(totalFunded, position.fundedEntitlement);
            totalGap = _add(totalGap, position.unfundedGap);
        }
        for (uint256 i; i < childNominalUnits.length; ++i) {
            Rational memory childNominal = _fromUint(childNominalUnits[i]);
            _preflightPositionComponents(childNominal, _zero(), childFunded[i], childGap[i]);
            totalNominal = _add(totalNominal, childNominal);
            totalFunded = _add(totalFunded, childFunded[i]);
            totalGap = _add(totalGap, childGap[i]);
        }

        if (!_equal(totalNominal, _fromUint(aggregateNominalUnits))) {
            revert InvariantViolation(25);
        }
        if (!_equal(totalPaid, _fromUint(aggregatePaidAssets))) revert InvariantViolation(26);
        if (!_equal(totalFunded, _fromUint(accountedAssets))) revert InvariantViolation(27);
        if (!_equal(totalGap, _fromUint(aggregateGap()))) revert InvariantViolation(28);
    }

    function _preflightPositionComponents(
        Rational memory nominal,
        Rational memory paid,
        Rational memory funded,
        Rational memory gap
    ) internal pure {
        if (!_equal(_add(_add(paid, funded), gap), nominal)) {
            revert InvariantViolation(29);
        }
    }

    function _invariantCode() internal view returns (uint8) {
        for (uint256 i; i < _positionIds.length; ++i) {
            Position storage position = _positions[_positionIds[i]];
            uint8 positionInvariantCode = _positionInvariantCode(position);
            if (positionInvariantCode != 0) return positionInvariantCode;
        }

        (
            Rational memory nominal,
            Rational memory paid,
            Rational memory funded,
            Rational memory gap
        ) = _aggregateComponents();
        if (!_equal(nominal, _fromUint(aggregateNominalUnits))) return 7;
        if (!_equal(paid, _fromUint(aggregatePaidAssets))) return 8;
        if (!_equal(funded, _fromUint(accountedAssets))) return 9;

        if (!deficitEntered) {
            if (
                fixedNominalUnits != 0 || aggregatePaidAssets != 0 || !_isZero(gap)
                    || accountedAssets != aggregateNominalUnits || !_equal(funded, nominal)
            ) {
                return 10;
            }
            return 0;
        }

        if (
            fixedNominalUnits != aggregateNominalUnits
                || !_equal(nominal, _fromUint(fixedNominalUnits))
        ) {
            return 11;
        }
        if (!_equal(gap, _fromUint(aggregateGap()))) return 12;

        Rational memory totalRights = _add(_add(paid, funded), gap);
        if (!_equal(totalRights, _fromUint(fixedNominalUnits))) return 13;
        return 0;
    }

    function _positionInvariantCode(Position storage position) internal view returns (uint8) {
        if (
            !position.exists || !_isValidRational(position.nominalUnits)
                || !_isValidRational(position.paidAssets)
                || !_isValidRational(position.fundedEntitlement)
                || !_isValidRational(position.unfundedGap)
        ) {
            return 1;
        }

        Rational memory components =
            _add(_add(position.paidAssets, position.fundedEntitlement), position.unfundedGap);
        if (!_equal(position.nominalUnits, components)) return 2;
        if (!_lessThanOrEqual(position.paidAssets, position.nominalUnits)) return 3;
        if (
            position.active
                && (position.consumed || position.replaced || !_isZero(position.paidAssets))
        ) {
            return 4;
        }
        if (position.replaced && (!position.consumed || position.active)) return 5;
        if (
            position.consumed && !position.replaced
                && (!_equal(position.paidAssets, position.nominalUnits)
                    || !_isZero(position.fundedEntitlement)
                    || !_isZero(position.unfundedGap))
        ) {
            return 6;
        }
        return 0;
    }

    function _position(bytes32 positionId) internal view returns (Position storage position) {
        position = _positions[positionId];
        if (!position.exists) revert PositionNotFound();
    }

    function _requireAggregateAmount(uint256 amount) internal pure {
        if (amount > MAX_AGGREGATE_AMOUNT) revert AmountOutOfRange();
    }

    function _fromUint(uint256 value) internal pure returns (Rational memory) {
        if (value > MAX_RATIONAL_PART) revert RationalOutOfRange();
        return Rational({numerator: value, denominator: 1});
    }

    function _zero() internal pure returns (Rational memory) {
        return Rational({numerator: 0, denominator: 1});
    }

    function _add(Rational memory left, Rational memory right)
        internal
        pure
        returns (Rational memory)
    {
        uint256 common = _gcd(left.denominator, right.denominator);
        uint256 leftScale = right.denominator / common;
        uint256 rightScale = left.denominator / common;
        uint256 numerator = _checkedAdd(
            _checkedMul(left.numerator, leftScale), _checkedMul(right.numerator, rightScale)
        );
        uint256 denominator = _checkedMul(left.denominator, leftScale);
        return _normalize(numerator, denominator);
    }

    function _sub(Rational memory left, Rational memory right)
        internal
        pure
        returns (Rational memory)
    {
        uint256 common = _gcd(left.denominator, right.denominator);
        uint256 leftScale = right.denominator / common;
        uint256 rightScale = left.denominator / common;
        uint256 leftNumerator = _checkedMul(left.numerator, leftScale);
        uint256 rightNumerator = _checkedMul(right.numerator, rightScale);
        if (rightNumerator > leftNumerator) revert RationalUnderflow();
        return _normalize(leftNumerator - rightNumerator, _checkedMul(left.denominator, leftScale));
    }

    function _mulRatio(Rational memory value, uint256 multiplier, uint256 divisor)
        internal
        pure
        returns (Rational memory)
    {
        if (divisor == 0) revert RationalUnderflow();
        if (value.numerator == 0 || multiplier == 0) return _zero();

        uint256 numeratorDivisorGcd = _gcd(value.numerator, divisor);
        uint256 numerator = value.numerator / numeratorDivisorGcd;
        uint256 remainingDivisor = divisor / numeratorDivisorGcd;

        uint256 multiplierDenominatorGcd = _gcd(multiplier, value.denominator);
        uint256 remainingMultiplier = multiplier / multiplierDenominatorGcd;
        uint256 denominator = value.denominator / multiplierDenominatorGcd;

        return _normalize(
            _checkedMul(numerator, remainingMultiplier), _checkedMul(denominator, remainingDivisor)
        );
    }

    function _normalize(uint256 numerator, uint256 denominator)
        internal
        pure
        returns (Rational memory)
    {
        if (denominator == 0) revert RationalUnderflow();
        if (numerator == 0) return _zero();

        uint256 divisor = _gcd(numerator, denominator);
        numerator /= divisor;
        denominator /= divisor;
        if (numerator > MAX_RATIONAL_PART || denominator > MAX_RATIONAL_PART) {
            revert OracleDomainExceeded();
        }
        return Rational({numerator: numerator, denominator: denominator});
    }

    function _lessThanOrEqual(Rational memory left, Rational memory right)
        internal
        pure
        returns (bool)
    {
        return _checkedMul(left.numerator, right.denominator)
            <= _checkedMul(right.numerator, left.denominator);
    }

    function _equal(Rational memory left, Rational memory right) internal pure returns (bool) {
        return left.numerator == right.numerator && left.denominator == right.denominator;
    }

    function _isZero(Rational memory value) internal pure returns (bool) {
        return value.numerator == 0;
    }

    function _integerValue(Rational memory value) internal pure returns (uint256) {
        if (value.denominator != 1) revert RationalOutOfRange();
        return value.numerator;
    }

    function _floor(Rational memory value) internal pure returns (uint256) {
        return value.numerator / value.denominator;
    }

    function _isValidRational(Rational memory value) internal pure returns (bool) {
        if (
            value.denominator == 0 || value.numerator > MAX_RATIONAL_PART
                || value.denominator > MAX_RATIONAL_PART
        ) {
            return false;
        }
        if (value.numerator == 0) return value.denominator == 1;
        return _gcd(value.numerator, value.denominator) == 1;
    }

    function _checkedAdd(uint256 left, uint256 right) internal pure returns (uint256 result) {
        if (right > type(uint256).max - left) revert RationalOverflow();
        return left + right;
    }

    function _checkedMul(uint256 left, uint256 right) internal pure returns (uint256 result) {
        if (left != 0 && right > type(uint256).max / left) revert RationalOverflow();
        return left * right;
    }

    function _gcd(uint256 left, uint256 right) internal pure returns (uint256) {
        while (right != 0) {
            uint256 remainder = left % right;
            left = right;
            right = remainder;
        }
        return left;
    }
}
