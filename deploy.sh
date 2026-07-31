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
  --core       Deploy Mandatory Core in two stages (deployer, then triad)
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
  local pk rpc owner operator charter tech build planned_deployment_method
  local deployer_creation_code factory_creation_code ledger_creation_code
  local coordinator_creation_code escrow_creation_code
  local capability governance salt broadcast verify api_key verifier chain

  pk="$(toml_get "$section" private_key "$DEPLOY_TOML")"
  rpc="$(toml_get "$section" rpc_url "$DEPLOY_TOML")"
  owner="$(toml_get "$section" coordinator_owner "$DEPLOY_TOML")"
  operator="$(toml_get "$section" deployment_operator "$DEPLOY_TOML")"
  charter="$(toml_get "$section" charter_hash "$DEPLOY_TOML")"
  tech="$(toml_get "$section" tech_spec_hash "$DEPLOY_TOML")"
  build="$(toml_get "$section" build_hash "$DEPLOY_TOML")"
  planned_deployment_method="$(toml_get "$section" planned_deployment_method_hash "$DEPLOY_TOML")"
  deployer_creation_code="$(toml_get "$section" deployer_creation_code_hash "$DEPLOY_TOML")"
  factory_creation_code="$(toml_get "$section" factory_creation_code_hash "$DEPLOY_TOML")"
  ledger_creation_code="$(toml_get "$section" ledger_creation_code_hash "$DEPLOY_TOML")"
  coordinator_creation_code="$(toml_get "$section" coordinator_creation_code_hash "$DEPLOY_TOML")"
  escrow_creation_code="$(toml_get "$section" escrow_creation_code_hash "$DEPLOY_TOML")"
  capability="$(toml_get "$section" capability_hash "$DEPLOY_TOML")"
  governance="$(toml_get "$section" governance_hash "$DEPLOY_TOML")"
  salt="$(toml_get "$section" salt "$DEPLOY_TOML")"
  broadcast="$(toml_get "$section" broadcast "$DEPLOY_TOML")"
  verify="$(toml_get "$section" verify "$DEPLOY_TOML")"
  api_key="$(toml_get "$section" etherscan_api_key "$DEPLOY_TOML")"
  verifier="$(toml_get "$section" verifier_url "$DEPLOY_TOML")"
  chain="$(toml_get "$section" chain "$DEPLOY_TOML")"

  [[ -n "$pk" ]] || die "[$section].private_key is required"
  [[ "$pk" != *"YOUR_"* ]] || die "[$section].private_key still has a placeholder — edit deploy.toml"
  [[ -n "$rpc" ]] || die "[$section].rpc_url is required"

  require_address() {
    local name="$1"
    local value="$2"
    [[ "$value" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "[$section].$name must be a 20-byte address"
    [[ "$value" != "0x0000000000000000000000000000000000000000" ]] || die "[$section].$name cannot be zero"
  }

  require_hash() {
    local name="$1"
    local value="$2"
    [[ "$value" =~ ^0x[0-9a-fA-F]{64}$ ]] || die "[$section].$name must be a bytes32 hash"
    [[ "$value" != "0x0000000000000000000000000000000000000000000000000000000000000000" ]] || die "[$section].$name cannot be zero"
  }

  require_address coordinator_owner "$owner"
  require_address deployment_operator "$operator"
  require_hash charter_hash "$charter"
  require_hash tech_spec_hash "$tech"
  require_hash build_hash "$build"
  require_hash planned_deployment_method_hash "$planned_deployment_method"
  require_hash deployer_creation_code_hash "$deployer_creation_code"
  require_hash factory_creation_code_hash "$factory_creation_code"
  require_hash ledger_creation_code_hash "$ledger_creation_code"
  require_hash coordinator_creation_code_hash "$coordinator_creation_code"
  require_hash escrow_creation_code_hash "$escrow_creation_code"
  require_hash capability_hash "$capability"
  require_hash governance_hash "$governance"
  require_hash salt "$salt"

  export PRIVATE_KEY="$pk"
  export CHARTER_HASH="$charter"
  export TECH_SPEC_HASH="$tech"
  export BUILD_HASH="$build"
  export PLANNED_DEPLOYMENT_METHOD_HASH="$planned_deployment_method"
  export DEPLOYER_CREATION_CODE_HASH="$deployer_creation_code"
  export FACTORY_CREATION_CODE_HASH="$factory_creation_code"
  export LEDGER_CREATION_CODE_HASH="$ledger_creation_code"
  export COORDINATOR_CREATION_CODE_HASH="$coordinator_creation_code"
  export ESCROW_CREATION_CODE_HASH="$escrow_creation_code"
  export CAPABILITY_HASH="$capability"
  export GOVERNANCE_HASH="$governance"
  export SALT_CORE="$salt"
  export COORDINATOR_OWNER="$owner"
  export DEPLOYMENT_OPERATOR="$operator"

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
  echo "    salt: ${SECTION_SALT}"
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
