---
name: deploy-pool
description: >-
  Deploy an official PluriSwap share pool via the on-chain factory. Use when a
  trader asks to create a pool, vault, or sede de liquidez. Do not compile this
  repo or start Anvil. Do not register the pool on a backend.
---

# Deploy a Pool

The factory is already deployed. The trader sends one transaction. This skill does not run `forge` or Anvil.

## 1. Ask for params

- `sponsors` (one or more; immutable after create; default: connected wallet)
- `token` (settlement ERC-20)
- `escrow` (kernel on this chain)
- `controllers` (designated agent wallets; may be empty — sponsors are already agents)
- `openDeposits` (false = private; true = anyone can deposit)
- `depositors` (required if private; must be empty if open)
- `controllerFeeBps` (0–10000; reserved from idle per deal)

One settlement token per pool. Sponsors automatically can be Controllers of deals. An LP who is not a sponsor and not designated cannot.

## 2. Factory address

Read `deployments/<chain>-pool-factory.json` (Sepolia: `deployments/sepolia-pool-factory.json`).

Use:

- `factory`
- `officialCodehash`

If the file is missing, stop. The protocol team must run `script/DeployPoolFactory.s.sol` first.

This ABI is the **share vault**. Do not call the old `createPool(address,address,address,address[])`.

## 3. Create the pool

Do **not** compile Solidity. Call the factory with `cast` (or viem/ethers) against a public RPC:

```bash
cast send "$FACTORY" \
  "createPool(address[],address,address,address[],bool,address[],uint16)" \
  "$SPONSORS" "$TOKEN" "$ESCROW" "$CONTROLLERS" "$OPEN" "$DEPOSITORS" "$FEE_BPS" \
  --rpc-url "$RPC" --private-key "$KEY"
```

Parse the `PoolCreated(address pool, address token, address escrow, bool openDeposits)` log. That `pool` is the Holder.

## 4. Check official

```bash
cast keccak "$(cast code "$POOL" --rpc-url "$RPC")"
# or
cast call "$FACTORY" "isOfficial(address)(bool)" "$POOL" --rpc-url "$RPC"
```

Official = factory says true (clone of the published implementation).

Do not POST to a backend. Listing/registry is a later factory deploy, when that service exists.

## 5. Aftercare

To fund: an allowed depositor (or anyone, if open) `approve`s the pool, then `deposit(amount)`. First deposit ≥ `1e6`.

To open a deal: an agent `authorize(holderAuthorization)` then `escrow.activate` with empty holder signature (EIP-1271). Idle must cover `principal + fee`.

`reconcile` is permissionless and does not take `returned`. It reads `settlementOf`.

Fee to list and backend registry: not in this skill.
