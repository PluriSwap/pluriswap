# PluriSwap / pluriswap — repository audit (Jira hygiene)

**Scope:** `PluriSwap/pluriswap` only (default branch `main` at audit time). Sister repos (`web`, `smarts`, `pluriapi`, `protocol`, `contracts`) were not inspected unless this repo’s docs explicitly name them (they do not).

**Audit date:** 2026-09-14  
**HEAD audited:** `552a5d5` (`feat(kleros): per-chain Kleros wiring, Court-UI-valid template, open/rule-only flow`)  
**Method:** structure map + docs inventory + code/tests/CI cross-check. Confidence labels: **high** = code + tests (+ usually docs); **med** = docs/scripts/deployments without full proof in this pass; **low** = inference / product naming not present in-repo.

---

## Executive summary

1. This repo is the **Solidity protocol + Foundry tests + Sepolia deployments + lab operator console**, not a consumer marketplace or KYC stack.
2. Product shape on-chain: **crypto principal escrowed against off-chain fiat**, closed state machine, roles **Holder / Provider / Controller**.
3. **Core-only** (`packageIds = []`) is constitutional: activate → fund → cancel / mark-fiat / release / claim / dispute / dual-sign / stalemate **without** packages, pool, ramp, or DAO (**high**).
4. **Opt-in packages** (Passport, Reputation, Bonds, ZK, Court) bind via content-addressed `packageId`s; same escrow resolves any compatible impl (**high**). There is **no** in-repo product name “Assured”.
5. Target settlement domain is **Arbitrum** (Sepolia `421614` deployments present); EIP-712 domain `PluriSwap` / `1` (**high**).
6. Maturity: **protocol Core + packages largely implemented and CI-green on `main`**; lab UI exists (`lab/` v0.1.0); **no git version tags / GitHub Releases** found; no `CHANGELOG` / ADRs folder.
7. Remaining protocol gaps called out in-repo: **real ZK verifier** (mocks only), **Kleros Arbitrum One whitelist + policy IPFS pin** (external), **ramp compose→activate** not implemented (taxi-only).
8. Docs are extensive and mostly authoritative, but **some lab/path copy is stale** vs post-2026-09-12 kernel decisions (e.g. `CLAIMED` + completion fee on claim).
9. **Zero Jira / issue keys** appear in this repository; Atlassian text search for “PluriSwap/pluriswap” returned no linked issues from this audit environment.
10. Use this file to cross-check whether Jira still tracks “build Core escrow” as open work (it should not) vs remaining product/ops themes below.

---

## Repo map

```
pluriswap/
├── src/
│   ├── Escrow.sol                 # kernel (state + principal custody)
│   ├── TestToken.sol              # mintable ERC-20 for tests/testnet
│   ├── interfaces/IEscrow.sol     # read surface for packages/pools/ramps
│   ├── libraries/                 # Consent, Terms, Settlement, Clocks, Types,
│   │                              # PackageId, Packages (external package edge)
│   ├── packages/                  # Passport, Reputation, BondVault, ZK, Court (+ mocks)
│   │   └── interfaces/            # IPassport, IReputation, IBondVault, IPaymentProof,
│   │                              # ICourt, IVerifier, Kleros/Gitcoin decoder ifaces
│   ├── pools/                     # Pool + PoolFactory (Holder-as-contract)
│   ├── ramps/                     # StargateV2Ramp, StargateSepolia, MockRamp
│   └── mocks/                     # FoT token, 1271, VerifierMock, Kleros mocks, …
├── test/                          # unit suites (one area per file)
│   ├── fuzz/                      # Kernel, Packages, Pool
│   ├── invariant/                 # EscrowCore, EscrowPackages, Pool
│   └── fork/                      # HumanPassport + Kleros (opt-in via RPC env)
├── script/                        # Deploy + deal/path/Kleros/pool/ramp scripts
├── deployments/                   # Sepolia address JSON (no secrets)
├── lab/                           # Vite/TS/viem operator console (vitest)
├── .github/workflows/ci.yml       # forge + slither + aderyn + lab (+ nightly heavy)
├── lib/                           # forge-std, openzeppelin-contracts (submodules)
└── *.md                           # protocol specs (root; no docs/ until this audit)
```

