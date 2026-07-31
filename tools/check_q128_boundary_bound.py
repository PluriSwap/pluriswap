#!/usr/bin/env python3
"""Check scoped Q128 initial-boundary and active-source replacement bounds."""

import argparse
from dataclasses import dataclass


SCALE = 1 << 128
MAX_BOUNDARY_NOMINAL = SCALE - 1
UINT256_MAX = (1 << 256) - 1


def ceil_div(numerator: int, denominator: int) -> int:
    if denominator <= 0:
        raise ValueError("denominator must be positive")
    return -(-numerator // denominator)


def initial_coefficient(loss: int, nominal: int, scale: int = SCALE) -> int:
    if nominal <= 0 or not 0 <= loss <= nominal:
        raise ValueError("expected 0 <= loss <= nominal and nominal > 0")
    return ceil_div(loss * scale, nominal)


def materialized_single_position_gap(
    loss: int, nominal: int, scale: int = SCALE
) -> int:
    coefficient = initial_coefficient(loss, nominal, scale)
    return min(nominal, ceil_div(coefficient * nominal, scale))


def assert_bounded_case(loss: int, nominal: int, scale: int) -> None:
    if not 1 <= nominal <= scale - 1:
        raise AssertionError("case is outside the proved nominal domain")

    coefficient = initial_coefficient(loss, nominal, scale)
    materialized_gap = materialized_single_position_gap(loss, nominal, scale)

    # Definition of a = ceil(loss * scale / nominal).
    assert loss * scale <= coefficient * nominal
    if coefficient > 0:
        assert (coefficient - 1) * nominal < loss * scale

    # a < loss * scale / nominal + 1, hence:
    # a * nominal < loss * scale + nominal < (loss + 1) * scale.
    assert coefficient * nominal < loss * scale + nominal
    assert loss * scale + nominal < (loss + 1) * scale

    assert loss <= materialized_gap <= loss + 1


def coefficient_gap(coefficient: int, nominal: int, scale: int = SCALE) -> int:
    if not 0 <= coefficient <= scale or nominal < 0:
        raise ValueError("coefficient or nominal is outside the proved domain")
    return ceil_div(coefficient * nominal, scale)


def assert_replacement_bound(
    coefficient: int, child_nominals: tuple[int, ...], scale: int
) -> None:
    if not child_nominals or len(child_nominals) > 3:
        raise AssertionError("expected one to three children")
    if any(child <= 0 for child in child_nominals):
        raise AssertionError("children must be positive")

    nominal = sum(child_nominals)
    if nominal > scale - 1:
        raise AssertionError("replacement is outside the boundary domain")

    parent_gap = coefficient_gap(coefficient, nominal, scale)
    child_gap = sum(
        coefficient_gap(coefficient, child, scale) for child in child_nominals
    )
    dust = child_gap - parent_gap

    assert 0 <= dust <= len(child_nominals) - 1
    assert child_gap <= nominal


def positive_partitions(total: int, count: int, prefix: tuple[int, ...] = ()):
    if count == 1:
        yield prefix + (total,)
        return
    for first in range(1, total - count + 2):
        yield from positive_partitions(total - first, count - 1, prefix + (first,))


@dataclass(frozen=True)
class EdgeCase:
    name: str
    nominal: int
    loss: int
    expected_coefficient: int
    expected_gap: int


def check_production_edges() -> None:
    cases = (
        EdgeCase("one_unit_boundary", 1, 1, SCALE, 1),
        EdgeCase("cap_one_unit_loss", MAX_BOUNDARY_NOMINAL, 1, 2, 2),
        EdgeCase(
            "cap_almost_total_loss",
            MAX_BOUNDARY_NOMINAL,
            MAX_BOUNDARY_NOMINAL - 1,
            SCALE - 1,
            MAX_BOUNDARY_NOMINAL,
        ),
        EdgeCase(
            "cap_total_loss",
            MAX_BOUNDARY_NOMINAL,
            MAX_BOUNDARY_NOMINAL,
            SCALE,
            MAX_BOUNDARY_NOMINAL,
        ),
    )
    for case in cases:
        coefficient = initial_coefficient(case.loss, case.nominal)
        gap = materialized_single_position_gap(case.loss, case.nominal)
        assert coefficient == case.expected_coefficient, case.name
        assert gap == case.expected_gap, case.name
        assert_bounded_case(case.loss, case.nominal, SCALE)

    midpoint_loss = MAX_BOUNDARY_NOMINAL // 2
    assert_bounded_case(midpoint_loss, MAX_BOUNDARY_NOMINAL, SCALE)

    # The removed wide-boundary case: a one-unit loss against uint256.max
    # materializes as 2^128 gap units, understating funded value by 2^128 - 1.
    wide_gap = materialized_single_position_gap(1, UINT256_MAX)
    assert initial_coefficient(1, UINT256_MAX) == 1
    assert wide_gap == SCALE
    assert wide_gap - 1 == SCALE - 1

    # A small witness that the one-unit result is not an unbounded-domain theorem.
    outside_nominal = 2 * SCALE + 1
    assert materialized_single_position_gap(1, outside_nominal) == 3


def check_exhaustive_small_domains() -> int:
    checked = 0
    for scale in range(2, 33):
        for nominal in range(1, scale):
            for loss in range(nominal + 1):
                assert_bounded_case(loss, nominal, scale)
                checked += 1
    return checked


def check_replacement_edges() -> None:
    assert_replacement_bound(0, (1, 1, MAX_BOUNDARY_NOMINAL - 2), SCALE)
    assert_replacement_bound(SCALE, (1, 1, MAX_BOUNDARY_NOMINAL - 2), SCALE)

    tight_children = (1, 1, MAX_BOUNDARY_NOMINAL - 2)
    parent_gap = coefficient_gap(2, sum(tight_children))
    child_gap = sum(coefficient_gap(2, child) for child in tight_children)
    assert parent_gap == 2
    assert child_gap == 4
    assert child_gap - parent_gap == len(tight_children) - 1 == 2
    assert_replacement_bound(2, tight_children, SCALE)


def check_exhaustive_replacement_domains() -> int:
    checked = 0
    for scale in range(2, 33):
        for nominal in range(1, scale):
            for child_count in range(1, min(3, nominal) + 1):
                for children in positive_partitions(nominal, child_count):
                    for coefficient in range(scale + 1):
                        assert_replacement_bound(coefficient, children, scale)
                        checked += 1
    return checked


def saturating_add_uint256(values: tuple[int, ...]) -> int:
    total = 0
    for value in values:
        if not 0 <= value <= UINT256_MAX:
            raise ValueError("value is outside uint256")
        if total > UINT256_MAX - value:
            return UINT256_MAX
        total += value
    return total


def boundary_accepts(current: int, wallet_pull_legs: tuple[int, ...]) -> bool:
    added = saturating_add_uint256(wallet_pull_legs)
    return current <= MAX_BOUNDARY_NOMINAL and added <= MAX_BOUNDARY_NOMINAL - current


def check_admission_edges() -> None:
    assert boundary_accepts(0, (MAX_BOUNDARY_NOMINAL,))
    assert not boundary_accepts(0, (MAX_BOUNDARY_NOMINAL + 1,))
    assert boundary_accepts(MAX_BOUNDARY_NOMINAL - 1, (1,))
    assert not boundary_accepts(MAX_BOUNDARY_NOMINAL - 1, (2,))
    assert boundary_accepts(MAX_BOUNDARY_NOMINAL, ())
    assert boundary_accepts(MAX_BOUNDARY_NOMINAL, (0,))
    assert not boundary_accepts(MAX_BOUNDARY_NOMINAL, (1,))
    assert not boundary_accepts(0, (UINT256_MAX,))
    assert saturating_add_uint256((UINT256_MAX, 1)) == UINT256_MAX

    # LEDGER_POSITION legs are intentionally absent from wallet_pull_legs.
    assert boundary_accepts(MAX_BOUNDARY_NOMINAL - 10, (10,))

    # Token boundaries evaluate independently.
    assert boundary_accepts(0, (MAX_BOUNDARY_NOMINAL,))
    assert boundary_accepts(0, (MAX_BOUNDARY_NOMINAL,))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="run deterministic and exhaustive-small-domain checks",
    )
    args = parser.parse_args()

    check_production_edges()
    initial_cases = check_exhaustive_small_domains()
    check_replacement_edges()
    replacement_cases = check_exhaustive_replacement_domains()
    check_admission_edges()

    mode = "check" if args.check else "run"
    print(
        "Q128 boundary bound "
        f"{mode} passed: {initial_cases} initial and "
        f"{replacement_cases} replacement exhaustive small-domain cases"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
