---
name: deploy-pool
description: >-
  Deploy an official PluriSwap owned pool via the on-chain factory. Use when a
  trader asks to create a pool, vault, or sede de liquidez. Do not compile this
  repo or start Anvil. Do not register the pool on a backend.
---

# Deploy a Pool

The factory is already deployed. The trader sends one transaction. This skill does not run `forge` or Anvil.

## 1. Ask for params

- `owner` (default: connected wallet)
- `token` (settlement ERC-20)
- `escrow` (kernel on this chain)
- `controllers` (addresses allowed to `authorize` deals)

One settlement token per pool.

## 2. Factory address

Read `deployments/<chain>-pool-factory.json` (Sepolia: `deployments/sepolia-pool-factory.json`).

Use:

- `factory`
- `officialCodehash`

If the file is missing, stop. The protocol team must run `script/DeployPoolFactory.s.sol` first.

## 3. Create the pool

Do **not** compile Solidity. Call the factory with `cast` (or viem/ethers) against a public RPC:

```bash
cast send "$FACTORY" \
  "createPool(address,address,address,address[])" \
  "$OWNER" "$TOKEN" "$ESCROW" "$CONTROLLERS" \
  --rpc-url "$RPC" --private-key "$KEY"
```

Parse the `PoolCreated(address pool, address owner, address token, address escrow)` log. That `pool` is the Holder.

## 4. Check official

```bash
cast keccak "$(cast code "$POOL" --rpc-url "$RPC")"
# or
cast call "$FACTORY" "isOfficial(address)(bool)" "$POOL" --rpc-url "$RPC"
```

Official = factory says true (clone of the published implementation).

Do not POST to a backend. Listing/registry is a later factory deploy, when that service exists.

## 5. Aftercare

To fund: owner `approve`s the pool, then `deposit(amount)`.

To open a deal: controller `authorize(holderAuthorization)` then `escrow.activate` with empty holder signature (EIP-1271).

Fee to list and backend registry: not in this skill.