| Area | Evidence | Notes |
| --- | --- | --- |
| Contracts | `src/**/*.sol` (~34 non-mock files; Escrow ~534 LOC) | No proxy / Ownable / Pausable on settlement (by design) |
| Tests | `test/**/*.sol` — **~328** `test*` functions | Unit + fuzz + invariant + optional fork |
| Scripts | `script/*.s.sol` (17) | Deploy, Paths catalog, Kleros open/close, Pool/Ramp deals |
| Packages / monorepo | Single Foundry root + `lab/` npm package | Not a multi-package Solidity workspace |
| CI | `.github/workflows/ci.yml` | `forge fmt/build/sizes/test`, bytecode margin gate, Slither (fail medium), Aderyn (fail high), lab `npm test`+build; nightly `FOUNDRY_PROFILE=ci` |
| Stack | `foundry.toml` | solc `0.8.28`, Cancun, `via_ir`, OZ v5 submodule |

**Branches observed:** `main`, `lab/console`, `resolve-packages-at-activate` (remote).  
**Recent CI (`main` / schedule):** green as of 2026-09-13/14 (e.g. nightly success). Older workflow name `Mandatory Core CI` (2026-08) had failures; appears superseded by current `ci`.

---

## Implemented features (with file pointers)

### A. Kernel escrow / deals (Core)

| Capability | Status | Confidence | Pointers |
| --- | --- | --- | --- |
| EIP-712 consent (Holder / Provider / Controller) | Implemented | high | `src/libraries/Consent.sol`, `ENCODING.md`, `test/Consent.t.sol` |
| `activate` Core-only (6-arg) and packaged (7-arg + `PackageMods`) | Implemented | high | `src/Escrow.sol`, `test/Activate.t.sol` |
| Exact principal pull; fee-on-transfer rejected | Implemented | high | `src/libraries/Settlement.sol`, `test/Settlement.t.sol` |
| Credit-first terminal payouts + `withdraw` | Implemented | high | `Settlement.sol`, `test/CreditFirst.t.sol` |
| States: `FUNDED` → `FIAT_SENT` / cancel / dual-sign; `DISPUTED`; terminals incl. `CLAIMED` | Implemented | high | `src/libraries/Types.sol`, `STATE_MACHINE.md`, `test/StateMachine.t.sol` |
| Role verbs: `markFiat`, `release`, `cancelByProvider`, `openDisputed` | Implemented | high | `Escrow.sol`, matching `test/*.t.sol` |
| Permissionless: `timeoutFiat`, `claim`, `forceStalemate`, dual-sign relays | Implemented | high | `Escrow.sol` §permissionless / dual-sign; `ARCHITECTURE.md` §3.2 |
| Dual-sign: `mutualCancel`, `coSignedRelease`, `mutualSplit` | Implemented | high | `Escrow.sol`, `test/DualSign.t.sol` |
| Clocks (due / strictly-before) | Implemented | high | `src/libraries/Clocks.sol`, `test/Timeouts.t.sol` |
| No owner / pause on settlement | Implemented | high | `IMPLEMENTATION.md`, constructor `Escrow()` empty of packages |
| Immutable kernel (upgrade = new deploy) | Documented + coded | high | `ARCHITECTURE.md` §8; no proxy usage |

**Product mapping:** P2P crypto↔fiat escrow **Core path is decentralized, permissionless, and trust-minimized** (rules in bytecode; anyone can execute due timeouts). No protocol KYC gate on Core (**high** — no KYC surface in code; optional Passport is a package, not Core).

### B. Packages / modules (“Assured”-like — naming)

| Kind | Official / shipping impl | Lab / mock | Confidence | Pointers |
| --- | --- | --- | --- | --- |
| PASSPORT | `HumanPassport.sol` (Gitcoin/Human Passport decoder) | `PassportMock.sol` | high | `src/packages/HumanPassport.sol`, `test/HumanPassport.t.sol`, fork test |
| REPUTATION | `Reputation.sol` (caps, activation/completion fees, scores) | — | high | `src/packages/Reputation.sol`, `test/Reputation.t.sol` |
| BONDS | `BondVault.sol` (lock / unlock / slash / burn) | — | high | `src/packages/BondVault.sol`, `test/BondVault.t.sol` |
| ZK / payment proof | Interface + `ZkMock` + `VerifierMock` | **no production verifier** | high (mock); low (prod ZK) | `ZkMock.sol`, `mocks/VerifierMock.sol`, `test/Zk.t.sol`; `REVIEW.md` §7 item 4 “Verifier pendiente” |
| COURT | `KlerosAdapter.sol` + `PluriSwapKlerosTemplate.sol` | `ArbitrationMock.sol` | high (adapter); med (mainnet usable) | `KlerosAdapter.sol`, `test/KlerosAdapter.t.sol`, fork; Arbitrum One whitelist called out in README / `PACKAGES.md` §4.1 |

