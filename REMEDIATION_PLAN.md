# PluriSwap Mandatory Core Remediation Plan

**Branch:** `fix/mandatory-core-remediation`
**Target:** 0.3.0-rc1 conformance per PROTOCOL.md and MANDATORY_CORE.md
**Date:** 2026-07-31

## Overview

Seven-wave remediation to bring the PluriSwap Mandatory Core smart contracts from
pre-remediation draft to 0.3.0-rc1 conformance. Each wave is executed independently
with build-test-fix cycles.

## Wave Status

| Wave | Description | Status | Current test evidence |
|------|-------------|--------|-----------------------|
| 1 | Foundation: types, libraries, interfaces, stubs | DONE | 40 foundation tests |
| 2 | CreditLedger sole vault with positions and reconciliation | DONE | 64 Ledger + 7 production evidence tests |
| 3 | CoreEscrow tokenless state machine with terminal records | DONE | 68 Escrow tests |
| 4 | CoreDeployer Intent binding and Evidence tooling | DONE | 12 deployer + 2 hash-vector tests |
| 5 | Deficit encoding research (parallel) | DONE | 9 indexed-model tests |
| 6 | Conservative deficit recovery candidate | IN PROGRESS / RELEASE-GATED | 64 Ledger + 5 math + 7 production evidence tests (shared) |
| 7 | Full test suite + conformance rewrite | DONE FOR CORE-ONLY CANDIDATE | 265 full-suite tests |

**Release status:** BLOCKED. Healthy custody hardening, identity validation, and the immutable
per-boundary `type(uint128).max` aggregate nominal limit are implemented. The limit and its
dependency-free proof close the initial wide-boundary precision-collapse blocker and the reachable
zero-history active-source replacement bound. The conservative fixed-point recovery candidate is
not an accepted production encoding until the remaining repeated-checkpoint, saturation,
dust-exhaustion, fairness, differential, governance, and independent-review gates are complete;
the bounded profile/attachment surfaces also require implementation and independent review.

**Current test target:** the full Foundry suite, including exact-token and signature
adversarial coverage.

## Current Conformance Snapshot

- Full Foundry suite: **265 passed, 0 failed**.
- `Coordinator` runtime is **4,643 bytes** and creation code is **4,969 bytes**.
- `CoreEscrow` runtime: **23,540 bytes**, leaving **1,036 bytes** below EIP-170; creation
  code is **24,572 bytes** and its checked creation-code identity is regenerated.
- `CreditLedger` runtime: **18,863 bytes**, leaving **5,713 bytes** below EIP-170;
  creation code is **19,477 bytes** and its checked creation-code identity is regenerated.
- `CoreDeployer` now uses staged child creation; its initcode is **5,925 bytes**, below the
  **49,152-byte EIP-3860** limit. The finalizer creates Ledger / Coordinator / Escrow with
  CREATE nonces 1–3 and validates canonical initcode, exact constructor arguments, and
  reverse links before becoming permanently inert.
- Deployed Core topology: **CoreDeployer plus exactly three children** —
  `CreditLedger`, `Coordinator`, and `CoreEscrow`; no `CoreSettlement` child.
- `forge fmt --check` and `git diff --check`: passing.
- `tools/generate_full_math_vectors.py --check` and the dependency-free
  `tools/check_q128_boundary_bound.py --check`: passing; the latter exhaustively checks 5,952
  initial and 1,124,432 replacement reduced-domain cases plus deterministic production edges.
- Pinned Slither `0.11.6` triage passes with **60 accepted**, **0 new**, and **0 stale**
  fingerprints (1 high, 28 medium, 16 low, 15 informational). Each accepted finding has a
  checked-in reason; naming-only style output is delegated to the production Foundry lint gate.
- Production remains blocked: deficit recovery is implemented only as a release-gated
  candidate pending a ratified precision and fairness policy, and payment-proof, arbitration,
  pool, module, and reservation
  attachment paths remain explicit release-gated surfaces.

---

## Wave 1: Foundation (COMPLETED)

Rewrote all foundational types, libraries, and interfaces per 0.3.0-rc1 spec.

