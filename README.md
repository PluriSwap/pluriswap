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
forge test                       # unit + fuzz (256 runs) + invariants (32 runs x 256 calls)
FOUNDRY_PROFILE=ci forge test    # heavier campaign: fuzz 2048, invariants 128 x 512
```

CI (`.github/workflows/ci.yml`) runs on push and PR: `forge fmt --check`, `forge build --sizes` plus a bytecode-margin gate (Escrow must keep ≥ 1 KB under EIP-170; it sits at ~15.3 KB after moving the package edge to the external `Packages` library), `forge test`, Slither (`slither.config.json`, fails on Medium), Aderyn (`aderyn.toml`, fails on High) and the lab console (vitest + build). A nightly job runs the `ci` profile. Static-analysis exclusions are triaged inline in those config files; the remaining Low findings (zero-address checks, shadowing) are open kernel decisions, not suppressed.

Locally: `uvx --from slither-analyzer slither . --config-file slither.config.json --fail-medium` and `aderyn .`.

Fork tests (`test/fork/`) run only when `ARBITRUM_RPC_URL` is set and check the official Human Passport decoder on Arbitrum One; `HUMAN_WALLET=<address with a live passing score>` adds the positive path. Without the variable they are skipped.

Invariant handlers run with `fail_on_revert = true`: they guard every precondition themselves, so any revert inside a campaign is a kernel finding. Properties live in `test/fuzz/` (stateless) and `test/invariant/` (stateful: Core with a token that rejects pushes, packaged recinto with hostile modules and a Kleros mock, share pool as Holder).

Core-only deals use `packageIds = []`. A packaged deal names `packageId`s and the relayer passes module addresses at `activate`. The same escrow resolves any compatible impl (`ARCHITECTURE.md` §5).

## Layout

```
src/Escrow.sol              kernel
src/interfaces/IEscrow.sol  read surface for packages, pools, ramps
src/libraries/              Consent, Terms, Settlement, Clocks, Types, PackageId, Packages (external: the kernel's package edge)
src/packages/               optional modules (behind interfaces)
src/pools/                  Holder-contract vault + factory
src/ramps/                  Stargate (and other) composers
lab/                        operator console (read-only Recinto + AddressBook)
script/                     deploy and deal scripts
deployments/                addresses, no secrets
test/                       one catalog area per file
test/fuzz/                  stateless properties (kernel, packages, pool)
test/invariant/             stateful handlers + invariants (solvency, conservation, immutability, books)
test/fork/                  Live-chain checks: Human Passport decoder, Kleros core + registry (opt-in via *_RPC_URL)
```

## Identity: Human Passport

The PASSPORT slot ships with `src/packages/HumanPassport.sol`, an adapter over Human Passport's (ex Gitcoin Passport) `GitcoinPassportDecoder`. The decoder scores addresses, so the subject is the wallet with a live passing score (`bytes32(uint160(wallet))`); Sybil resistance is Passport's stamp deduplication. Decoder address and `minScore` (4 decimals, `0` defers to the decoder threshold) are immutable and therefore bound by `PackageId.passport(adapter)`. Any decoder revert (no attestation, expired, paused) reads as `NoPassport`: admission fails closed, live deals are untouched (subjects are snapshotted at activation).

Deploy scripts pick the adapter per chain (`script/PassportPicker.s.sol`): Arbitrum One → `HumanPassport` over `0x2050256A91cbABD7C42465aA0d5325115C1dEB43`; any chain with `PASSPORT_DECODER=<address>` → `HumanPassport` over that decoder (`PASSPORT_MIN_SCORE` optional); otherwise `PassportMock`, a lab tool with an unauthenticated `setHuman`, never a production identity. `src/mocks/PassportDecoderMock.sol` reproduces the decoder's revert surface for tests and test nets (deployer-only writes).

## Court: Kleros V2

The ARB slot ships with `src/packages/KlerosAdapter.sol`. A deal that selected ARBITRATION always enters `DISPUTED` first; the Controller then opens the case (`Escrow.openCourt`, pays `arbitrationCost`). The verdict comes back as `KlerosCore` → `rule`, then anyone calls `Escrow.readRuling`. The three jury outcomes (Holder wins, Provider wins, neither) all close as `RESOLVED_BY_ARBITRATION`; court silence is the same “neither” path. `STALEMATE` remains only if the parties never opened court. Evidence, appeals and votes live in the Kleros Court dapp, which finds the case via `DisputeRequest(externalDisputeID = uint256(dealId))` and fills the dispute template by calling `KlerosAdapter.caseOf`. `script/KlerosConfig.s.sol` holds the per-chain `KlerosCore` / `DisputeTemplateRegistry` addresses with `KLEROS_*` env overrides; `KLEROS_POLICY_URI` (IPFS multiaddr of `KLEROS_POLICY.md`) is required on Arbitrum One. Arbitrum One's core enforces an arbitrable whitelist: the adapter must be listed by Kleros governance before `openCourt` works there. Details in `PACKAGES.md` §4.1.

## Deployments

JSON under `deployments/`. More than one escrow may exist on Sepolia (core-only vs packaged; old vs new pool factory). Point pools at the escrow whose domain you signed. Do not mix ABIs.
