# PluriSwap

Escrow de principal cripto contra fiat offchain. El kernel es una máquina de estados cerrada con tres roles (Holder, Provider, Controller). Paquetes, pools y rampas son opt-in y viven fuera de esa máquina.

## Architecture

Read `ARCHITECTURE.md` first. It is the map of layers, package binding, and what a given escrow instance can resolve.

| Doc | What it freezes |
| --- | --- |
| `ARCHITECTURE.md` | Layers, interfaces, `packageId` resolution, observability |
| `STATE_MACHINE.md` | States, transitions, outcomes, clocks |
| `ENCODING.md` | EIP-712 typed data, nonces, `dealId` |
| `PACKAGES.md` | Reputation, bonds, ZK, arbitration formulas |
| `PROTECTION.md` | Kernel → package verbs, fees, DAO as recipient |
| `POOLS.md` | Vault as Holder (EIP-1271), shares, sponsors |
| `RAMPS.md` | Bridge composers, zero protocol bps |
| `IMPLEMENTATION.md` | Libraries, OpenZeppelin, bytecode split |
| `PLAN.md` | TDD order (historical) |

Conflict: states/economy → `STATE_MACHINE.md` / `PACKAGES.md`. Layering/binding → `ARCHITECTURE.md`.

## Stack

Foundry, Solidity `0.8.28`, Cancun, `via_ir`. OpenZeppelin v5. Target chain: Arbitrum (Sepolia `421614` today). No proxy, no `Pausable` / `Ownable` on settlement.

## Build and test

```shell
forge build
forge test
```

Core-only deals use `packageIds = []`. A packaged deal names `packageId`s and the relayer passes module addresses at `activate`. The same escrow resolves any compatible impl (`ARCHITECTURE.md` §5).

## Layout

```
src/Escrow.sol              kernel
src/interfaces/IEscrow.sol  read surface for packages, pools, ramps
src/libraries/              Consent, Terms, Settlement, Clocks, Types, PackageId
src/packages/               optional modules (behind interfaces)
src/pools/                  Holder-contract vault + factory
src/ramps/                  Stargate (and other) composers
lab/                        operator console (read-only Recinto + AddressBook)
script/                     deploy and deal scripts
deployments/                addresses, no secrets
test/                       one catalog area per file
```

## Deployments

JSON under `deployments/`. More than one escrow may exist on Sepolia (core-only vs packaged; old vs new pool factory). Point pools at the escrow whose domain you signed. Do not mix ABIs.
