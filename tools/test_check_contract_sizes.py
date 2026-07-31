#!/usr/bin/env python3
"""Unit tests for the mandatory Core contract-size gate."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest


MODULE_PATH = Path(__file__).with_name("check_contract_sizes.py")
SPEC = importlib.util.spec_from_file_location("check_contract_sizes", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {MODULE_PATH}")
sizes = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(sizes)


VALID_TABLE = """
| Contract     | Runtime Size (B) | Initcode Size (B) | Runtime Margin (B) |
| Coordinator  | 1,232            | 1,530             | 23,344             |
| CoreDeployer | 3,987            | 5,987             | 20,589             |
| CoreEscrow   | 21,654           | 22,539            | 2,922              |
| CreditLedger | 21,929           | 22,585            | 2,647              |
"""


class ContractSizeGateTest(unittest.TestCase):
    def test_accepts_all_required_rows_below_limits(self) -> None:
        parsed = sizes.check_sizes(VALID_TABLE)

        self.assertEqual(parsed["Coordinator"], (1_232, 1_530))
        self.assertEqual(parsed["CreditLedger"], (21_929, 22_585))

    def test_rejects_a_missing_required_row(self) -> None:
        with self.assertRaisesRegex(sizes.SizeCheckError, "Coordinator.*missing"):
            sizes.check_sizes(VALID_TABLE.replace("| Coordinator", "| NotCoordinator"))

    def test_rejects_runtime_at_the_eip_170_limit(self) -> None:
        invalid = VALID_TABLE.replace("| 21,929", "| 24,576")

        with self.assertRaisesRegex(sizes.SizeCheckError, "CreditLedger.*runtime"):
            sizes.check_sizes(invalid)

    def test_rejects_initcode_at_the_eip_3860_limit(self) -> None:
        invalid = VALID_TABLE.replace("| 5,987", "| 49,152")

        with self.assertRaisesRegex(sizes.SizeCheckError, "CoreDeployer.*initcode"):
            sizes.check_sizes(invalid)

    def test_rejects_duplicate_required_rows(self) -> None:
        duplicate = VALID_TABLE + "| CoreEscrow | 1 | 1 | 1 |\n"

        with self.assertRaisesRegex(sizes.SizeCheckError, "CoreEscrow.*duplicate"):
            sizes.check_sizes(duplicate)


if __name__ == "__main__":
    unittest.main()
