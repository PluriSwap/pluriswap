# PluriSwap

Permissionless protocol for escrowed crypto against an offchain fiat agreement.

| Document | Path |
| --- | --- |
| Business source of truth | [`PROTOCOL.md`](./PROTOCOL.md) |
| Mandatory Core tech spec | [`docs/v2/technical/MANDATORY_CORE.md`](./docs/v2/technical/MANDATORY_CORE.md) |
| Architecture / immutability | [`docs/superpowers/specs/2026-07-29-core-architecture-immutability-design.md`](./docs/superpowers/specs/2026-07-29-core-architecture-immutability-design.md) |
| Superseded historical Foundry plan | [`docs/superpowers/plans/2026-07-29-mandatory-core-foundry.md`](./docs/superpowers/plans/2026-07-29-mandatory-core-foundry.md) |

> **Production-remediation status:** the governing documents above define the `0.3.0-rc1` candidate. The current Solidity implementation and tests are experimental, pre-remediation evidence and are not production-conforming until the sole-vault, checkpoint, reservation, module, terminal-record, and manifest requirements are implemented and verified.

## Current prototype files and target roles

The repository currently contains experimental pre-remediation contracts at the target paths below. Their intended production roles are:

- `src/CoreEscrow.sol` — target tokenless consent, timing, module-dispatch, and deal state machine
- `src/CreditLedger.sol` — target sole physical vault for active principal, fee/reservation positions, matured credits, withdrawals, and deficit recovery
- `src/Coordinator.sol` — target module-admission registry for future activations

`src/CoreDeployer.sol` is mandatory target deployment infrastructure that creates/cross-binds the triad; it is not a fourth Core contract and has no post-deployment authority. File presence or a passing prototype test does not establish conformance with the governing documents.

### Setup

```bash
forge install
forge test
forge build --sizes
```

`CoreEscrow` must stay under the EIP-170 24KB runtime limit.

### Current prototype deploy workflow (local / Arbitrum)

Per-package credentials live in `deploy.toml` (gitignored). Start from the example:

```bash
cp deploy.toml.example deploy.toml
# edit [core] private_key, rpc_url, hashes, etc.

./deploy.sh --core           # broadcast per deploy.toml
./deploy.sh --core --dry-run # simulate only
```

Each TOML section (`[core]`, later `[bonds]`, …) may use a different wallet.

The current script uses **CREATE2** for `CoreDeployer`, which then CREATE-deploys Ledger / Coordinator / Escrow. A CREATE2 address is deterministic only for the exact factory address, salt, and complete CoreDeployer initcode hash; each child address additionally depends on the actual CoreDeployer address and exact CREATE nonce/order. Because constructor/initcode preimages can bind chain, version, documents, configuration, and dependencies—and factory addresses can differ—reusing a human-readable salt alone does **not** imply equal addresses across chains. Cross-chain address equality occurs only when every relevant preimage and deployer/factory address also matches.

This script remains prototype tooling until it emits and verifies the mandatory `0.3.0-rc1` ABI manifest and all CoreDeployer/child preimages required by the technical specification.

### Milestone scope

The active milestone is production remediation toward the `0.3.0-rc1` authorities. Core-only deals remain the minimum complete path, while production Mandatory Core must also ship the generic bounded attachment surface, pool-authority/reservation slots, and functional named payment-proof and arbitration edges. Profile internals remain separate specifications.

Any current `ProfileDisabled`/`ProfileNotImplemented` behavior is an experimental implementation gap, not a permanent Core design claim. A deployment retaining unconditional extension stubs or Escrow-held principal is non-conforming and must not be presented as production-ready.

### Reference home chain

Arbitrum (see `PROTOCOL.md` ECO-007). Core paths are ordinary L2 transactions; bridges are out of Core.
