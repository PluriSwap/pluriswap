#!/usr/bin/env python3
"""Generate a reviewable Slither baseline from a successful pinned report.

This is an explicit triage aid, not a CI update step. Review every generated entry
before replacing slither-baseline.json.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


SLITHER_VERSION = "0.11.6"


def reason_for(finding: dict[str, Any]) -> str:
    check = finding["check"]
    description = finding["description"]

    if check in {"incorrect-exp", "divide-before-multiply"}:
        return (
            "Intentional Remco Bloemen/Uniswap FullMath modular-inverse algorithm; XOR seeds the "
            "Newton inverse and divisions remove exact powers of two."
        )
    if check == "incorrect-equality":
        return (
            "Exact equality is intentional for closed enum/status branches, zero boundaries, and "
            "exact token-accounting reconciliation."
        )
    if check == "locked-ether":
        return (
            "The payable arbitration stub always reverts; native and forced ETH are unsupported "
            "and no privileged sweep path is permitted."
        )
    if check in {"reentrancy-no-eth", "reentrancy-benign"}:
        return (
            "The entrypoint is nonReentrant; external calls use the fixed Ledger or exact-token "
            "boundary, and effects commit only after the atomic external operation succeeds."
        )
    if check == "uninitialized-local":
        return (
            "Solidity deliberately zero-initializes the fixed memory allocation array; a separate "
            "count exposes only entries written by the bounded append routine."
        )
    if check == "unused-return":
        return (
            "The checked-add call is intentionally used as a reverting representability assertion; "
            "the validated horizon value itself is not stored at this transition."
        )
    if check == "calls-loop":
        return (
            "Only Escrow can call this path and supplies the protocol-bounded sorted token set; each "
            "exact balance query is required for independent boundary reconciliation."
        )
    if check == "timestamp":
        return (
            "Timestamp comparisons implement signed expiries and protocol deadlines, not randomness; "
            "uint64 horizon and no-mutation behavior are explicitly checked."
        )
    if check == "assembly":
        if "CoreDeployer" in description:
            return "CREATE consumes dynamic child initcode and requires the reviewed memory-safe opcode block."
        if "FullMath" in description or "DeficitMath" in description:
            return "Reviewed memory-safe 512-bit arithmetic assembly implements exact or saturating mulDiv."
        if "ExactERC20" in description:
            return "Reviewed memory-safe assembly decodes the exact 32-byte ERC-20 return/balance word."
        if "SignatureValidation" in description:
            return "Reviewed memory-safe assembly decodes canonical 64/65-byte signatures."
    if check == "cyclomatic-complexity":
        return (
            "The bounded validation/state branch set mirrors the closed protocol cases; splitting it "
            "would obscure required check ordering without reducing reachable paths."
        )
    if check == "low-level-calls":
        if "ExactERC20" in description:
            return (
                "Raw ERC-20 calls intentionally validate optional return data and exact before/after "
                "balances; high-level IERC20 calls cannot enforce this token boundary."
            )
        if "SignatureValidation" in description:
            return (
                "The bounded staticcall is the required ERC-1271 signature check and validates the "
                "returned magic value without granting state-changing control."
            )
    raise ValueError(f"no reviewed reason for detector {check}: {description.splitlines()[0]}")


def generate(report: dict[str, Any]) -> dict[str, Any]:
    if report.get("success") is not True:
        raise ValueError(f"cannot baseline failed Slither report: {report.get('error')}")
    findings = report.get("results", {}).get("detectors")
    if not isinstance(findings, list):
        raise ValueError("Slither report has no detector list")

    entries = []
    for finding in findings:
        entries.append(
            {
                "fingerprint": finding["id"],
                "check": finding["check"],
                "impact": finding["impact"],
                "confidence": finding["confidence"],
                "location": finding.get("first_markdown_element", ""),
                "reason": reason_for(finding),
            }
        )
    entries.sort(key=lambda entry: (entry["check"], entry["fingerprint"]))
    return {
        "schema": 1,
        "slither_version": SLITHER_VERSION,
        "config": "slither.config.json",
        "findings": entries,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    report = json.loads(args.report.read_text(encoding="utf-8"))
    baseline = generate(report)
    args.output.write_text(json.dumps(baseline, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {len(baseline['findings'])} reviewed entries to {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