### Changes
- **DealTypes.sol**: New wire IDs (terminal states at 16-21), 8-field ModuleBinding,
  FundingSpec/FundingAuth, TerminalRecord (27 fields), explicit isTerminal membership check,
  typed constants (PositionKind, PoolKind, FundingPurpose, FundingSourceMode,
  OperatorFaultCode, ReconciliationStatus, BoundaryMode, PayoutResultCode)
- **FullMath.sol**: 512-bit mulDiv using OpenZeppelin-style algorithm with Newton-Raphson
  inversion for full-precision settlement math
- **DealHashing.sol**: All new typehashes (DEAL_TERMS with 33 fields, FUNDING_SPEC,
  FUNDING_AUTH, MODULE_BINDING, TERMINAL_RECORD, POSITION_ID_V1, CUSTODY_BOUNDARY)
- **SettlementMath.sol**: Rewritten to use FullMath.mulDiv, added checkedAdd64
- **CoreErrors.sol**: New errors for positions, reconciliation, deficit, manifest, funding,
  terminal records
- **Interfaces**: ICoreEscrow, ICreditLedger, ICoordinator rewritten per spec API direction
- **Stubs**: CoreEscrow, CreditLedger, CoreDeployer with Intent hash placeholder
- **Coordinator.sol**: Full implementation with ModuleBinding-based admission

### Test Files
- `test/DealTypes.t.sol` (8 tests)
- `test/DealHashing.t.sol` (13 tests)
- `test/FullMath.t.sol` (11 tests)
- `test/SettlementMath.t.sol` (8 tests)

---

## Wave 2: CreditLedger Sole Vault (COMPLETED)

Full CreditLedger implementation as the sole physical vault per spec sections 3, 4, 8.2.

### Changes
- **Per-token Boundary struct**: mode (HEALTHY/DEFICIT), accountedAssets,
  nominalOutstanding, quarantinedSurplus, deficitNominalUnits, fixed-point indices,
  generation/history checkpoint, precision-floor flag, and observable rounding dust
- **Position model**: Deterministic IDs via DealHashing.positionId, token field for
  permissionless withdrawals, tombstones for consumed positions, queryable canonical
  terminal-hash provenance plus compact frozen replacement gap / bounded rounding-dust state on
  consumed settlement sources, and an O(1) typed `PositionView` / `DeficitComponents`
  materialization preserving stored nominal and unpaid nominal separately
- **Reconciliation protocol**: 5 statuses (Unchanged, SurplusQuarantined,
  QuarantineLossAbsorbed, DeficitCheckpointed, ReservedInvalid)
- **fundDealAndReservations**: WALLET_PULL (exact-pull from source) and LEDGER_POSITION
  (debit from existing matured position) funding modes
- **Boundary exposure safety**: expose
  `MAX_BOUNDARY_NOMINAL = type(uint128).max`; after all applicable funding request/auth/source
  validation and before any funding leg or nonce/accounting effect, sum all principal/fee
  WALLET_PULL nominal units with checked/saturating arithmetic and atomically reject
  current-plus-added overflow through typed `BoundaryNominalLimitExceeded` data; same-Ledger
  reassignment contributes zero and token boundaries remain independent
- **Terminal planning**: Retain semantic holder/provider/fee amounts in TerminalRecord while
  coalescing equal beneficiaries into one final allocation and deterministic position ID;
  the pure planner is exposed by Coordinator and Ledger remains custody-only
- **settleDealAndReservations**: Consume the deal position, persist its canonical terminal
  hash, emit final-nominal consumption/settlement events, reject duplicate/existing targets,
  and create each pre-coalesced terminal position exactly once
- **withdrawPosition / withdrawPositionTo**: Permissionless withdrawals, signed
  alternate receiver via PositionPayoutAuth
- **checkpointBoundary**: Permissionless deficit entry
- **Deficit recovery candidate**: recovery deposits and direct/signed claims use the
  release-gated conservative fixed-point policy described in Wave 6 below.

