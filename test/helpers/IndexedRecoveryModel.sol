// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test-only affine-index model for irreversible deficit accounting.
/// @dev State transitions are O(1) in position/checkpoint count, except terminal splits which are
/// bounded to at most three children. The global affine index has an independent uint120 bound;
/// position history and lazily materialized components use checked uint256 rational arithmetic.
/// Differential vectors prove exact equivalence where both this model and ReferenceRecoveryModel
/// accept, while domain-distinction vectors exercise values outside the iterative oracle's
/// artificial per-position uint120 bound.
contract IndexedRecoveryModel {
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

    struct IndexedPosition {
        uint256 nominalUnits;
        uint256 paidAssets;
        Rational history;
        uint256 generation;
        Rational replacedFunded;
        Rational replacedGap;
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

    mapping(bytes32 positionId => IndexedPosition position) private _positions;
    bytes32[] private _positionIds;

    // For unpaid units u, gap is a*u + s*h. A generation reset makes stale h equal zero.
    Rational private _gapCoefficient;
    Rational private _historyScale;
    uint256 public generation;

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

        _positions[positionId] = IndexedPosition({
            nominalUnits: nominalUnits,
            paidAssets: 0,
            history: _zero(),
            generation: 0,
            replacedFunded: _zero(),
            replacedGap: _zero(),
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
        Rational memory coefficient =
            _normalize(nominalAtEntry - attributableAssets, nominalAtEntry);
        Rational memory scale = _fromUint(1);
        _requireBoundaryRational(coefficient);
        _requireBoundaryRational(scale);

        fixedNominalUnits = nominalAtEntry;
        accountedAssets = attributableAssets;
        generation = 1;
        _gapCoefficient = coefficient;
        _historyScale = scale;
        deficitEntered = true;
    }

    /// @notice Checkpoints an observed attributable asset balance.
    /// @return changed False for a duplicate observation, true for a newly observed loss.
    function observeAttributableAssets(uint256 observedAssets) external returns (bool changed) {
        if (!deficitEntered) revert DeficitNotEntered();
        _requireAggregateAmount(observedAssets);

        uint256 fundedBefore = accountedAssets;
        if (observedAssets == fundedBefore) return false;
        if (observedAssets > fundedBefore) revert InvalidLossCheckpoint();

        if (observedAssets == 0) {
            _resetBoundary(_fromUint(1));
        } else {
            Rational memory lossRatio = _normalize(observedAssets, fundedBefore);
            Rational memory retainedGap = _mul(lossRatio, _sub(_fromUint(1), _gapCoefficient));
            Rational memory coefficientAfter = _sub(_fromUint(1), retainedGap);
            Rational memory scaleAfter = _mul(lossRatio, _historyScale);
            _requireBoundaryRational(coefficientAfter);
            _requireBoundaryRational(scaleAfter);

            _gapCoefficient = coefficientAfter;
            _historyScale = scaleAfter;
        }
        accountedAssets = observedAssets;
        return true;
    }

    function depositRecovery(uint256 amount) external {
        if (!deficitEntered) revert DeficitNotEntered();
        if (amount == 0) revert InvalidRecoveryAmount();
        _requireAggregateAmount(amount);

        uint256 gapBefore = aggregateGap();
        if (amount > gapBefore) revert RecoveryExceedsGap();
        uint256 gapAfter = gapBefore - amount;
        uint256 accountedAfter = _checkedAdd(accountedAssets, amount);

        if (gapAfter == 0) {
            _resetBoundary(_zero());
        } else {
            Rational memory retainedGap = _normalize(gapAfter, gapBefore);
            Rational memory coefficientAfter = _mul(retainedGap, _gapCoefficient);
            Rational memory scaleAfter = _mul(retainedGap, _historyScale);
            _requireBoundaryRational(coefficientAfter);
            _requireBoundaryRational(scaleAfter);

            _gapCoefficient = coefficientAfter;
            _historyScale = scaleAfter;
        }
        accountedAssets = accountedAfter;
    }

    function claim(bytes32 positionId, uint256 maxAmount) external returns (uint256 paidAmount) {
        if (!deficitEntered) revert DeficitNotEntered();
        if (maxAmount == 0) revert InvalidClaimCap();
        if (maxAmount != type(uint256).max) _requireAggregateAmount(maxAmount);

        IndexedPosition storage position = _position(positionId);
        if (position.consumed) return 0;
        if (position.active || position.replaced) revert PositionNotClaimable();

        (Rational memory fundedBefore, Rational memory gapBefore) = _currentComponents(position);
        uint256 available = _floor(fundedBefore);
        paidAmount = maxAmount < available ? maxAmount : available;
        if (paidAmount == 0) return 0;

        Rational memory history = _currentHistory(position);
        Rational memory coefficientPerScale = _div(_gapCoefficient, _historyScale);
        Rational memory historyAfter = _add(history, _mulUint(coefficientPerScale, paidAmount));
        uint256 paidAfter = _checkedAdd(position.paidAssets, paidAmount);
        uint256 accountedAfter = accountedAssets - paidAmount;
        uint256 aggregatePaidAfter = _checkedAdd(aggregatePaidAssets, paidAmount);
        Rational memory fundedAfter = _sub(fundedBefore, _fromUint(paidAmount));

        position.paidAssets = paidAfter;
        position.history = historyAfter;
        position.generation = generation;
        accountedAssets = accountedAfter;
        aggregatePaidAssets = aggregatePaidAfter;
        if (_isZero(fundedAfter) && _isZero(gapBefore)) position.consumed = true;
    }

    function splitActivePosition(
        bytes32 parentId,
        bytes32[] calldata childIds,
        uint256[] calldata childNominalUnits
    ) external {
        if (!deficitEntered) revert DeficitNotEntered();

        IndexedPosition storage parent = _position(parentId);
        if (!parent.active || parent.consumed || parent.replaced || parent.paidAssets != 0) {
            revert PositionNotSplittable();
        }

        uint256 childCount = childIds.length;
        if (childCount == 0 || childCount > 3 || childCount != childNominalUnits.length) {
            revert InvalidSplit();
        }
        if (_positionIds.length + childCount > MAX_POSITIONS) revert TooManyPositions();

        uint256 parentNominal = parent.nominalUnits;
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

        Rational memory parentHistory = _currentHistory(parent);
        (Rational memory parentFunded, Rational memory parentGap) = _currentComponents(parent);
        Rational[] memory childHistories = new Rational[](childCount);
        for (uint256 i; i < childCount; ++i) {
            childHistories[i] = _mulRatio(parentHistory, childNominalUnits[i], parentNominal);
        }

        parent.active = false;
        parent.consumed = true;
        parent.replaced = true;
        parent.replacedFunded = parentFunded;
        parent.replacedGap = parentGap;

        for (uint256 i; i < childCount; ++i) {
            bytes32 childId = childIds[i];
            _positions[childId] = IndexedPosition({
                nominalUnits: childNominalUnits[i],
                paidAssets: 0,
                history: childHistories[i],
                generation: generation,
                replacedFunded: _zero(),
                replacedGap: _zero(),
                active: false,
                consumed: false,
                replaced: false,
                exists: true
            });
            _positionIds.push(childId);
        }
    }

    function getPosition(bytes32 positionId) external view returns (Position memory) {
        IndexedPosition storage position = _position(positionId);
        (Rational memory funded, Rational memory gap) = _currentComponents(position);
        return Position({
            nominalUnits: _fromUint(position.nominalUnits),
            paidAssets: _fromUint(position.paidAssets),
            fundedEntitlement: funded,
            unfundedGap: gap,
            active: position.active,
            consumed: position.consumed,
            replaced: position.replaced,
            exists: position.exists
        });
    }

    function positionCount() external view returns (uint256) {
        return _positionIds.length;
    }

    function positionIdAt(uint256 index) external view returns (bytes32) {
        return _positionIds[index];
    }

    function gapCoefficient() external view returns (Rational memory) {
        return _gapCoefficient;
    }

    function historyScale() external view returns (Rational memory) {
        return _historyScale;
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

    function _resetBoundary(Rational memory coefficient) internal {
        uint256 nextGeneration = _checkedAdd(generation, 1);
        Rational memory scale = _fromUint(1);
        _requireBoundaryRational(coefficient);
        _requireBoundaryRational(scale);

        generation = nextGeneration;
        _gapCoefficient = coefficient;
        _historyScale = scale;
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
            IndexedPosition storage position = _positions[_positionIds[i]];
            if (position.replaced) continue;
            (Rational memory positionFunded, Rational memory positionGap) =
                _currentComponents(position);
            nominal = _add(nominal, _fromUint(position.nominalUnits));
            paid = _add(paid, _fromUint(position.paidAssets));
            funded = _add(funded, positionFunded);
            gap = _add(gap, positionGap);
        }
    }

    function _invariantCode() internal view returns (uint8) {
        if (deficitEntered) {
            if (
                !_isValidBoundaryRational(_gapCoefficient)
                    || !_isValidBoundaryRational(_historyScale) || _historyScale.numerator == 0
            ) return 14;
        }

        for (uint256 i; i < _positionIds.length; ++i) {
            IndexedPosition storage position = _positions[_positionIds[i]];
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
            ) return 10;
            return 0;
        }
        if (fixedNominalUnits != aggregateNominalUnits) return 11;
        if (!_equal(gap, _fromUint(aggregateGap()))) return 12;
        if (!_equal(_add(_add(paid, funded), gap), _fromUint(fixedNominalUnits))) return 13;
        return 0;
    }

    function _positionInvariantCode(IndexedPosition storage position)
        internal
        view
        returns (uint8)
    {
        if (
            !position.exists || position.nominalUnits == 0
                || position.nominalUnits > MAX_AGGREGATE_AMOUNT
                || position.paidAssets > position.nominalUnits
                || !_isValidRational(position.history) || !_isValidRational(position.replacedFunded)
                || !_isValidRational(position.replacedGap)
        ) return 1;

        (Rational memory funded, Rational memory gap) = _currentComponents(position);
        Rational memory components = _add(_add(_fromUint(position.paidAssets), funded), gap);
        if (!_equal(_fromUint(position.nominalUnits), components)) return 2;
        if (position.active && (position.consumed || position.replaced || position.paidAssets != 0))
        {
            return 4;
        }
        if (position.replaced && (!position.consumed || position.active)) return 5;
        if (
            position.consumed && !position.replaced
                && (position.paidAssets != position.nominalUnits
                    || !_isZero(funded)
                    || !_isZero(gap))
        ) return 6;
        return 0;
    }

    function _currentComponents(IndexedPosition storage position)
        internal
        view
        returns (Rational memory funded, Rational memory gap)
    {
        if (!deficitEntered) return (_fromUint(position.nominalUnits), _zero());
        if (position.replaced) return (position.replacedFunded, position.replacedGap);

        uint256 unpaid = position.nominalUnits - position.paidAssets;
        Rational memory history = _currentHistory(position);
        gap = _add(_mulUint(_gapCoefficient, unpaid), _mul(_historyScale, history));
        funded = _sub(_fromUint(unpaid), gap);
    }

    function _currentHistory(IndexedPosition storage position)
        internal
        view
        returns (Rational memory)
    {
        if (position.generation != generation) return _zero();
        return position.history;
    }

    function _position(bytes32 positionId)
        internal
        view
        returns (IndexedPosition storage position)
    {
        position = _positions[positionId];
        if (!position.exists) revert PositionNotFound();
    }

    function _requireAggregateAmount(uint256 amount) internal pure {
        if (amount > MAX_AGGREGATE_AMOUNT) revert AmountOutOfRange();
    }

    function _fromUint(uint256 value) internal pure returns (Rational memory) {
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

    function _mul(Rational memory left, Rational memory right)
        internal
        pure
        returns (Rational memory)
    {
        if (left.numerator == 0 || right.numerator == 0) return _zero();

        uint256 leftNumeratorGcd = _gcd(left.numerator, right.denominator);
        uint256 rightNumeratorGcd = _gcd(right.numerator, left.denominator);
        return _normalize(
            _checkedMul(left.numerator / leftNumeratorGcd, right.numerator / rightNumeratorGcd),
            _checkedMul(left.denominator / rightNumeratorGcd, right.denominator / leftNumeratorGcd)
        );
    }

    function _div(Rational memory value, Rational memory divisor)
        internal
        pure
        returns (Rational memory)
    {
        if (divisor.numerator == 0) revert RationalUnderflow();
        return
            _mul(value, Rational({numerator: divisor.denominator, denominator: divisor.numerator}));
    }

    function _mulUint(Rational memory value, uint256 multiplier)
        internal
        pure
        returns (Rational memory)
    {
        return _mulRatio(value, multiplier, 1);
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
        return Rational({numerator: numerator, denominator: denominator});
    }

    function _requireBoundaryRational(Rational memory value) internal pure {
        if (value.numerator > MAX_RATIONAL_PART || value.denominator > MAX_RATIONAL_PART) {
            revert OracleDomainExceeded();
        }
    }

    function _equal(Rational memory left, Rational memory right) internal pure returns (bool) {
        return left.numerator == right.numerator && left.denominator == right.denominator;
    }

    function _isZero(Rational memory value) internal pure returns (bool) {
        return value.numerator == 0;
    }

    function _floor(Rational memory value) internal pure returns (uint256) {
        return value.numerator / value.denominator;
    }

    function _isValidRational(Rational memory value) internal pure returns (bool) {
        if (value.denominator == 0) return false;
        if (value.numerator == 0) return value.denominator == 1;
        return _gcd(value.numerator, value.denominator) == 1;
    }

    function _isValidBoundaryRational(Rational memory value) internal pure returns (bool) {
        return _isValidRational(value) && value.numerator <= MAX_RATIONAL_PART
            && value.denominator <= MAX_RATIONAL_PART;
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
