#!/usr/bin/env bash
# End-to-end deploy and catalog run against a throwaway chain.
#
# `forge test` exercises the contracts; nothing exercised the SCRIPTS until this existed, and two of
# them had been broken for months without anyone noticing: `Paths` still asserted that a timeout
# claim lands in RELEASED (CLAIMED became its own terminal on 2026-09-12), and `PoolDeal` still
# listed a Sponsor as a designated controller (the share vault rejects that). Both are the kind of
# rot that only a cold chain finds, so CI runs this on every push.
#
# Usage: script/e2e.sh [port]     (needs anvil and forge on PATH)
set -euo pipefail

PORT="${1:-8545}"
RPC="http://127.0.0.1:${PORT}"
# Anvil's first account. A throwaway chain, a published key: never used anywhere else.
KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

anvil --silent --port "$PORT" &
ANVIL=$!
trap 'kill $ANVIL 2>/dev/null || true' EXIT
until cast block-number --rpc-url "$RPC" >/dev/null 2>&1; do sleep 1; done

# Order matters: each step reads the deployment record the previous one wrote.
STEPS=(
  "script/Deploy.s.sol:Deploy"
  "script/Paths.s.sol:Paths"
  "script/DeployPackages.s.sol:DeployPackages"
  "script/TrioDeal.s.sol:TrioDeal"
  "script/CatalogDeals.s.sol:CatalogDeals"
  "script/DeployPoolFactory.s.sol:DeployPoolFactory"
  "script/PoolDeal.s.sol:PoolDeal"
  "script/DeployPrivate.s.sol:DeployPrivate"
)

failed=0
for step in "${STEPS[@]}"; do
  name="${step##*:}"
  if HOLDER_PRIVATE_KEY="$KEY" forge script "$step" \
      --rpc-url "$RPC" --broadcast --skip-simulation --private-key "$KEY" >"/tmp/e2e-$name.log" 2>&1; then
    echo "[OK]   $name"
  else
    echo "[FAIL] $name"
    tail -25 "/tmp/e2e-$name.log"
    failed=1
  fi
done
[ "$failed" -eq 0 ] || { echo "e2e: a deploy or catalog script failed"; exit 1; }

# The scripts' own `require`s run locally; this checks what actually LANDED on the chain.
ESCROW=$(python3 -c "import json;print(json.load(open('deployments/31337-paths.json'))['escrow'])")
cast logs --rpc-url "$RPC" --address "$ESCROW" \
  "Settled(bytes32,uint8,uint256,uint256)" --from-block 0 --json \
  | python3 -c '
import json, sys
NAMES = ["NONE","FUNDED","FIAT_SENT","DISPUTED","RELEASED","RESOLVED_SPLIT","STALEMATE",
         "CANCELLED","ARBITRATION_ACTIVE","RESOLVED_BY_ARBITRATION","CLAIMED","ABANDONED"]
# CASE-CORE-03..15, as PLURISWAP.md §3.9 lists them.
EXPECTED = {"CANCELLED": 5, "RELEASED": 3, "CLAIMED": 1, "RESOLVED_SPLIT": 2, "ABANDONED": 1}
PRINCIPAL = 1_000_000
rows = json.load(sys.stdin)
got = {}
for row in rows:
    d = row["data"][2:]
    w = [d[i:i+64] for i in range(0, len(d), 64)]
    status, holder, provider = NAMES[int(w[1],16)], int(w[2],16), int(w[3],16)
    got[status] = got.get(status, 0) + 1
    assert holder + provider == PRINCIPAL, f"{status} does not conserve principal: {holder}+{provider}"
    if status == "ABANDONED":
        assert provider == PRINCIPAL, f"abandoned dispute paid the Provider {provider}, not the pot"
assert got == EXPECTED, f"terminal histogram {got} != {EXPECTED}"
print(f"[OK]   {len(rows)} Core terminals on chain, principal conserved in every one")
'
echo "e2e: green"