### Test File
- `test/CreditLedger.t.sol` (64 tests): funding, settlement, terminal provenance,
  reconciliation-only immutability, coalescing, withdrawal, deficit entry, canonical component
  views including immutable replacement tombstones, position collisions, and exact cap /
  aggregate crossing / mixed-source / token independence / uint256 extreme / one-unit-loss
  boundary vectors
- `test/CreditLedgerRecoveryDifferential.t.sol` (7 tests): exact and non-integral
  production-Ledger differential sequences including explicit pre-existing-error/split-dust
  decomposition, bounded/no-capture replacement-dust fuzzing, malformed-sum and over-count
  rollback, and matched cold/warm O(1) view gas-growth regression

---

## Wave 3: CoreEscrow Tokenless State Machine (COMPLETED)

Full CoreEscrow implementation as a tokenless state machine per spec sections 8, 9, 10.

### Changes
- **Tokenless**: Never imports IERC20 or touches tokens; all custody via Ledger
- **activate**: Verify party EIP-712 signatures (Escrow domain), funding spec hashes,
  custody boundary verification, Core-only field validation (profileFlags=0, all
  optional hash fields zero), call ledger.fundDealAndReservations
- **State transitions** (all 8 Core cases):
  - markFiatSent (CASE-CORE-002): provider-only, FUNDED to FIAT_SENT
  - providerCancel (CASE-CORE-004): provider-only, returns principal holder-side
  - fiatTimeoutCancel (CASE-CORE-005): permissionless, after fiatDeadline
  - holderRelease (CASE-CORE-007): holder-only, FIAT_SENT to RELEASED
  - claim (CASE-CORE-009): permissionless, after releaseDeadline
  - openDispute (CASE-CORE-021): holder-only, strictly before releaseDeadline
  - disputeTimeout (CASE-CORE-025): permissionless, after disputeDeadline
  - mutualResolve: dual-signed cancel/release/split with ResolutionAuth verification
- **Timing origins**: Activation derives fiat and prechecks release-plus-dispute arithmetic from
  its current origin; mark-fiat and dispute opening validate their actual later origins before
  state change. At a representable timestamp, downstream mark-fiat overflow leaves `FUNDED`
  unchanged and a still-representable fiat-timeout settlement remains available. Once
  `block.timestamp` exceeds `type(uint64).max`, every timestamp-writing action rejects and no
  timeout-liveness claim remains.
- **Settlement math**: SettlementMath.split (mulDiv-based) + completionCollected
  (min(completionFee, providerGross))
- **TerminalRecord**: 27-field struct with terminalHash via DealHashing.hashTerminalRecord
- **Mutual terminal evidence**: Core computes `DealHashing.hashResolution(auth)` once, reuses
  it for the signature digest, and stores that exact struct hash as terminal evidence; all
  deterministic unilateral/Core-timeout outcomes retain zero evidence
- **Terminal timestamp**: Core checked-casts `block.timestamp` to `uint64` before planning;
  overflow reverts with no Core terminal or Ledger tombstone mutation
- **Extension stubs**: submitPaymentProof, openArbitration, submitArbitrationRuling,
  arbitrationTimeout all revert ProfileNotSelected (Core-only)

### Test File
- `test/CoreEscrow.t.sol` (68 tests): all Core transitions, rejection edges, settlement
  math, dispute paths, mutual resolve, terminal records, coalesced events, timestamp overflow

### Size Resolution
Settlement planning is now a pure Coordinator operation, with the Ledger remaining
custody-only. CoreEscrow remains below the EIP-170 limit while the deployed child topology
remains exactly Ledger / Coordinator / Escrow.

---

## Wave 4: CoreDeployer Intent and Evidence (COMPLETED)

Immutable deployment Intent hash computation and off-chain Evidence hashing per spec section 13.

### Changes
- **CoreDeploymentIntentV1 / CoreDeploymentEvidenceV1**: Separate on-chain deployment
  preimages from off-chain build, verification, and transaction evidence
