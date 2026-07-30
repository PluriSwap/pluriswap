# PluriSwap Mandatory Core Remediation Plan

**Branch:** `feat/mandatory-core-foundry`
**Target:** 0.3.0-rc1 conformance per PROTOCOL.md and MANDATORY_CORE.md
**Date:** 2026-07-30

## Overview

Seven-wave remediation to bring the PluriSwap Mandatory Core smart contracts from
pre-remediation draft to 0.3.0-rc1 conformance. Each wave is committed independently
with build-test-fix cycles.

## Wave Status

| Wave | Description | Status | Tests |
|------|-------------|--------|-------|
| 1 | Foundation: types, libraries, interfaces, stubs | DONE | 33 |
| 2 | CreditLedger sole vault with positions and reconciliation | DONE | 13 |
| 3 | CoreEscrow tokenless state machine with terminal records | DONE | 37 |
| 4 | CoreDeployer manifest emission and verification | DONE | 5 |
| 5 | Deficit encoding research (parallel) | DONE | 9 |
| 6 | Integrate proven deficit encoding | BLOCKED | - |
| 7 | Full test suite + conformance rewrite | IN PROGRESS | ongoing |

**Release status:** BLOCKED. Healthy custody hardening and identity validation are implemented,
but deficit recovery remains intentionally disabled and the bounded profile/attachment
surfaces still require implementation and independent review.

**Current test target:** the full Foundry suite, including exact-token and signature
adversarial coverage.

## Current Conformance Snapshot

- Full Foundry suite: **134 passed, 0 failed**.
- `CoreEscrow` runtime: **24,517 bytes**, leaving **59 bytes** below EIP-170.
- Deployed Core topology: **CoreDeployer plus exactly three children** —
  `CreditLedger`, `Coordinator`, and `CoreEscrow`; no `CoreSettlement` child.
- `forge fmt --check` and `git diff --check`: passing.
- Static-analysis CI is configured with Slither; the local environment does not have
  Slither installed, so that gate remains CI evidence rather than a local result.
- Production remains blocked: deficit recovery is disabled pending a ratified precision
  and fairness policy, and payment-proof, arbitration, pool, module, and reservation
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
- **Stubs**: CoreEscrow, CreditLedger, CoreDeployer with manifestHash placeholder
- **Coordinator.sol**: Full implementation with ModuleBinding-based admission

### Test Files
- `test/DealTypes.t.sol` (7 tests)
- `test/DealHashing.t.sol` (12 tests)
- `test/FullMath.t.sol` (6 tests)
- `test/SettlementMath.t.sol` (8 tests)

---

## Wave 2: CreditLedger Sole Vault (COMPLETED)

Full CreditLedger implementation as the sole physical vault per spec sections 3, 4, 8.2.

### Changes
- **Per-token Boundary struct**: mode (HEALTHY/DEFICIT), accountedAssets,
  nominalOutstanding, quarantinedSurplus, deficitNominalUnits
- **Position model**: Deterministic IDs via DealHashing.positionId, token field for
  permissionless withdrawals, tombstones for consumed positions
- **Reconciliation protocol**: 5 statuses (Unchanged, SurplusQuarantined,
  QuarantineLossAbsorbed, DeficitCheckpointed, ReservedInvalid)
- **fundDealAndReservations**: WALLET_PULL (exact-pull from source) and LEDGER_POSITION
  (debit from existing matured position) funding modes
- **settleDealAndReservations**: Consume deal position, coalesce equal beneficiaries,
  create terminal positions with deterministic IDs
- **withdrawPosition / withdrawPositionTo**: Permissionless withdrawals, signed
  alternate receiver via PositionPayoutAuth
- **checkpointBoundary**: Permissionless deficit entry
- **Deficit stubs**: depositRecovery/claimRecovery/claimRecoveryTo revert
  DeficitNotImplemented (Wave 6 will implement)

### Test File
- `test/CreditLedger.t.sol` (18 tests): funding, settlement, coalescing, withdrawal,
  reconciliation, deficit entry, position collisions

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
- **Settlement math**: SettlementMath.split (mulDiv-based) + completionCollected
  (min(completionFee, providerGross))
- **TerminalRecord**: 27-field struct with terminalHash via DealHashing.hashTerminalRecord
- **Extension stubs**: submitPaymentProof, openArbitration, submitArbitrationRuling,
  arbitrationTimeout all revert ProfileNotSelected (Core-only)

### Test File
- `test/CoreEscrow.t.sol` (46 tests): all Core transitions, rejection edges, settlement
  math, dispute paths, mutual resolve, terminal records

### Size Resolution
Settlement planning is now bound to the sole Ledger as a read-only, Escrow-authorized
planning operation. CoreEscrow remains below the EIP-170 limit while the deployed child
topology remains exactly Ledger / Coordinator / Escrow.

---

## Wave 4: CoreDeployer Manifest (COMPLETED)

Immutable deployment manifest hash computation per spec section 13.