**Resolution:** `PackageId` recompute + peer binding (Rep/Bonds require same Passport) in `src/libraries/Packages.sol` + `PackageId.sol` (**high**). ZK + Arbitration mutually exclusive; Rep without Passport rejected (**high**, tests in `Packages.t.sol`).

**Hypothesis (low):** Product language “Core vs Assured” outside this repo likely maps to **Core-only** vs **packaged** (Passport+Rep±Bonds±Court/ZK). The string `Assured` does **not** appear anywhere in this repository.

### C. Fees / DAO

| Item | Status | Confidence | Pointers |
| --- | --- | --- | --- |
| Activation + completion fees from Reputation `packageId` | Implemented | high | `Packages.completionInvoice`, `Escrow._close` |
| Completion on any Provider payout (incl. `claim` → `CLAIMED`) | Implemented (2026-09-12) | high | `Escrow._close`, `test/Packages.t.sol` CLAIMED cases; `REVIEW.md` §7 |
| Fee > leftover → omit fee (KERNEL-04) | Implemented | high | `Escrow._invoice` |
| DAO as fee *recipient* only (not a package kind) | Spec + code pattern | high | `PACKAGES.md`, feeRecipient in Reputation/ZK |

### D. Disputes / arbitration / timeouts

| Item | Status | Confidence | Pointers |
| --- | --- | --- | --- |
| Core `DISPUTED` + dual-sign exits + `forceStalemate` (bond burn) | Implemented | high | `Escrow.openDisputed` / `forceStalemate`, `STATE_MACHINE.md` CASE-CORE-11..15 |
| `openCourt` / `readRuling` / `forceArbitrationTimeout` | Implemented | high | `Escrow.sol`, `KlerosAdapter.sol` |
| Evidence off-protocol (Kleros Court UI) | Documented + adapter `caseOf` | high | `PACKAGES.md` §4.1, `KLEROS_POLICY.md` |
| Mainnet Kleros whitelist | **External blocker** | high (documented) | README Court section; fork asserts whitelist behavior |

### E. Pools (liquidity Holder)

| Item | Status | Confidence | Pointers |
| --- | --- | --- | --- |
| Share pool as EIP-1271 Holder; authorize / unlock / reconcile / runoff | Implemented | high | `src/pools/Pool.sol`, `PoolFactory.sol`, large `test/Pool.t.sol` |
| Factory + official codehash | Implemented + Sepolia deploy | high | `deployments/sepolia-pool*.json`, `script/DeployPoolFactory.s.sol` |
| NAV / credits / activation-fee reservation | Implemented (REVIEW items marked done) | high | `REVIEW.md` §7 item 5; pool tests |

### F. Ramps (bridge composers)

| Item | Status | Confidence | Pointers |
| --- | --- | --- | --- |
| Stargate V2 taxi `quote` / `send` (0 protocol bps) | Implemented | high | `src/ramps/StargateV2Ramp.sol`, `test/Ramp.t.sol`, `deployments/sepolia-ramp.json` |
| Compose → `activate` in same arrival | Spec only / **not in bytecode** | high (gap) | `RAMPS.md` §4; `REVIEW.md` §3.8; `LAB_UI.md` |

### G. Lab / operator console

| Item | Status | Confidence | Pointers |
| --- | --- | --- | --- |
| Recinto, AddressBook, eligibility matrix, Core→packaged→pool→ramp demos | Present (`lab/` v0.1.0) | high | `lab/README.md`, `LAB_UI.md` PR-1..12 plan |
| CI covers lab vitest + build | Yes | high | `ci.yml` job `lab` |

### H. Product principles vs this repo

