# PluriSwap

Permissionless protocol for escrowed crypto against an offchain fiat agreement.

| Document | Path |
| --- | --- |
| Business source of truth | [`PROTOCOL.md`](./PROTOCOL.md) |
| Mandatory Core tech spec | [`docs/v2/technical/MANDATORY_CORE.md`](./docs/v2/technical/MANDATORY_CORE.md) |
| Architecture / immutability | [`docs/superpowers/specs/2026-07-29-core-architecture-immutability-design.md`](./docs/superpowers/specs/2026-07-29-core-architecture-immutability-design.md) |
| Foundry implementation plan | [`docs/superpowers/plans/2026-07-29-mandatory-core-foundry.md`](./docs/superpowers/plans/2026-07-29-mandatory-core-foundry.md) |

## Contracts (Foundry)

Mandatory Core triad (non-upgradeable):

- `src/CoreEscrow.sol` — deal state machine + principal custody
- `src/CreditLedger.sol` — pull credits + deficit recovery
- `src/Coordinator.sol` — module allowlist for future activations

### Setup

```bash
forge install
forge test
forge build --sizes
```

`CoreEscrow` must stay under the EIP-170 24KB runtime limit.

### Deploy (local / Arbitrum)

Per-package credentials live in `deploy.toml` (gitignored). Start from the example:

```bash
cp deploy.toml.example deploy.toml
# edit [core] private_key, rpc_url, hashes, etc.

./deploy.sh --core           # broadcast per deploy.toml
./deploy.sh --core --dry-run # simulate only
```

Each TOML section (`[core]`, later `[bonds]`, …) may use a different wallet. Deploy order uses nonce prediction so `CreditLedger` and `Coordinator` bind the Escrow address before it exists.

### Milestone scope

This Foundry Core milestone implements **Core-only** deals (`profileFlags == 0`). Extension entrypoints exist and revert `ProfileDisabled`. Optional profiles (bonds, proof, arbitration, pools) are separate tech specs / plans.

### Reference home chain

Arbitrum (see `PROTOCOL.md` ECO-007). Core paths are ordinary L2 transactions; bridges are out of Core.