- **Intent constants**: INTENT_SCHEMA_ID and EVIDENCE_SCHEMA_ID
- **ManifestHashing**: Computes `intentHash` and `evidenceHash` from canonical ABI encodings
- **CoreDeployer**: Predicts all triad addresses via CREATE nonces, computes
  `intentHash` before deploying CoreEscrow, passes it to the Escrow constructor,
  stores chainId/protocolVersion/charterHash/techSpecHash as immutables
- **IntentComputed event**: Emitted at construction for off-chain verification
- **Deploy script**: Updated with env-var-driven Intent preimage fields

### Test File
- `test/CoreEscrow.t.sol` (5 identity tests): non-zero hash, matches escrow,
  deterministic, differs for different charter, identity fields stored

---

## Wave 5: Deficit Encoding Research (COMPLETED)

Research and prove an O(1) deficit encoding that allows pro-rata recovery from deficit
positions without per-position storage.

### Problem Statement
When a token issuer loses value (e.g., stablecoin depegs), the ledger's actual assets
fall below nominal outstanding liabilities. The boundary enters DEFICIT mode (irreversible).
In DEFICIT:
- New exposure is rejected
- Healthy withdrawals return DEFICIT_CLAIM_REQUIRED
- Recovery deposits can be made via depositRecovery
- Position holders claim pro-rata shares of recovered assets

### Key Constraints (from spec section 4)
- Deficit entry, sync, loss, recovery, claim, and terminal reassignment MUST each be
  O(1), independent of position count and checkpoint history
- DEFICIT is irreversible; full refill does not restore HEALTHY
- Claim order among positions at the same checkpoint cannot change exact funded
  entitlement
- Multiple loss checkpoints can occur (appended, not replaced)
- Recovery above aggregate gap rejects atomically
- ReferenceRecoveryModel.sol must agree with implementation on all vectors

### Research Finding
The proposed cumulative-recovery scalar is **disproven**. It cannot apply a later issuer
loss only to then-unpaid funded entitlement after asymmetric claims. Updating the scalar
either claws back prior payments or redistributes the remaining assets incorrectly.

The best abstract O(1) encoding is a lazy affine checkpoint over each position's unpaid
funded/gap components. For unpaid units `u`, the position gap is represented as:

```
gap = a * u + s * h
funded = u - gap
```

`a` and `s` are boundary-wide exact rational indices; `h` is position-local state. Loss
and recovery checkpoints compose `a` and `s` in O(1). Claims update only the claimed
position's paid amount and `h`. Full loss and full recovery are singular checkpoints that
start a new generation with all unpaid value respectively in gap or funded entitlement.
Terminal reassignment scales `h` by each child's nominal share.

This encoding is mathematically equivalent to the reference model with arbitrary-precision
rationals. It is not exactly representable in a fixed number of Solidity words for an
unbounded alternating checkpoint history: a valid four-unit sequence can grow a reduced
denominator as `4^m` without reaching a singular reset. `FullMath.mulDiv` cannot preserve
those chained fractions.

### Approved Wave 5 Research Harness

1. Implement a test-only `IndexedRecoveryModel` using bounded exact rationals.
2. Differential-test every position component and payout against
   `ReferenceRecoveryModel` for entry, loss, recovery, partial claims, full loss/recovery,
   terminal splits, dust, and claim-order permutations.
3. Add an adversarial denominator-growth vector proving why the exact harness cannot be
   copied directly into fixed-width production storage.
4. Keep production `CreditLedger` unchanged until the harness passes and the fixed-width
   precision policy is explicitly selected.

### Acceptance Gate
Implementation must pass all ReferenceRecoveryModel.t.sol differential vectors
(section 15.2) before being accepted as production deficit encoding.

### Result
- Added `test/helpers/IndexedRecoveryModel.sol`, an exact affine O(1) research model.
- Added `test/IndexedRecoveryModel.t.sol` with 9 differential/domain vectors.
- Proved equivalence for every shared accepted entry, loss, recovery, claim, split, dust,
  and claim-order vector.
- Proved safe pre-mutation index exhaustion after 59 alternating recovery/loss cycles
  while the iterative oracle can continue.
- Wave 6 remains blocked because issuer-loss reconciliation cannot safely reject when a
  fixed-width production index exhausts.

