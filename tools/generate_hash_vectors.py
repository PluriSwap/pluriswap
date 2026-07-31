#!/usr/bin/env python3
"""Generate independent keccak/ABI hash vectors for DealHashing and Intent/Evidence checks."""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "test" / "vectors" / "HashVectors.sol"

FUNDING_SPEC_TYPE = (
    "FundingSpec(uint8 purpose,uint8 sourceMode,address token,uint256 amount,"
    "address source,bytes32 sourcePositionId,address authority)"
)
FUNDING_AUTH_TYPE = (
    "FundingAuth(bytes32 termsHash,bytes32 fundingSpecHash,uint8 purpose,"
    "address authority,uint256 nonce,uint64 expiry)"
)
RESOLUTION_TYPE = (
    "ResolutionAuth(bytes32 dealId,uint8 action,uint256 resolutionNonce,uint64 expiry,"
    "uint16 providerShareBps,uint8 operatorFaultCode,bytes32 operatorFaultEvidenceHash,"
    "bytes32 reservationDispositionsHash,bytes32 extensionsHash)"
)
TERMINAL_TYPE = (
    "PluriSwapTerminalRecord(uint64 chainId,uint32 protocolVersion,address escrow,"
    "address ledger,bytes32 dealId,uint8 terminalState,uint8 outcome,uint8 operatorFaultCode,"
    "bytes32 operatorFaultEvidenceHash,address token,uint256 principal,uint256 holderSideReturn,"
    "uint256 providerGross,uint256 providerNet,uint256 completionCollected,uint256 operatorFeePaid,"
    "uint256 operatorFeeUnlocked,address holderReceiver,address providerReceiver,"
    "address completionFeeRecipient,address operatorFeeRecipient,address operatorFeeReturnReceiver,"
    "bytes32 termsHash,bytes32 modulesHash,bytes32 evidenceHash,bytes32 reservationsHash,"
    "bytes32 reservationDispositionsHash,uint64 terminatedAt)"
)
INTENT_TYPE = (
    "CoreDeploymentIntentV1(bytes32 schemaId,uint16 schemaVersion,uint8 deploymentKind,"
    "uint64 chainId,uint32 protocolVersion,bytes32 charterHash,bytes32 techSpecHash,"
    "bytes32 buildHash,bytes32 plannedDeploymentMethodHash,bytes32 coreDeployerCreationCodeHash,"
    "bytes32 factoryCreationCodeHash,bytes32 ledgerCreationCodeHash,"
    "bytes32 coordinatorCreationCodeHash,bytes32 escrowCreationCodeHash,address coreDeployer,"
    "address ledger,address coordinator,address escrow,bytes32 capabilityHash,"
    "bytes32 governanceHash,bytes32 predecessorIntentHash)"
)
EVIDENCE_TYPE = (
    "CoreDeploymentEvidenceV1(bytes32 schemaId,uint16 schemaVersion,bytes32 intentHash,"
    "bytes32 coreDeployerArtifactHash,bytes32 factoryArtifactHash,bytes32 ledgerArtifactHash,"
    "bytes32 coordinatorArtifactHash,bytes32 escrowArtifactHash,bytes32 deploymentMethodHash,"
    "bytes32 verificationHash)"
)
INTENT_SCHEMA_STRING = "pluriswap.mandatory-core.intent.v1"
EVIDENCE_SCHEMA_STRING = "pluriswap.mandatory-core.evidence.v1"


def _run(args: list[str]) -> str:
    process = subprocess.run(args, check=True, capture_output=True, text=True)
    return process.stdout.strip()


def keccak_string(value: str) -> str:
    return _run(["cast", "keccak", value])


def keccak_hex(data_hex: str) -> str:
    if not data_hex.startswith("0x"):
        data_hex = "0x" + data_hex
    return _run(["cast", "keccak", data_hex])


def abi_encode(signature: str, *values: str) -> str:
    return _run(["cast", "abi-encode", signature, *values])


def as_bytes32(value: int) -> str:
    return "0x" + value.to_bytes(32, "big").hex()


def as_address(value: int) -> str:
    return "0x" + value.to_bytes(20, "big").hex()


