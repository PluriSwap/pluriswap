#!/usr/bin/env python3
"""Unit tests for the pinned Slither baseline gate."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest


MODULE_PATH = Path(__file__).with_name("check_slither_baseline.py")
SPEC = importlib.util.spec_from_file_location("check_slither_baseline", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {MODULE_PATH}")
triage = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(triage)


def finding(fingerprint: str, check: str = "reentrancy-no-eth", impact: str = "Medium") -> dict:
    return {
        "id": fingerprint,
        "check": check,
        "impact": impact,
        "confidence": "Medium",
        "description": f"{check} fixture",
        "elements": [],
    }


def accepted(fingerprint: str, check: str = "reentrancy-no-eth", impact: str = "Medium") -> dict:
    return {
        "fingerprint": fingerprint,
        "check": check,
        "impact": impact,
        "confidence": "Medium",
        "reason": "Fixture is protected by the nonReentrant state machine.",
    }


class SlitherBaselineGateTest(unittest.TestCase):
    def test_accepts_exact_nonstale_baseline(self) -> None:
        report = {"success": True, "error": None, "results": {"detectors": [finding("abc")]}}
        baseline = {"schema": 1, "slither_version": "0.11.6", "findings": [accepted("abc")]}

        summary = triage.evaluate_report(report, baseline)

        self.assertEqual(summary.accepted, 1)
        self.assertEqual(summary.by_impact, {"Medium": 1})

    def test_rejects_new_untriaged_finding(self) -> None:
        report = {
            "success": True,
            "error": None,
            "results": {"detectors": [finding("abc"), finding("new", "incorrect-exp", "High")]},
        }
        baseline = {"schema": 1, "slither_version": "0.11.6", "findings": [accepted("abc")]}

        with self.assertRaisesRegex(triage.TriageError, "new.*incorrect-exp.*High"):
            triage.evaluate_report(report, baseline)

    def test_rejects_stale_baseline_entry(self) -> None:
        report = {"success": True, "error": None, "results": {"detectors": [finding("abc")]}}
        baseline = {
            "schema": 1,
            "slither_version": "0.11.6",
            "findings": [accepted("abc"), accepted("gone", "unused-return")],
        }

        with self.assertRaisesRegex(triage.TriageError, "stale.*unused-return"):
            triage.evaluate_report(report, baseline)

    def test_rejects_tool_error_even_with_no_findings(self) -> None:
        report = {"success": False, "error": "compiler failed", "results": {"detectors": []}}
        baseline = {"schema": 1, "slither_version": "0.11.6", "findings": []}

        with self.assertRaisesRegex(triage.TriageError, "compiler failed"):
            triage.evaluate_report(report, baseline)

    def test_rejects_baseline_without_a_reason(self) -> None:
        report = {"success": True, "error": None, "results": {"detectors": [finding("abc")]}}
        entry = accepted("abc")
        entry["reason"] = ""
        baseline = {"schema": 1, "slither_version": "0.11.6", "findings": [entry]}

        with self.assertRaisesRegex(triage.TriageError, "reason"):
            triage.evaluate_report(report, baseline)

    def test_rejects_fingerprint_metadata_drift(self) -> None:
        report = {"success": True, "error": None, "results": {"detectors": [finding("abc")]}}
        baseline = {
            "schema": 1,
            "slither_version": "0.11.6",
            "findings": [accepted("abc", "incorrect-equality")],
        }

        with self.assertRaisesRegex(triage.TriageError, "metadata"):
            triage.evaluate_report(report, baseline)


if __name__ == "__main__":
    unittest.main()