---

## Wave 6: Conservative Deficit Recovery Candidate (RELEASE-GATED)

The exact-rational Wave 5 harness remains the semantic reference. The branch now contains
an O(1) Solidity candidate selected for the accepted conservative tradeoff: it may leave
bounded boundary dust, but it never overpays, claws back a completed claim, or allows a
last claimant to capture the residual balance.

### Closed scoped blockers: initial precision collapse and active-source replacement

`MAX_BOUNDARY_NOMINAL = 2^128 - 1` now limits each
`(chain, version, Ledger, token)` boundary while leaving token and position fields as `uint256`.
For initial exact loss `L`, nominal `N`, scale `S = 2^128`, coefficient
`a = ceil(L*S/N)`, and one-position materialized gap `G = ceil(a*N/S)`,
`N <= S - 1` proves `0 <= G - L <= 1`. The maximum-boundary one-unit loss therefore
materializes two gap units, `MAX_BOUNDARY_NOMINAL - 2` funded units, and exactly one unit of
stored `deficitRoundingDust` against `MAX_BOUNDARY_NOMINAL - 1` assets, instead of the prior
`uint256.max` boundary's `2^128` gap units.

Active `DEAL` and `RESERVATION` sources are nonclaimable and are enforced to have zero paid assets
and zero local history before replacement. Children inherit the current global gap coefficient
with zero local history. For one to three positive children, the ceiling-partition inequality
proves exact nominal/paid conservation and `0 <= replacementRoundingDust <= childCount - 1`; the
runtime retains the lower-side conservative guard and an upper bound of at most two units.
`docs/security/Q128_BOUNDARY_BOUND.md` derives the result and
`tools/check_q128_boundary_bound.py --check` verifies deterministic production edges,
admission arithmetic, the removed regression, reachable replacement partitions, and exhaustive
reduced domains.

These scoped proofs do not approve the complete Q128 model.

### Remaining blocker

The technical specification and governance process must still ratify the complete production
policy.
The candidate uses:

- Q128.128 boundary indices for the gap coefficient and history scale;
- upward rounding for gap, downward rounding for funded entitlement, and exact token deltas;
- conservative child-sum replacement snapshots with explicit dust bounded by
  `childCount - 1`;
- saturating history/index arithmetic that records a non-reverting precision floor;
- status `4` as a persistent reconciliation-only transition that blocks new exposure; and
- an observable boundary rounding-dust reserve with no privileged recipient.

The remaining release gate is to formally select and evidence this policy, or replace it with
another approved policy:

1. explicit rational/checkpoint bounds with defined exhaustion behavior; or
2. conservative fixed-point indices with a normative error bound, dust behavior, and
   revised differential acceptance criteria.

Issuer-loss reconciliation cannot safely revert merely because an exact rational index no
longer fits fixed-width storage. Integrating the disproven cumulative scalar or an
unspecified approximation would violate TOKEN-017 through TOKEN-019.

### Changes
- Implement `depositRecovery`: exact-pull attributable recovery, with status `4` returned
  without consuming the deposit when a new loss is first checkpointed.
- Implement `claimRecovery`: conservative pro-rata payable, exact push, and position/boundary
  accounting with no action nonce.
- Implement `claimRecoveryTo`: signed alternate receiver using payout action `2`, consuming
  its purpose-namespaced nonce only after a positive payment.
- Update `_reconcile` to append loss checkpoints in irreversible DEFICIT mode.
- Refresh first-entry rounding dust before checkpoint identity derivation; emit `DeficitEntered`
  only for `HEALTHY -> DEFICIT`, and emit the complete typed `LossCheckpointed` snapshot after
  `BoundaryReconciled` for every later status-`4` loss.
- Preserve `DEFICIT_CLAIM_REQUIRED` for the healthy withdrawal surface.
- Update preflight and funding to return status `4` with no new exposure.
- Enforce the per-token boundary cap before the first funding leg, including aggregate
  principal-plus-fee overflow, later funding against existing exposure, mixed source modes,
  exact-cap same-vault reassignment, reusable nonces, and independent token boundaries.
