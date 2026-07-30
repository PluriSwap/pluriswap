#!/usr/bin/env bash
# Deploy PluriSwap packages from deploy.toml credentials.
# Usage:
#   ./deploy.sh --core
#   ./deploy.sh --core --dry-run
#   ./deploy.sh --help

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

DEPLOY_TOML="${DEPLOY_TOML:-$ROOT/deploy.toml}"
EXAMPLE_TOML="$ROOT/deploy.toml.example"

PACKAGE=""
DRY_RUN=0

usage() {
  cat <<'EOF'
Deploy PluriSwap contracts using per-package credentials in deploy.toml.

Usage:
  ./deploy.sh --core [--dry-run]
  ./deploy.sh --help

Flags:
  --core       Deploy Mandatory Core (CreditLedger + Coordinator + CoreEscrow)
  --dry-run    Simulate only (overrides broadcast = true in deploy.toml)
  --help       Show this help

Config:
  Reads ./deploy.toml (or $DEPLOY_TOML). If missing, copies deploy.toml.example.
  Each package section may specify its own private_key / rpc_url so packages
  can be deployed from different wallets.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

# Read KEY from [section] in a simple TOML file (string/bool/empty values).
toml_get() {
  local section="$1"
  local key="$2"
  local file="$3"
  awk -v section="$section" -v key="$key" '
    BEGIN { in_section = 0 }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    /^\[/ {
      gsub(/[[:space:]]/, "", $0)
      in_section = ($0 == "[" section "]")
      next
    }
    in_section && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      sub(/^[^=]*=[[:space:]]*/, "", $0)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
      if ($0 ~ /^".*"$/) { sub(/^"/, "", $0); sub(/"$/, "", $0) }
      if ($0 ~ /^'\''.*'\''$/) { sub(/^'\''/, "", $0); sub(/'\''$/, "", $0) }
      print $0
      exit
    }
  ' "$file"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

ensure_deploy_toml() {
  if [[ ! -f "$DEPLOY_TOML" ]]; then
    [[ -f "$EXAMPLE_TOML" ]] || die "missing $EXAMPLE_TOML"
    cp "$EXAMPLE_TOML" "$DEPLOY_TOML"
    echo "created $DEPLOY_TOML from example — fill in credentials, then re-run."
    exit 1
  fi
}

load_section() {
  local section="$1"
  local pk rpc owner charter tech broadcast verify api_key verifier chain

  pk="$(toml_get "$section" private_key "$DEPLOY_TOML")"
  rpc="$(toml_get "$section" rpc_url "$DEPLOY_TOML")"
  owner="$(toml_get "$section" coordinator_owner "$DEPLOY_TOML")"
  charter="$(toml_get "$section" charter_hash "$DEPLOY_TOML")"
  tech="$(toml_get "$section" tech_spec_hash "$DEPLOY_TOML")"
  salt="$(toml_get "$section" salt "$DEPLOY_TOML")"
  broadcast="$(toml_get "$section" broadcast "$DEPLOY_TOML")"
  verify="$(toml_get "$section" verify "$DEPLOY_TOML")"
  api_key="$(toml_get "$section" etherscan_api_key "$DEPLOY_TOML")"
  verifier="$(toml_get "$section" verifier_url "$DEPLOY_TOML")"
  chain="$(toml_get "$section" chain "$DEPLOY_TOML")"

  [[ -n "$pk" ]] || die "[$section].private_key is required"
  [[ "$pk" != *"YOUR_"* ]] || die "[$section].private_key still has a placeholder — edit deploy.toml"
  [[ -n "$rpc" ]] || die "[$section].rpc_url is required"

  export PRIVATE_KEY="$pk"
  export CHARTER_HASH="${charter:-}"
  export TECH_SPEC_HASH="${tech:-}"
  if [[ -n "${salt:-}" ]]; then
    export SALT_CORE="$salt"
  else
    unset SALT_CORE 2>/dev/null || true
  fi
  if [[ -n "${owner:-}" ]]; then
    export COORDINATOR_OWNER="$owner"
  else
    unset COORDINATOR_OWNER 2>/dev/null || true
  fi

  # shellcheck disable=SC2034
  SECTION_RPC_URL="$rpc"
  SECTION_BROADCAST="${broadcast:-true}"
  SECTION_VERIFY="${verify:-false}"
  SECTION_ETHERSCAN_API_KEY="${api_key:-}"
  SECTION_VERIFIER_URL="${verifier:-}"
  SECTION_CHAIN="${chain:-}"
  SECTION_SALT="${salt:-}"
}

truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

deploy_core() {
  require_cmd forge
  ensure_deploy_toml
  load_section "core"

  local args=(
    script
    script/DeployCore.s.sol:DeployCore
    --rpc-url "$SECTION_RPC_URL"
  )

  if [[ -n "$SECTION_CHAIN" ]]; then
    args+=(--chain "$SECTION_CHAIN")
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    SECTION_BROADCAST="false"
  fi

  if truthy "$SECTION_BROADCAST"; then
    args+=(--broadcast)
  fi

  if truthy "$SECTION_VERIFY"; then
    [[ -n "$SECTION_ETHERSCAN_API_KEY" ]] || die "[core].etherscan_api_key required when verify = true"
    export ETHERSCAN_API_KEY="$SECTION_ETHERSCAN_API_KEY"
    args+=(--verify)
    if [[ -n "$SECTION_VERIFIER_URL" ]]; then
      args+=(--verifier-url "$SECTION_VERIFIER_URL")
    fi
  fi

  echo "==> Deploying Mandatory Core (CREATE2)"
  echo "    rpc:  $SECTION_RPC_URL"
  echo "    chain:${SECTION_CHAIN:-"(from rpc)"}"
  echo "    salt: ${SECTION_SALT:-"(default pluriswap.core.v2)"}"
  echo "    broadcast: $SECTION_BROADCAST"
  echo "    verify: $SECTION_VERIFY"
  forge "${args[@]}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --core)
      PACKAGE="core"
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1 (try --help)"
      ;;
  esac
done

[[ -n "$PACKAGE" ]] || die "select a package flag (e.g. --core)"

case "$PACKAGE" in
  core) deploy_core ;;
  *) die "unsupported package: $PACKAGE" ;;
esac