def build_vectors() -> dict[str, str]:
    funding_spec_typehash = keccak_string(FUNDING_SPEC_TYPE)
    funding_auth_typehash = keccak_string(FUNDING_AUTH_TYPE)
    resolution_typehash = keccak_string(RESOLUTION_TYPE)
    terminal_typehash = keccak_string(TERMINAL_TYPE)
    intent_typehash = keccak_string(INTENT_TYPE)
    evidence_typehash = keccak_string(EVIDENCE_TYPE)
    intent_schema_id = keccak_string(INTENT_SCHEMA_STRING)
    evidence_schema_id = keccak_string(EVIDENCE_SCHEMA_STRING)

    funding_spec = keccak_hex(
        abi_encode(
            "x(bytes32,uint8,uint8,address,uint256,address,bytes32,address)",
            funding_spec_typehash,
            "1",
            "1",
            as_address(5),
            str(100 * 10**18),
            as_address(1),
            as_bytes32(0),
            as_address(1),
        )
    )
    funding_auth = keccak_hex(
        abi_encode(
            "x(bytes32,bytes32,bytes32,uint8,address,uint256,uint64)",
            funding_auth_typehash,
            as_bytes32(1),
            as_bytes32(2),
            "1",
            as_address(1),
            "1",
            "1700000000",
        )
    )
    resolution = keccak_hex(
        abi_encode(
            "x(bytes32,bytes32,uint8,uint256,uint64,uint16,uint8,bytes32,bytes32,bytes32)",
            resolution_typehash,
            as_bytes32(1),
            "0",
            "1",
            "1700000000",
            "0",
            "0",
            as_bytes32(0),
            as_bytes32(0),
            as_bytes32(0),
        )
    )
    terminal = keccak_hex(
        abi_encode(
            "x(bytes32,uint64,uint32,address,address,bytes32,uint8,uint8,uint8,bytes32,address,"
            "uint256,uint256,uint256,uint256,uint256,uint256,uint256,address,address,address,"
            "address,address,bytes32,bytes32,bytes32,bytes32,bytes32,uint64)",
            terminal_typehash,
            "1",
            "2",
            as_address(0xE5C1),
            as_address(0x1ED),
            as_bytes32(1),
            "16",
            "1",
            "0",
            as_bytes32(0),
            as_address(0x70C),
            str(100 * 10**18),
            "0",
            str(100 * 10**18),
            str(97 * 10**18),
            str(3 * 10**18),
            "0",
            "0",
            as_address(0x1111),
            as_address(0x2222),
            as_address(0xFEE),
            as_address(0),
            as_address(0),
            as_bytes32(1),
            as_bytes32(0),
            as_bytes32(0),
            as_bytes32(0),
            as_bytes32(0),
            "1700000000",
        )
    )
    intent = keccak_hex(
        abi_encode(
            "x(bytes32,bytes32,uint16,uint8,uint64,uint32,bytes32,bytes32,bytes32,bytes32,bytes32,"
            "bytes32,bytes32,bytes32,bytes32,address,address,address,address,bytes32,bytes32,"
            "bytes32)",
            intent_typehash,
            intent_schema_id,
            "1",
            "1",
            "42161",
            "2",
            as_bytes32(11),
            as_bytes32(12),
            as_bytes32(21),
            as_bytes32(22),
            as_bytes32(23),
            as_bytes32(24),
            as_bytes32(25),
            as_bytes32(26),
            as_bytes32(27),
            as_address(0xD01),
            as_address(0x1ED),
            as_address(0xC001),
            as_address(0xE5C1),
            as_bytes32(31),
            as_bytes32(32),
            as_bytes32(0),
        )
    )
    evidence = keccak_hex(
        abi_encode(
            "x(bytes32,bytes32,uint16,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,"
            "bytes32)",
            evidence_typehash,
            evidence_schema_id,
            "1",
            intent,
            as_bytes32(41),
            as_bytes32(42),
            as_bytes32(43),
            as_bytes32(44),
            as_bytes32(45),
            as_bytes32(46),
            as_bytes32(47),
        )
    )

    return {
        "fundingSpecTypehash": funding_spec_typehash,
        "fundingAuthTypehash": funding_auth_typehash,
        "resolutionTypehash": resolution_typehash,
        "terminalTypehash": terminal_typehash,
        "intentTypehash": intent_typehash,
        "evidenceTypehash": evidence_typehash,
        "intentSchemaId": intent_schema_id,
        "evidenceSchemaId": evidence_schema_id,
        "fundingSpecHash": funding_spec,
        "fundingAuthHash": funding_auth,
        "resolutionHash": resolution,
        "terminalHash": terminal,
        "intentHash": intent,
        "evidenceHash": evidence,
    }


def render(vectors: dict[str, str]) -> str:
    lines = [
        "// SPDX-License-Identifier: MIT",
        "pragma solidity ^0.8.24;",
        "",
        "// Generated by tools/generate_hash_vectors.py. Do not edit manually.",
        "library HashVectors {",
    ]
    for name, value in vectors.items():
        lines.append(f"    bytes32 internal constant {name} =")
        lines.append(f"        {value};")
    lines.extend(["}", ""])
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="fail if the committed Solidity fixture is not up to date",
    )
    args = parser.parse_args(argv)

    try:
        rendered = render(build_vectors())
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"hash vector generation failed: {error}", file=sys.stderr)
        return 1

    relative = OUTPUT.relative_to(ROOT)
    if args.check:
        if not OUTPUT.exists() or OUTPUT.read_text(encoding="utf-8") != rendered:
            print(f"{relative} is not up to date", file=sys.stderr)
            return 1
        print(f"{relative} is up to date")
        return 0

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(rendered, encoding="utf-8")
    print(f"Wrote {relative}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
