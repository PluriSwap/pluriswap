#!/usr/bin/env python3
"""Run pinned Slither and require an exact, reviewed finding baseline."""

from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from typing import Any, NamedTuple


PINNED_SLITHER_VERSION = "0.11.6"
REQUIRED_BASELINE_SCHEMA = 1


class TriageError(ValueError):
    """Raised when Slither execution or baseline reconciliation is unsafe."""


class TriageSummary(NamedTuple):
    accepted: int
    by_impact: dict[str, int]


def _load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise TriageError(f"cannot read {path}: {error}") from error
    if not isinstance(value, dict):
        raise TriageError(f"{path} must contain a JSON object")
    return value


def _finding_label(value: dict[str, Any]) -> str:
    return f"{value.get('check', '<unknown>')} {value.get('impact', '<unknown>')}"


def evaluate_report(report: dict[str, Any], baseline: dict[str, Any]) -> TriageSummary:
    """Require every current finding to be reviewed and every review to remain current."""
    if report.get("success") is not True:
        raise TriageError(f"Slither tool error: {report.get('error') or 'unknown failure'}")
    if baseline.get("schema") != REQUIRED_BASELINE_SCHEMA:
        raise TriageError(f"unsupported Slither baseline schema: {baseline.get('schema')!r}")

    results = report.get("results")
    current_values = results.get("detectors") if isinstance(results, dict) else None
    baseline_values = baseline.get("findings")
    if not isinstance(current_values, list):
        raise TriageError("Slither report does not contain results.detectors")
    if not isinstance(baseline_values, list):
        raise TriageError("Slither baseline does not contain findings")

    current: dict[str, dict[str, Any]] = {}
    for value in current_values:
        if not isinstance(value, dict) or not isinstance(value.get("id"), str):
            raise TriageError("Slither finding is missing its fingerprint")
        fingerprint = value["id"]
        if fingerprint in current:
            raise TriageError(f"Slither report repeats fingerprint {fingerprint}")
        current[fingerprint] = value

    accepted: dict[str, dict[str, Any]] = {}
    required_fields = ("fingerprint", "check", "impact", "confidence", "reason")
    for value in baseline_values:
        if not isinstance(value, dict):
            raise TriageError("Slither baseline finding must be an object")
        missing = [field for field in required_fields if not value.get(field)]
        if missing:
            raise TriageError(
                f"Slither baseline entry is missing {', '.join(missing)}; every entry needs a reason"
            )
        fingerprint = value["fingerprint"]
        if not isinstance(fingerprint, str):
            raise TriageError("Slither baseline fingerprint must be a string")
        if fingerprint in accepted:
            raise TriageError(f"Slither baseline repeats fingerprint {fingerprint}")
        accepted[fingerprint] = value

    new_ids = sorted(set(current) - set(accepted))
    stale_ids = sorted(set(accepted) - set(current))
    if new_ids:
        labels = ", ".join(
            f"{current[fingerprint].get('id')} {_finding_label(current[fingerprint])}"
            for fingerprint in new_ids
        )
        raise TriageError(f"new untriaged Slither finding(s): {labels}")
    if stale_ids:
        labels = ", ".join(
            f"{accepted[fingerprint].get('fingerprint')} {_finding_label(accepted[fingerprint])}"
            for fingerprint in stale_ids
        )
        raise TriageError(f"stale Slither baseline finding(s): {labels}")

    for fingerprint, finding in current.items():
        entry = accepted[fingerprint]
        current_metadata = (
            finding.get("check"),
            finding.get("impact"),
            finding.get("confidence"),
        )
        accepted_metadata = (entry["check"], entry["impact"], entry["confidence"])
        if current_metadata != accepted_metadata:
            raise TriageError(
                f"Slither fingerprint metadata drift for {fingerprint}: "
                f"{accepted_metadata!r} != {current_metadata!r}"
            )

    impacts = Counter(str(value.get("impact")) for value in current.values())
    return TriageSummary(accepted=len(current), by_impact=dict(sorted(impacts.items())))


def _run_slither(slither: str, config: Path) -> dict[str, Any]:
    version = subprocess.run(
        [slither, "--version"], check=False, capture_output=True, text=True
    )
    if version.returncode != 0:
        raise TriageError(f"cannot execute Slither: {version.stderr.strip()}")
    if version.stdout.strip() != PINNED_SLITHER_VERSION:
        raise TriageError(
            f"Slither {PINNED_SLITHER_VERSION} required, got {version.stdout.strip()!r}"
        )

    with tempfile.TemporaryDirectory(prefix="pluriswap-slither-") as directory:
        report_path = Path(directory) / "report.json"
        process = subprocess.run(
            [
                slither,
                ".",
                "--config-file",
                str(config),
                "--json",
                str(report_path),
                "--fail-none",
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        if process.returncode != 0:
            detail = process.stderr.strip() or process.stdout.strip()
            raise TriageError(f"Slither execution failed ({process.returncode}): {detail}")
        return _load_json(report_path)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, default=Path("slither-baseline.json"))
    parser.add_argument("--config", type=Path, default=Path("slither.config.json"))
    parser.add_argument("--report", type=Path, help="check an existing JSON report")
    parser.add_argument("--slither", default="slither", help="pinned Slither executable")
    args = parser.parse_args(argv)

    try:
        baseline = _load_json(args.baseline)
        if baseline.get("slither_version") != PINNED_SLITHER_VERSION:
            raise TriageError(
                f"baseline Slither version must be {PINNED_SLITHER_VERSION}, "
                f"got {baseline.get('slither_version')!r}"
            )
        report = _load_json(args.report) if args.report else _run_slither(args.slither, args.config)
        summary = evaluate_report(report, baseline)
    except TriageError as error:
        print(f"Slither baseline check failed: {error}", file=sys.stderr)
        return 1

    counts = " ".join(f"{impact}={count}" for impact, count in summary.by_impact.items())
    print(f"Slither baseline check passed: accepted={summary.accepted} new=0 stale=0 {counts}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
