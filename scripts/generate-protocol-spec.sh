#!/usr/bin/env bash
# Regenerates PLURISWAP_OPEN_PROTOCOL_SPEC.md from authored V2 technical sources.
# Do not hand-edit the aggregate; edit docs/v2/technical/*.md and re-run this script.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/PLURISWAP_OPEN_PROTOCOL_SPEC.md"
CORE="$ROOT/docs/v2/technical/MANDATORY_CORE.md"
OPT="$ROOT/docs/v2/technical/OPTIONAL_PROFILES.md"

for f in "$CORE" "$OPT"; do
  if [[ ! -f "$f" ]]; then
    echo "missing authored source: $f" >&2
    exit 1
  fi
done

{
  cat <<'EOF'
# PluriSwap Open Protocol — Technical Specification (Aggregate)

> **GENERATED FILE — DO NOT EDIT BY HAND.**
>
> Source of generation: `scripts/generate-protocol-spec.sh`
> Authored sources:
> - `docs/v2/technical/MANDATORY_CORE.md`
> - `docs/v2/technical/OPTIONAL_PROFILES.md`
>
> Business authority remains `PROTOCOL.md`.

EOF
  printf '\n---\n\n'
  printf '## Part A — Mandatory Core\n\n'
  cat "$CORE"
  printf '\n\n---\n\n'
  printf '## Part B — Optional Profiles\n\n'
  cat "$OPT"
  printf '\n'
} > "$OUT"

echo "wrote $OUT"
wc -l "$OUT"