### Changes
- **CoreManifestOffchain struct**: 11 off-chain fields (buildHash,
  deploymentMethodHash, artifactHashes, capabilityHash, governanceHash,
  verificationHash, predecessorManifestHash)
- **Manifest constants**: MANIFEST_SCHEMA_ID, MANIFEST_SCHEMA_VERSION,
  DEPLOYMENT_KIND_MANDATORY_CORE
- **MANDATORY_CORE_MANIFEST_V1_TYPEHASH**: Full 22-field ABI encoding typehash
- **DealHashing.hashCoreManifest**: Computes manifestHash from on-chain + off-chain
  fields
- **CoreDeployer**: Predicts all triad addresses via CREATE nonces, computes
  manifestHash before deploying CoreEscrow, passes real hash to Escrow constructor,
  stores chainId/protocolVersion/charterHash/techSpecHash as immutables
- **ManifestComputed event**: Emitted at construction for off-chain verification
- **Deploy script**: Updated with env-var-driven off-chain manifest fields

### Test File
- `test/CoreEscrow.t.sol` (5 manifest tests): non-zero hash, matches escrow,
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

## Wave 6: Integrate Proven Deficit Encoding (BLOCKED)

Replace deficit stubs in CreditLedger with the proven O(1) encoding from Wave 5.

### Blocker
The technical specification must select one production precision policy before integration:

1. explicit rational/checkpoint bounds with defined exhaustion behavior; or
2. conservative fixed-point indices with a normative error bound, dust behavior, and
   revised differential acceptance criteria.

Issuer-loss reconciliation cannot safely revert merely because an exact rational index no
longer fits fixed-width storage. Integrating the disproven cumulative scalar or an
unspecified approximation would violate TOKEN-017 through TOKEN-019.

### Changes
- Implement depositRecovery: accept recovery deposits, update totalRecoveredAssets
- Implement claimRecovery: compute pro-rata payable, push tokens, update claimedAssets
- Implement claimRecoveryTo: signed alternate receiver
- Update _reconcile to handle DEFICIT mode (append checkpoints)
- Update withdrawPosition to return DEFICIT_CLAIM_REQUIRED when in deficit
- Update preflightValueAction to handle deficit mode
- Terminal reassignment in deficit (section 4.6)
- Differential testing against ReferenceRecoveryModel

---

## Wave 7: Full Test Suite + Conformance Rewrite (IN PROGRESS)

Final conformance pass to verify all spec sections are covered.

### Contract topology and size remediation (COMPLETED FOR CURRENT CORE-ONLY CANDIDATE)
- Removed the deployed `CoreSettlement` child and kept the CoreDeployer child order at
  Ledger / Coordinator / Escrow nonces 1-3.
- Settlement planning is now Core-owned and internal; the resulting Escrow bytecode must
  remain bound to the sole Ledger as a read-only operation.
- Current `CoreEscrow` runtime is 24,517 bytes, 59 bytes below the 24,576-byte EIP-170
  limit. Any future attachment implementation must preserve this limit or reduce the
  current Core surface before it can be accepted.
- CoreDeployer now rejects placeholder manifest inputs and verifies reverse links.

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
2. **Deficit encoding**: Research-first (prove O(1) encoding before integrating)
3. **Module dispatch**: Deferred to later (Core-only in Phase 1)
4. **ABI manifest**: Included in Phase 1 (Wave 4)
5. **EVM version**: Shanghai (enables PUSH0 for smaller bytecode)
6. **Optimizer**: runs=1 (minimize bytecode size)
7. **via_ir**: true (Yul-based optimizer enabled)

## File Inventory

### Source Files
```
src/
  CoreEscrow.sol        - Tokenless state machine (Wave 3)
  CreditLedger.sol      - Sole vault with positions (Wave 2)
  CoreDeployer.sol      - Triad deployment + manifest (Wave 4)
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
    SignatureValidation.sol - Shared EOA/ERC-1271/EIP-2098 verification
```

### Test Files
```
test/
  DealTypes.t.sol           - 8 tests (Wave 1)
  DealHashing.t.sol         - 13 tests (Wave 1)
  FullMath.t.sol            - 6 tests (Wave 1)
  SettlementMath.t.sol      - 8 tests (Wave 1)
  CreditLedger.t.sol        - 18 tests (Wave 2)
  CoreEscrow.t.sol          - 46 tests (Wave 3+4+7)
  Coordinator.t.sol         - 3 tests (Wave 7)
  ExactERC20.t.sol          - 7 tests (Wave 7)
  SignatureValidation.t.sol - 5 tests (Wave 7)
  ReferenceRecoveryModel.t.sol - 11 tests (pre-existing)
  IndexedRecoveryModel.t.sol - 9 tests (Wave 5)
  helpers/
    MockERC20.sol
    FeeOnTransferToken.sol
    RevertingReceiver.sol
    ReferenceRecoveryModel.sol
    IndexedRecoveryModel.sol
```
