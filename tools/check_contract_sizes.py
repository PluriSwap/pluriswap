#!/usr/bin/env python3
"""Parse `forge build --sizes` output and enforce Mandatory Core budgets."""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import sys
from typing import NamedTuple


EIP_170_RUNTIME_LIMIT = 24_576
EIP_3860_INITCODE_LIMIT = 49_152


class SizeBudget(NamedTuple):
    runtime: int
    initcode: int


# Keep contract-specific published budgets here. A value may be stricter than the
# protocol-wide EIP limits, but never looser.
SIZE_BUDGETS = {
    "Coordinator": SizeBudget(EIP_170_RUNTIME_LIMIT, EIP_3860_INITCODE_LIMIT),
    "CoreDeployer": SizeBudget(EIP_170_RUNTIME_LIMIT, EIP_3860_INITCODE_LIMIT),
    "CoreEscrow": SizeBudget(EIP_170_RUNTIME_LIMIT, EIP_3860_INITCODE_LIMIT),
    "CreditLedger": SizeBudget(EIP_170_RUNTIME_LIMIT, EIP_3860_INITCODE_LIMIT),
}

ANSI_ESCAPE = re.compile(r"\x1b\[[0-9;]*m")
SIZE_ROW = re.compile(
    r"^\|\s*([A-Za-z_][A-Za-z0-9_]*)\s*"
    r"\|\s*([0-9][0-9,]*)\s*"
    r"\|\s*([0-9][0-9,]*)\s*\|"
)


class SizeCheckError(ValueError):
    """Raised when Forge size output violates the checked contract budgets."""


def _parse_number(value: str) -> int:
    return int(value.replace(",", ""))


def check_sizes(output: str) -> dict[str, tuple[int, int]]:
    """Return required sizes or raise when output is incomplete or over budget."""
    found: dict[str, tuple[int, int]] = {}

    for raw_line in output.splitlines():
        line = ANSI_ESCAPE.sub("", raw_line)
        match = SIZE_ROW.match(line)
        if match is None:
            continue

        contract = match.group(1)
        if contract not in SIZE_BUDGETS:
            continue
        if contract in found:
            raise SizeCheckError(f"{contract} size row is duplicate")

        found[contract] = (_parse_number(match.group(2)), _parse_number(match.group(3)))

    missing = sorted(set(SIZE_BUDGETS) - set(found))
    if missing:
        raise SizeCheckError(f"{', '.join(missing)} size row is missing")

    for contract, (runtime, initcode) in found.items():
        budget = SIZE_BUDGETS[contract]
        if runtime >= budget.runtime:
            raise SizeCheckError(
                f"{contract} runtime {runtime} must be below {budget.runtime} bytes"
            )
        if initcode >= budget.initcode:
            raise SizeCheckError(
                f"{contract} initcode {initcode} must be below {budget.initcode} bytes"
            )

    return found


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sizes_file", type=Path, help="captured `forge build --sizes` output")
    args = parser.parse_args(argv)

    try:
        checked = check_sizes(args.sizes_file.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, SizeCheckError) as error:
        print(f"contract size check failed: {error}", file=sys.stderr)
        return 1

    for contract in SIZE_BUDGETS:
        runtime, initcode = checked[contract]
        print(f"{contract}: runtime={runtime} initcode={initcode}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