- Allow terminal reassignment in an existing deficit without changing boundary nominal units.
- Enforce zero paid assets and zero local history on nonclaimable active sources; remove unreachable
  parent-history scaling/saturation and create children at the current global coefficient with
  zero local history.
- Preserve explicit settlement-parent replacement tombstones with compact frozen child-sum gap
  plus packed `uint8 replacementRoundingDust`; derive funded value from stored nominal while
  children evolve, and reject more than three final deal children before reconciliation/mutation.
- Add production tests for partial/full recovery, repeated loss after payment, full-generation
  reset, over-recovery, reconciliation-only retry, and deficit settlement.
- Drive the production Ledger and exact rational reference model through the same deterministic
  entry/claim/recovery/repeated-loss/split sequence and compare every component and payout.
- Exercise non-integral production/reference splits where independent Q128 upward rounding shifts
  funded value into gap, including the explicit `nominal=3/assets=2/children=1/1/1` vector;
  distinguish pre-existing boundary representation error and require the entire split-induced
  divergence to equal reported replacement dust with no double counting.
- Prove by arithmetic and production fuzzing over one to three children that zero-history
  coefficient split divergence is at most `childCount - 1`, every successful split is conservative,
  both dust identities hold, and aggregate claims cannot capture dust.
- Pack Boundary mode/precision and Position token/kind/lifecycle/dust fields without changing the
  public ABI; remove dead/redundant settlement, checkpoint, signature, token, and payout helpers,
  and return precise amount/allocation/nonclaimable errors.
- Regress `getPosition` gas under matched cold/warm access after 2 versus 32 positions and 1
  versus 17 deficit checkpoints, with a 3,000-gas iteration-detecting tolerance.

### Wave 6 acceptance gate

The candidate is not production-approved until all of the following are complete:

1. Differential and adversarial tests demonstrate the conservative invariant envelope against
   `ReferenceRecoveryModel` for claims, splits, dust, permutations, repeated losses, and
   denominator/index saturation.
2. Governance ratifies the Q128.128 precision floor, dust ownership, recovery exhaustion,
   and fairness rules in the business specification.
3. Independent security and economic reviews confirm that rounding cannot overpay, claw back,
   or create order-capture incentives.
4. Deployment manifests and canary evidence identify the exact recovery policy version.

The capability/manifest preimage must also commit
`maxBoundaryNominal == type(uint128).max` and match the live Ledger getter. This records the
closed narrow bound without representing the remaining Q128 gates as complete.

Until then, the source implementation is a review candidate only; no production deployment
or production-readiness label is permitted.
- Differential testing against ReferenceRecoveryModel

---

## Wave 7: Full Test Suite + Conformance Rewrite (IN PROGRESS)

Final conformance pass to verify all spec sections are covered.

### Contract topology and size remediation (COMPLETED FOR CURRENT CORE-ONLY CANDIDATE)
- Removed the deployed `CoreSettlement` child and kept the CoreDeployer child order at
  Ledger / Coordinator / Escrow nonces 1-3.
- Settlement planning is exposed as a pure Coordinator operation; the Ledger is custody-only
  and only Core can supply authenticated terminal evidence.
- Current `CoreEscrow` runtime is 23,540 bytes, 1,036 bytes below the 24,576-byte EIP-170
  limit.
- CoreDeployer now rejects placeholder Intent inputs and verifies reverse links.
- CoreDeployer deployment is now two-phase: CoreDeployer creation followed by one authorized,
  atomic triad-finalization transaction. Deployment Evidence records both transactions.

### Changes
- Conformance matrix: verify every spec section has corresponding tests
- Edge cases: dust handling, claim order independence, repeated loss, partial claim
- Integration tests: full deal lifecycle through Escrow + Ledger
- Gas reporting for all transitions
- Contract size verification (current Core-only candidate is below the EIP-170 limit)
- Selector and event signature verification
- Invariant testing (section 14)
- Conformance record (section 25)

---

## Architecture Decisions