| Claim | Repo evidence | Confidence |
| --- | --- | --- |
| Decentralized settlement | No Ownable/Pausable; permissionless timeouts; anyone deploys escrow/packages | high |
| Permissionless | PERM-* invariants in `STATE_MACHINE.md` / `ARCHITECTURE.md`; package publish without registry gate | high |
| Trustless | **Core:** trust-minimized. **Packaged:** parties *choose* Passport/Court/ZK trust (`TRUST-02`) | high |
| No KYC | No KYC/AML modules; optional Human Passport = score/attestation adapter, not identity document KYC | high (protocol); med (product UX lives elsewhere) |
| Fiat off-chain | Explicit in README / ARCHITECTURE; on-chain only crypto principal + proofs/rulings | high |

---

## Documentation quality assessment

### Inventory (root specs — primary)

| Doc | Role | Quality signal |
| --- | --- | --- |
| `README.md` | Entry + stack + Passport/Kleros/deploy notes | Strong, current |
| `ARCHITECTURE.md` | Layers, binding, observability, versioning | Authoritative |
| `STATE_MACHINE.md` | States, CASE-CORE/ARB/PAY, races, invariants | Authoritative (large) |
| `ENCODING.md` | EIP-712 / nonces / dealId | Authoritative |
| `PACKAGES.md` | Package economics + Kleros §4.1 | Authoritative |
| `PROTECTION.md` | Kernel↔package verbs / fees | Present |
| `POOLS.md`, `POOL_IMPL.md`, `POOL_SHARES_IMPL.md` | Pool constitution / impl notes | Present (split depth) |
| `RAMPS.md` | Bridge policy | Present; ahead of compose impl |
| `IMPLEMENTATION.md` | OZ / libraries / bytecode split | Present |
| `PLAN.md` | Historical TDD order (phases 0–11) | Useful archaeology; not a live burndown |
| `TESTNET_PLAN.md` | Stub → “use PLAN.md” | Stale pointer only |
| `REVIEW.md` | 2026-09-08 findings + 09-12/13 closures | High value; some mid-doc narrative still shows pre-fix wording before §7 |
| `KLEROS_POLICY.md` | Juror policy for template URI | Product/legal-ish artifact |
| `LAB_UI.md` | Lab IA + PR plan (very long) | Detailed; **partially stale** vs kernel (see gaps) |
| `lab/README.md` | Operator demos PR-1..12 | Practical |
| Skills | `.cursor/skills/deploy-pool`, `.agents/skills/deploy-pool` | Ops helpers |

**Missing vs typical product repos:** no `docs/` tree before this audit; no ADRs; no `CHANGELOG`; no git tags / GitHub Releases for `0.x` / `0.3.0-rc1` (that version string **was not found** in-repo). NatSpec is selective (libraries/`Packages`/`IEscrow` comments; not full public API encyclopedia).

### Stale / conflicting documentation (evidence)

| Topic | Stale text | Current code |
| --- | --- | --- |
| `CLAIMED` status | `LAB_UI.md` Paths: CASE-CORE-07 → `RELEASED`, “sin completion fee” | `Status.CLAIMED`; `_close` invoices completion when Provider payout > 0 |
| Claim completion | Older REVIEW narrative §3.1 / LAB_UI PATH-TRIO note | Closed in `REVIEW.md` §7; tests assert CLAIMED + fee |
| ZK packageId | Older REVIEW §3.4 “ZK id omits module” | `PackageId.zk(module, verifier, …)` includes module |
| `TESTNET_PLAN.md` | Empty redirect | Use `PLAN.md` / README deployments |

**Overall:** Spec set is unusually strong for a protocol repo (architecture + state machine + encoding). Primary doc risk is **lab/path copy lagging kernel decisions**, not absence of design docs.

---

## Version / release state

| Signal | Finding |
| --- | --- |
| Git tags | **None** (`git tag -l` empty; `git describe` → commit hash only) |
| GitHub Releases | None observed via `gh release list` |
| EIP-712 version | `"PluriSwap"` / `"1"` in `Escrow` constructor |
| Lab npm version | `lab/package.json` → `0.1.0` |
| Claimed `0.3.0-rc1` | **Not present** in this repo (hypothesis: lives in another repo or external roadmap) |
| Deployments | Multiple Arbitrum Sepolia recintos under `deployments/*.json` (core, packages, paths, kleros, pool, ramp) — lab/testnet grade, not a single “production” pin |
| Mainnet readiness | Human Passport path exists for Arbitrum One; Kleros adapter **blocked on Kleros governance whitelist** + `KLEROS_POLICY_URI` pin |
| CI maturity | Current `ci` green on recent `main`; static analysis + bytecode margin gate; nightly heavy fuzz/invariants |

