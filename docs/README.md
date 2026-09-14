# PluriSwap documentation

PluriSwap is a **peer-to-peer crypto↔fiat escrow**: on-chain principal (ERC-20) against an off-chain fiat payment. The Core is a closed state machine with three roles — Holder, Provider, Controller — that anyone can use without permission. Packages, pools, and ramps are opt-in and live outside that machine. The protocol does **not** require KYC; identity modules (e.g. Human Passport) are optional packages parties choose when they open a deal.

This folder is the documentation home for the repository. Specs here are the source of truth for protocol behavior. Root-level `*.md` files of the same names are short stubs that point here so old links keep working.

---

## How to read these docs

Suggested order for a new reader:

1. **[ARCHITECTURE.md](ARCHITECTURE.md)** — layers, what is kernel vs opt-in, `packageId` binding, observability.
2. **[STATE_MACHINE.md](STATE_MACHINE.md)** — states, transitions, outcomes, clocks, Core catalog.
3. **[ENCODING.md](ENCODING.md)** — EIP-712 typed data, nonces, `dealId`.
4. **[PACKAGES.md](PACKAGES.md)** and **[PROTECTION.md](PROTECTION.md)** — optional modules and how the kernel calls them.
5. **[POOLS.md](POOLS.md)** / **[RAMPS.md](RAMPS.md)** — liquidity vaults as Holder; bridge composers.
6. **[IMPLEMENTATION.md](IMPLEMENTATION.md)** — libraries, OpenZeppelin, bytecode split.

Conflict resolution (unchanged from before): states/economy → `STATE_MACHINE.md` / `PACKAGES.md`. Layering/binding → `ARCHITECTURE.md`.

---

## Normative specs

These documents freeze protocol behavior. Prefer them over code comments, lab notes, or historical plans when something disagrees.

| Doc | What it freezes |
| --- | --- |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Layers, interfaces, `packageId` resolution, observability |
| [STATE_MACHINE.md](STATE_MACHINE.md) | States, transitions, outcomes, clocks |
| [ENCODING.md](ENCODING.md) | EIP-712 typed data, nonces, `dealId` |
| [PACKAGES.md](PACKAGES.md) | Reputation, bonds, ZK, arbitration formulas |
| [PROTECTION.md](PROTECTION.md) | Kernel → package verbs, fees, DAO as recipient |
| [POOLS.md](POOLS.md) | Vault as Holder (EIP-1271), shares, sponsors |
| [RAMPS.md](RAMPS.md) | Bridge composers, zero protocol bps |
| [IMPLEMENTATION.md](IMPLEMENTATION.md) | Libraries, OpenZeppelin, bytecode split |
| [KLEROS_POLICY.md](KLEROS_POLICY.md) | Juror-facing arbitration policy (`policyURI` / IPFS) |

### Implementation notes (normative for their subject, not the Core graph)

| Doc | Notes |
| --- | --- |
| [POOL_SHARES_IMPL.md](POOL_SHARES_IMPL.md) | Shares vault implementation notes |
| [POOL_IMPL.md](POOL_IMPL.md) | Superseded cut; see `POOL_SHARES_IMPL.md` |

---

## Historical / ops (not normative)

These are useful for context and operators. They do **not** override the specs above.

| Doc | Notes |
| --- | --- |
| [PLAN.md](PLAN.md) | TDD / implementation order (historical) |
| [TESTNET_PLAN.md](TESTNET_PLAN.md) | Absorbed by `PLAN.md` |
| [REVIEW.md](REVIEW.md) | Snapshot of Core-vs-modules gaps (dated review) |
| [LAB_UI.md](LAB_UI.md) | Lab console information architecture. May be partially stale relative to later Core decisions (e.g. `CLAIMED`, completion fee); trust `STATE_MACHINE.md` / `PACKAGES.md` on conflict. |

For the lab app itself, see also [`lab/README.md`](../lab/README.md).

---

## Table of contents

- [ARCHITECTURE.md](ARCHITECTURE.md)
- [STATE_MACHINE.md](STATE_MACHINE.md)
- [ENCODING.md](ENCODING.md)
- [PACKAGES.md](PACKAGES.md)
- [PROTECTION.md](PROTECTION.md)
- [POOLS.md](POOLS.md)
- [POOL_SHARES_IMPL.md](POOL_SHARES_IMPL.md)
- [POOL_IMPL.md](POOL_IMPL.md)
- [RAMPS.md](RAMPS.md)
- [IMPLEMENTATION.md](IMPLEMENTATION.md)
- [KLEROS_POLICY.md](KLEROS_POLICY.md)
- [PLAN.md](PLAN.md)
- [TESTNET_PLAN.md](TESTNET_PLAN.md)
- [REVIEW.md](REVIEW.md)
- [LAB_UI.md](LAB_UI.md)