1. **Full rewrite vs phased**: Full rewrite now (breaks all signatures)
2. **Deficit encoding**: Research-first, followed by a conservative Q128.128 candidate;
   production acceptance remains gated on policy ratification and differential evidence
3. **Module dispatch**: Deferred to later (Core-only in Phase 1)
4. **Deployment Intent/Evidence**: Included in Phase 1 (Wave 4)
5. **EVM version**: Shanghai (enables PUSH0 for smaller bytecode)
6. **Optimizer**: runs=1 (minimize bytecode size)
7. **via_ir**: true (Yul-based optimizer enabled)

## File Inventory

### Source Files
```
src/
  CoreEscrow.sol        - Tokenless state machine (Wave 3)
  CreditLedger.sol      - Sole vault with positions (Wave 2)
  CoreDeployer.sol      - Triad deployment + Intent binding (Wave 4)
  Coordinator.sol       - Module admission registry (Wave 1)
  interfaces/
    ICoreEscrow.sol     - Escrow interface (Wave 1)
    ICreditLedger.sol   - Ledger interface (Wave 1)
    ICoordinator.sol    - Coordinator interface (Wave 1)
    IERC20.sol           - ERC20 interface
    IERC1271.sol         - ERC-1271 signature interface
  libraries/
    DealTypes.sol       - All types, constants, structs (Wave 1+4)
    DealHashing.sol     - EIP-712 hashing (Wave 1+4)
    FullMath.sol        - 512-bit mulDiv (Wave 1)
    SettlementMath.sol  - Settlement calculations (Wave 1)
    CoreErrors.sol      - Custom errors (Wave 1)
    ExactERC20.sol      - Exact transfer helpers
    DeficitMath.sol     - Conservative fixed-point deficit arithmetic (release-gated)
    SignatureValidation.sol - Shared EOA/ERC-1271/EIP-2098 verification
```

### Test Files
```
test/
  DealTypes.t.sol           - 8 tests (Wave 1)
  DealHashing.t.sol         - 13 tests (Wave 1)
  FullMath.t.sol            - 11 tests (Wave 1)
  SettlementMath.t.sol      - 8 tests (Wave 1)
  CreditLedger.t.sol        - 64 tests (Wave 2+6 candidate + boundary cap)
  CreditLedgerRecoveryDifferential.t.sol - 12 tests (differential + dust fuzz + rollback + O(1) gas)
  DeficitMath.t.sol         - 5 tests (Wave 6 arithmetic + reachable split bound/edge fuzz)
  CoreEscrow.t.sol          - 68 tests (Wave 3+4+7)
  CoreDeployer.t.sol        - 12 tests (Wave 4+7)
  Coordinator.t.sol         - 3 tests (Wave 7)
  ExactERC20.t.sol          - 7 tests (Wave 7)
  SignatureValidation.t.sol - 5 tests (Wave 7)
  ReferenceRecoveryModel.t.sol - 11 tests (pre-existing)
  IndexedRecoveryModel.t.sol - 9 tests (Wave 5)
  LiveChain.t.sol           - 12 tests (live-chain identity)
  CanonicalEvents.t.sol     - 4 tests (event payload/cardinality checks)
  DeadlineRaces.t.sol       - 5 tests (boundary timestamp checks)
  HashVectors.t.sol         - 2 tests (independent Intent/Evidence vectors)
  StatusFourMatrix.t.sol    - 5 tests (status-four no-effect retries)
  TerminalPlanning.t.sol    - 1 test (pure planner/coalescing)
  Total                     - 265 tests
  vectors/
    FullMathVectors.sol     - Generated independent mulDiv vectors
  helpers/
    MockERC20.sol
    FeeOnTransferToken.sol
    RevertingReceiver.sol
    ReferenceRecoveryModel.sol
    IndexedRecoveryModel.sol
```

### Tooling Files
```
tools/
  generate_full_math_vectors.py - Independent FullMath vector generator
  check_q128_boundary_bound.py  - Dependency-free initial Q128 boundary proof checker
docs/security/
  Q128_BOUNDARY_BOUND.md        - Initial single-position bound and explicit remaining gates
```