**Maturity verdict (evidence-based):** **late testnet / pre-mainnet protocol** with Core+packages implemented, operator lab in-repo, Sepolia artifacts, and explicit external blockers — not an unscoped prototype, not a tagged production release.

---

## Gaps

### Protocol / product

1. **Production ZK verifier** — only mocks; cannot claim trustless fiat proof release on mainnet (**high** gap).
2. **Kleros Arbitrum One** — adapter must be whitelisted; policy must be IPFS-pinned (**high**, external).
3. **Ramp compose→activate** — documented, not implemented (**high** gap vs `RAMPS.md` ambition; taxi OK for v1).
4. **Sepolia “official” packages** still use PassportMock / VerifierMock / ArbitrationMock in some deploy JSONs — correct for lab, unsafe if marketed as production identity/court (**high**).
5. **Multiple escrow deployments** on Sepolia — ABI/domain mixing risk called out in README (**med** ops hazard).

### Tests / CI

6. Fork tests skipped without `ARBITRUM_RPC_URL` / `ARBITRUM_SEPOLIA_RPC_URL` (nightly sets them; PR forge job does not) — **med**.
7. Historical CI failures under old workflow name — **low** relevance if current `ci` stays green.
8. No broken CI observed on recent `main` in this audit (**high**).

### Docs / process

9. Stale LAB_UI Path economics for claim/CLAIMED (**high** doc debt).
10. `PLAN.md` / `TESTNET_PLAN.md` not a live roadmap; easy to misread as unfinished Core (**med**).
11. No ticket keys / changelog / tags for release communication (**high** process gap for CoS/Jira alignment).

### Explicit TODO/FIXME in Solidity

12. No meaningful production `TODO`/`FIXME` backlog in `src/` (search mostly hits Spanish “todo”, test stubs named `KernelStub`, or Stargate `Ticket` structs). Work is tracked in specs/`REVIEW.md`/`LAB_UI.md` instead.

---

## Ticket / roadmap language found in-repo

### Jira / external trackers

- **No** `PROJ-123`, Jira URLs, Linear URLs, or GitHub issue numbers found in tracked sources.
- Atlassian JQL text search for PluriSwap/pluriswap in the connected site returned **no issues** (may be naming/project mismatch — treat as “not linked from this repo,” not “Jira empty”).

### Internal IDs (use these for hygiene, not as Jira keys)

| Family | Examples | Where |
| --- | --- | --- |
| CASE-CORE-* | `CASE-CORE-01` … `17` | `STATE_MACHINE.md`, `PLAN.md`, lab Paths |
| CASE-ARB-* / CASE-PAY-* / CASE-RACE-* | arbitration / ZK / races | `STATE_MACHINE.md` |
| PERM-*, TRUST-*, EXT-*, KERNEL-*, DEC-* | invariants | `ARCHITECTURE.md`, `STATE_MACHINE.md` |
| OUT-* | terminal outcomes | `STATE_MACHINE.md` / packages docs |
| Lab PR-1..PR-12 | console slices | `LAB_UI.md`, `lab/README.md` |
| REVIEW items 1–7 | gap closure checklist | `REVIEW.md` §7 (mostly **Hecho**; verifier + Kleros external left) |

### Roadmap-ish language

- `PLAN.md`: TDD phases through packages/ramp/pool (historical build order).
- `LAB_UI.md`: open questions Q2/Q3/Q5; “primer slice mergeable = PR-1..3”.
- `REVIEW.md` §7: remaining external Kleros + verifier.
- `RAMPS.md`: ETH “después”; compose optional.

---

## Open questions / unknowns

1. Does product/marketing “Assured” equal packaged Passport+Rep+Bonds(+Court), or a sister-repo SKU? (**unknown in this repo**)
2. Where does version `0.3.0-rc1` (if real) live — another PluriSwap repo, Notion, or outdated brief? (**not found here**)
3. Which Sepolia escrow JSON is the **canonical** demo for CoS demos vs abandoned recintos?
4. Is mainnet launch gated only on Kleros whitelist + real ZK, or also on sister apps (`web` / `pluriapi`)?
5. Are Jira epics named after CASE-CORE / package kinds, or after product journeys (onboard, dispute, pool LP)? (**no keys to verify**)
6. Lab console: is PR-1..12 considered shipped on `main`, or is `lab/console` the integration branch? (commits show lab work merged; remote `lab/console` still exists)

---

## Suggested Jira hygiene (themes the code implies)

Use these as **epic/theme checks** against the backlog. Prefer closing or converting “build X” tickets when evidence shows X is done.

### Likely **Done** (do not keep as open build work without re-scoping)

| Theme | Why |
| --- | --- |
| Core escrow state machine (activate → terminals) | `Escrow.sol` + CASE-CORE tests |
| EIP-712 consent + nonces + dealId | Consent/ENCODING + tests |
| Permissionless timeouts / claim / stalemate | Implemented + tested |
| Dual-sign cancel / release / split | Implemented + tested |
| Package binding / PackageId / peer Passport | `Packages.sol` + Packages tests |
| Reputation fees + BondVault economics | Modules + tests; 2026-09-12 fee/CLAIMED decisions |
| Human Passport adapter | Code + unit + fork |
| Kleros adapter (open/rule/template) on Sepolia | Code + tests + deploy JSON |
| Share pool as Holder + factory | Pool suite + Sepolia factory |
| Stargate taxi ramp | Ramp tests + deploy |
| CI: forge + slither + aderyn + lab | Green recent runs |
| Lab console slices PR-1..12 (as code presence) | `lab/` + README demos — confirm product acceptance separately |

### Should remain **Open** (or be created if missing)

| Theme | Why |
| --- | --- |
| Production ZK verifier + nullifier policy | Explicitly pending in `REVIEW.md` |
| Kleros Arbitrum One whitelist + `KLEROS_POLICY.md` IPFS pin | External dependency |
| Ramp compose→activate (if still a product requirement) | Spec ahead of code |
| Doc sync: LAB_UI Paths vs `CLAIMED`/completion fee | Stale operator/docs risk |
| Release process: tags, changelog, single “blessed” deployment pin | No tags/releases today |
| Mainnet deployment runbook (Passport picker, Kleros env, policy URI) | Scripts exist; ops ticket likely |
| Product KYC stance communication | Protocol has no KYC; clarify vs Passport packaging |
| Sister-repo alignment (web/API indexing of `IEscrow` events) | Out of scope here but needed for end-to-end P2P UX |

### Suggested epic cut (mirrors code layers)

1. **Kernel / Core** — state machine, settlement, clocks  
2. **Packages** — Passport, Reputation, Bonds, ZK, Court  
3. **Pools** — liquidity Holder  
4. **Ramps** — Stargate (taxi vs compose)  
5. **Lab / DX** — console, Paths catalog, deploy skills  
6. **Mainnet readiness** — whitelist, policy pin, verifier, release tagging  
7. **Docs & backlog hygiene** — retire PLAN-as-roadmap; sync LAB_UI; link Jira keys *into* repo only if process requires

### Mapping tip for CoS

If a Jira ticket claims “no permissionless claim” / “no disputes” / “Core needs admin pause” / “KYC in protocol,” treat it as **inaccurate vs this repo** unless it explicitly targets a sister product surface. If a ticket says “Assured package,” require a definition that maps to concrete `packageId` kinds above.

---

## Appendix — evidence quick index

| Need | Start here |
| --- | --- |
| What Core can do | `STATE_MACHINE.md` + `src/Escrow.sol` + `test/HappyPath.t.sol` |
| What packages can do | `PACKAGES.md` + `src/packages/*` + `test/Packages.t.sol` |
| What’s still broken vs spec | `REVIEW.md` §7 (and stale sections above it) |
| What’s deployed on Sepolia | `deployments/*.json` + `lab/README.md` |
| How CI defines “green” | `.github/workflows/ci.yml` + `foundry.toml` `[profile.ci]` |
| Operator UX intent | `LAB_UI.md` (verify claims against code when economics involved) |

*End of audit.*
