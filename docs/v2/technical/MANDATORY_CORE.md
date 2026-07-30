# Mandatory Core — Technical Specification

**Status:** Production-remediation specification candidate; unratified
**Document version:** 0.3.0-rc1
**Protocol version:** 2
**Date:** 2026-07-30
**Business authority:** `PROTOCOL.md`
**Architecture authority:** `docs/superpowers/specs/2026-07-29-core-architecture-immutability-design.md` revision 0.3.0-rc1
**Reference home chain:** Arbitrum (ECO-007)
**Runtime scope:** Mandatory Core plus the generic package attachment boundary; profile internals are separately specified

This is the only current Mandatory Core technical candidate. Versions 0.1.x and 0.2.x are historical drafts and MUST NOT be used as implementation authority.

---

## 0. Authority, candidate control, and history

### 0.1 Precedence

1. `PROTOCOL.md` defines business behavior.
2. This document defines executable Mandatory Core semantics.
3. The architecture document constrains topology and trust boundaries.
4. Code, tests, manifests, and deployments provide evidence; they do not redefine these documents.

If this document conflicts with `PROTOCOL.md`, this document is non-conforming until revised. Normative language follows `PROTOCOL.md` §1.3.

### 0.2 Document control

| Version | Date | Disposition |
| --- | --- | --- |
| 0.1.0 | 2026-07-29 | Initial draft; superseded |
| 0.2.0 | 2026-07-29 | Split-custody implementation draft; superseded |
| 0.2.1 | 2026-07-29 | Informal deficit addendum that retained an insufficient cumulative scalar; superseded |
| **0.3.0-rc1** | **2026-07-30** | **Sole-vault, typed funding/package/arbitration-open surfaces, deterministic positions/payouts, exact reconciliation statuses, signed PoolKind authority, fault-predicate reservations, independent Core dispute, Core-owned timeout, module-free commit, mandatory CoreDeployer, and ABI-manifest production-remediation candidate** |

There is no separate effective 0.2.0/0.2.1 candidate. This unratified working candidate remains mutable until its `techSpecHash` is explicitly frozen; after that freeze, any normative byte change requires a new release-candidate identifier and hash.

### 0.3 Existing artifacts and deployments

The current pre-remediation contracts are not production-deployable under this specification. Any existing instance with Escrow-held principal, general recovery-unit reallocation, ordinal terminal classification, unconditional extension stubs, or cumulative-distributable deficit accounting is experimental and non-conforming for production Mandatory Core.

The triad has no upgrade path. Such an instance cannot be upgraded or migrated in place. A conforming release requires new bytecode, a new immutable manifest and deployment identity, and explicit user opt-in. No production-conformance claim is valid before protocol ratification and release evidence satisfy `PROTOCOL.md` §§24–25.

### 0.4 Acceptance artifacts and freeze gates

Acceptance is artifact- and evidence-based; historical task numbers are not normative:

- `test/helpers/ReferenceRecoveryModel.sol` is the required independent rational model for §4. Its differential vectors and the implementation under test MUST satisfy §15.2 before a production recovery encoding is accepted.
- The API artifacts under `src/interfaces/` MUST preserve §8 and pass the token/signature, module, reservation, terminal-record, and deployment gates in §§15.3–15.6 before their selectors, errors, and events are treated as frozen.
- `docs/superpowers/specs/2026-07-29-core-architecture-immutability-design.md` §11 supplies the architecture conformance checkpoints. This document §§14–15 supplies the executable invariants and acceptance evidence.
- `docs/superpowers/plans/2026-07-29-mandatory-core-foundry.md` is superseded in full. Only its leading status and current-authorities notice identifies the replacement documents; none of its numbered tasks or retained body is an acceptance gate.

An artifact path above identifies required evidence, not independent authority. A missing, stale, or disagreeing artifact fails the applicable gate and MUST NOT weaken this specification.

---

## 1. Deployment topology

### 1.1 Mandatory Core triad

One Mandatory Core deployment consists of exactly:

| Contract | Holds protocol tokens? | Normative responsibility |
| --- | --- | --- |
| `CoreEscrow` | **No** | Consent, signatures, nonces, state, timing, module dispatch, settlement math, terminal record |
| `CreditLedger` | **Yes — exclusively** | Exact funding, active principal and fee/reservation positions, matured credits, withdrawals, loss checkpoints, attributable recoveries |
| `Coordinator` | No | Complete-tuple module admission for future activations |

`CreditLedger` is the sole physical vault for active principal, fee/reservation positions, matured credits, and recovery assets. `CoreEscrow` MUST hold zero protocol-token balance after every successful action, and principal MUST NOT transit through it.

### 1.2 Immutability

- Escrow and Ledger MUST NOT use a proxy, upgrade admin, custody pause, arbitrary call, receiver rescue, or asset sweep.
- Coordinator code and authority bounds are immutable. Its admitted tuples MAY change for future activations only.
- Escrow permanently binds one Ledger and one Coordinator.
- Ledger permanently binds one Escrow as its only Core controller.
- Constructor and live-readback checks MUST prove all reverse links.
- A new implementation is a new deployment identity; no successor can alter a predecessor.

### 1.3 CoreDeployer

`CoreDeployer` is mandatory deterministic deployment infrastructure, not a fourth member of the triad. Every supported deployment method MUST create one `CoreDeployer`, and that deployer MUST create and cross-bind Ledger, Coordinator, and Escrow and expose their addresses. It MUST have no post-deployment protocol authority.

Its nonzero address, creation/runtime code hashes, constructor preimage, child creation order, and deployment method are manifest facts; salt is zero only for the direct-deployer method. A one-shot factory is permitted as `CoreDeployer`'s creator when embedding all child creation code would approach EIP-3860 limits, but no method is permitted to bypass it or create a triad child from another address.

### 1.4 Required constructor identity

The triad MUST bind or expose:

- `chainId`, after proving `block.chainid <= type(uint64).max`;
- `protocolVersion == 2`;
- nonzero `charterHash`;
- nonzero `techSpecHash` for the exact ratified candidate/final artifact;
- Ledger, Escrow, and Coordinator cross-links;
- Coordinator governance authority and immutable authority bounds; and
- Core module API identity and bounds.

Deployment MUST revert on a wrong chain, unsupported protocol version, zero/placeholder document hash, zero address, duplicate triad address, non-contract dependency, or failed reverse binding.

---

## 2. Numeric domains, fixed limits, and state

### 2.1 Domains

| Quantity | Domain |
| --- | --- |
| Token amounts and nominal units | `uint256` token-smallest units |
| Basis points | `uint16` in `0..10_000` |
| Durations | positive `uint64` seconds |
| Timestamps/deadlines | `uint64` Unix seconds |
| Chain id | constructor-validated `uint64` |
| Protocol version | `uint32`, exactly `2` |
| Deal and content identities | `bytes32` |

Timestamp addition MUST detect `uint64` overflow. Multiplication/division that can overflow a `uint256` intermediate MUST use full-precision `mulDiv` semantics.

### 2.2 Core bounds

The 0.3.0-rc1 baseline fixes:

```text
MAX_MODULES_PER_DEAL          = 8
MAX_MODULE_CALLS_PER_ACTION   = 8
MAX_MODULE_DATA_BYTES         = 4_096 per call
MAX_EXTENSION_BYTES_PER_DEAL = 16_384 aggregate
MAX_RESERVATIONS_PER_DEAL     = 8
MAX_RULES_PER_RESERVATION     = 16
MAX_OUTPUTS_PER_RESERVATION   = 2
BPS_DENOMINATOR               = 10_000
```

Bindings are sorted and unique by role, so work remains bounded even when all slots are populated. Changing these limits changes technical semantics and requires a new candidate/deployment identity.

### 2.3 Deal states

```text
Nonexistent:
   0 NONE

Nonterminal:
   1 FUNDED
   2 FIAT_SENT
   3 DISPUTED
   4 ARBITRATION_ACTIVE       // only when ARBITRATION is selected

Terminal:
  16 RELEASED
  17 RESOLVED_SPLIT
  18 RESOLVED_BY_DISPUTE_TIMEOUT
  19 CANCELLED
  20 RESOLVED_BY_ARBITRATION
  21 STALEMATE
```

The terminal predicate is explicit set membership:

```text
isTerminal(s) =
  s == RELEASED
  || s == RESOLVED_SPLIT
  || s == RESOLVED_BY_DISPUTE_TIMEOUT
  || s == CANCELLED
  || s == RESOLVED_BY_ARBITRATION
  || s == STALEMATE
```

These are fixed `uint8` wire/storage ids for contexts and terminal records. Ordinal comparison is forbidden. In particular, `ARBITRATION_ACTIVE` is nonterminal regardless of numeric layout.

### 2.4 Outcomes

The closed outcome set remains:

```text
 0 INVALID
 1 VOLUNTARY_RELEASE
 2 COSIGNED_RELEASE
 3 PAYMENT_PROOF_RELEASE
 4 TIMEOUT_CLAIM
 5 PROVIDER_CANCEL
 6 FIAT_TIMEOUT_CANCEL
 7 MUTUAL_CANCEL
 8 MUTUAL_SPLIT
 9 ARBITRATION_HOLDER_WIN
10 ARBITRATION_PROVIDER_WIN
11 ARBITRATION_REFUSED
12 ARBITRATION_TIMEOUT
13 DISPUTE_TIMEOUT
```

These are fixed `uint8` ids. Outcome `0` is never terminal. Reserved business identifiers remain reserved. State and outcome are stored separately.

### 2.5 Profile capability set

Profile-flag values remain:

```text
PAYMENT_PROOF    = 1 << 0
ARBITRATION      = 1 << 1
BONDS            = 1 << 2
POOL             = 1 << 3
REPUTATION       = 1 << 4
HUMANITY         = 1 << 5
RATE_POLICY      = 1 << 6
CROWDFUNDED_POOL = 1 << 7
```

The signed/snapshotted `PoolKind` ids are:

```text
0 NONE
1 OWNED
2 CUSTOM
3 CROWDFUNDED
```

`POOL` requires kind `1` or `2`. A direct deal requires kind `0` through canonical absence of the pool-authority preimage. Kind `3`, the `CROWDFUNDED_POOL` flag, or any flag/kind mismatch rejects in this candidate.

Module-role ordinals remain:

```text
0 PAYMENT_PROOF_VERIFIER
1 ARBITRATION_ADAPTER
2 BOND_VAULT
3 POOL
4 HUMANITY_VERIFIER
5 REPUTATION_POLICY
6 RATE_POLICY
7 PACKAGE_POLICY
```

Required flag-to-role mapping is:

| Flag | Required role |
| --- | --- |
| `PAYMENT_PROOF` | `PAYMENT_PROOF_VERIFIER` |
| `ARBITRATION` | `ARBITRATION_ADAPTER` |
| `BONDS` | `BOND_VAULT` |
| `POOL` | `POOL` |
| `REPUTATION` | `REPUTATION_POLICY` |
| `HUMANITY` | `HUMANITY_VERIFIER` |
| `RATE_POLICY` | `RATE_POLICY` |

Core MUST implement generic attachment for roles 0–7. `PACKAGE_POLICY` has no standalone profile bit; it is permitted only when the nonzero `packageSelectionHash` and its exact §6.9 preimage bind the same `modulesHash`. Core-only deals use no roles and remain complete. A role's internal policy is not implemented by Core and cannot claim profile conformance merely because the attachment surface exists.

`CROWDFUNDED_POOL` MUST reject at activation until CF-GATE is satisfied.

### 2.6 Operator-fault classification

The closed authenticated `uint8` classification is:

```text
0 NO_OPERATOR_FAULT
1 MUTUAL_OPERATOR_FAULT
2 ARBITRATION_OPERATOR_FAULT
```

Code `1` is valid only on `MUTUAL_SPLIT` with the exact operator consent in §6.6. Code `2` is valid only in a selected arbitration ruling result authenticated under the snapshotted `operatorFaultPolicyHash`. Unknown codes reject.

Provider cancel, fiat timeout, claim, payment proof, Core dispute/open/timeout, arbitration timeout, and a refused/no-decision result with fault code zero never invent operator fault. The classification controls operator-fee eligibility under §8.5; any bond consequence remains separately limited by its signed reservation schedule.

`ReservationRule` uses this separate closed predicate:

```text
0 FAULT_ANY
1 FAULT_NONE
2 FAULT_MUTUAL
3 FAULT_ARBITRATION
```

Predicate `0` matches any normalized classification. Predicates `1`, `2`, and `3` match classification `0`, `1`, and `2` respectively. For one `(reservation slot, outcome)`, rules use either one `FAULT_ANY` row or one/more class-specific rows, never both. Core performs the match; a module returns only the authenticated classification/evidence allowed by §7.3 and never selects a predicate, formula, beneficiary, or amount.

```text
OPERATOR_FAULT_RULE_SCHEMA_V1 = keccak256("pluriswap.operator-fault-rule.v1")
```

---

## 3. Custody boundary and position model

### 3.1 Boundary identity

For token `T`:

```text
CUSTODY_BOUNDARY_TYPEHASH =
  keccak256("PluriSwapCustodyBoundary(uint64 chainId,uint32 protocolVersion,address ledger,address token)")

custodyBoundaryId =
  keccak256(abi.encode(
    CUSTODY_BOUNDARY_TYPEHASH,
    chainId,
    protocolVersion,
    address(ledger),
    T
  ))
```

Signed terms MUST contain this derived value. A caller-supplied alternative that claims separate accounting over the same `(chain, version, Ledger, token)` balance rejects.

### 3.2 Boundary state

Each token boundary has:

```text
mode                 ∈ { HEALTHY, DEFICIT }
accountedAssets      // assets attributed to live positions
nominalOutstanding   // healthy-mode unpaid liabilities
quarantinedSurplus   // raw positive deltas not attributed to positions
deficitNominalUnits  // fixed total at deficit entry
checkpoint identity/generation
```

`DEFICIT` is irreversible. A fully refilled gap does not restore `HEALTHY` and does not permit new exposure.

### 3.3 Position kinds

Ledger uses these closed immutable identity kinds:

```text
1 DEAL
2 ACTIVATION_FEE
3 DEAL_TERMINAL
4 RESERVATION
5 RESERVATION_TERMINAL
```

Kinds `1` and `4` are active and not withdrawable. Kinds `2`, `3`, and `5` are matured beneficiary positions; their fixed beneficiary is both the default receiver and payout authority, while only a typed §6.7 authorization may select another receiver. Consumption is lifecycle state retained as a tombstone, not another identity kind.

Every position id is:

```text
POSITION_ID_V1_TYPEHASH = keccak256("PluriSwapPositionIdV1(bytes32 custodyBoundaryId,uint8 kind,bytes32 sourceId,bytes32 terminalHash,address beneficiary)")

positionId = keccak256(abi.encode(
  POSITION_ID_V1_TYPEHASH,
  custodyBoundaryId,
  kind,
  sourceId,
  terminalHash,
  beneficiary
))
```

The exact preimages are:

| Kind | `sourceId` | `terminalHash` | `beneficiary` |
| --- | --- | --- | --- |
| `DEAL` | `dealId` | zero | zero |
| `ACTIVATION_FEE` | `dealId` | zero | signed activation-fee recipient |
| `DEAL_TERMINAL` | `dealId` | canonical terminal hash | fixed output beneficiary |
| `RESERVATION` | §8.5 `reservationId` | zero | zero |
| `RESERVATION_TERMINAL` | §8.5 `reservationId` | canonical terminal hash | fixed output beneficiary |

Healthy activation creates one `DEAL` position exactly equal to principal. A nonzero activation fee creates one separate fully funded `ACTIVATION_FEE` position from its separately authorized exact funding.

Healthy terminal settlement consumes one `DEAL` position and first coalesces the holder, provider-net, and completion-fee allocations by equal beneficiary address; it creates at most one `DEAL_TERMINAL` position per nonzero coalesced beneficiary. Each reservation similarly coalesces its own nonzero outputs before creating at most one `RESERVATION_TERMINAL` position per beneficiary. No coalescing occurs across different deals, between activation fee and terminal value, between deal and reservation value, or across different reservations. Thus source attribution and deficit components remain independently reconstructable.

A derived id that is already live or consumed rejects creation. An exact repeated preimage is an attempted replay, not an instruction to add liability; a distinct preimage producing the same id is a collision and also rejects. Consumed tombstones are never deleted or reusable. Zero allocations create no position. Within one successful settlement only the specified same-source beneficiary coalescing occurs before ids are derived.

### 3.4 Healthy invariants

After each reconciled healthy action:

```text
accountedAssets == nominalOutstanding
raw token balance == accountedAssets + quarantinedSurplus
sum(live unpaid position amounts) == nominalOutstanding
CoreEscrow token balance == 0
```

An unexplained positive raw delta increases only `quarantinedSurplus`. It does not create a position or hide a shortfall.

---

## 4. Irreversible checkpointed deficit semantics

This section defines observable exact-model semantics. The independent rational model at `test/helpers/ReferenceRecoveryModel.sol` MUST prove any global-index/generation encoding equivalent under the §15.2 differential gate. This candidate intentionally does not prescribe an unproven Solidity index formula.

### 4.1 Deficit entry

After consuming any physical loss from `quarantinedSurplus`, if attributable assets `A` are below healthy outstanding nominal liability `N`, the boundary enters DEFICIT:

```text
0 <= A < N
deficitNominalUnits = N
```

Every live outstanding position `i` receives a deficit position with:

```text
nominalUnits_i       = its unpaid nominal claim at entry
paidAssets_i         = 0 for the deficit epoch
fundedEntitlement_i  = nominalUnits_i * A / N       // exact rational
unfundedGap_i        = nominalUnits_i - fundedEntitlement_i
```

Pre-deficit successful transfers are closed history and excluded from `N`. Active deals remain deal-owned and cannot claim before terminal reassignment.

For every position and checkpoint:

```text
nominalUnits_i =
  paidAssets_i + fundedEntitlement_i + unfundedGap_i
```

The sum of nominal units never changes after entry. Position identities may be replaced only by an authorized whole-position terminal split of a deal or reservation that conserves every component.

### 4.2 Raw-balance reconciliation

Let:

```text
expectedRaw = accountedAssets + quarantinedSurplus
actualRaw   = exact token.balanceOf(Ledger)
```

On reconciliation:

```text
quarantineBefore = quarantinedSurplus
accountedBefore  = accountedAssets
```

1. If `actualRaw > expectedRaw`, add the difference to `quarantinedSurplus`, do not fund gaps, and return status `1`.
2. If `actualRaw == expectedRaw`, change no accounting and return status `0`.
3. If `actualRaw < expectedRaw`, let:

```text
negativeDelta = expectedRaw - actualRaw
absorbed      = min(negativeDelta, quarantineBefore)
quarantinedSurplus' = quarantineBefore - absorbed
residualLoss  = negativeDelta - absorbed
```

4. If `residualLoss == 0`, return status `3`: the negative delta was fully absorbed by quarantined surplus, so `accountedAssets`, boundary mode, nominal units, and checkpoint identity remain unchanged.
5. If `residualLoss > 0`, return status `4`: set `quarantinedSurplus = 0`; the residual reduces `accountedAssets` and enters or advances `DEFICIT`.

A successful exact pull or push already changes the corresponding accounting in the same transaction and is not an external loss or surplus.

No Core path sweeps quarantined surplus. A future surplus policy requires a new explicitly reviewed authority.

Every Ledger operation that can transfer tokens or create, consume, split, pay, or reassign a position MUST reconcile every touched token boundary immediately before that value movement. This includes:

- principal, activation-fee, and reservation funding;
- same-Ledger funding-position splits;
- healthy `withdrawPosition` and `withdrawPositionTo`;
- `depositRecovery`;
- `claimRecovery` and signed redirection;
- deal settlement; and
- reservation disposition.

The closed reconciliation status is:

```text
0 UNCHANGED
1 SURPLUS_QUARANTINED
2 RESERVED_INVALID
3 QUARANTINE_LOSS_ABSORBED
4 DEFICIT_CHECKPOINTED
```

Status `2` is reserved and MUST never be returned; Core rejects it as malformed. Statuses `0`, `1`, and `3` may continue the requested action. Status `3` is not a deficit or position-loss checkpoint: liabilities remain fully covered by `accountedAssets`, only surplus accounting decreases, and no funded/gap component changes.

Status `4` is the only reconciliation loss status. From `HEALTHY` it enters irreversible `DEFICIT`; from `DEFICIT` it persists that mode and appends the next loss checkpoint. It stops the current requested exposure/value movement; the retry uses the mode-specific paths below.

Every accounting-changing reconciliation emits exactly one semantic record:

```text
BoundaryReconciled(
  address token,
  uint8 status,
  uint256 expectedRawBefore,
  uint256 actualRaw,
  uint256 accountedAssetsBefore,
  uint256 accountedAssetsAfter,
  uint256 quarantinedSurplusBefore,
  uint256 quarantinedSurplusAfter,
  bytes32 checkpointId
)
```

The accepted interface artifacts may choose the Solidity event name/indexing only after the §§15.2–15.3 gates pass, but this field meaning and emission cardinality are normative. Statuses `1`, `3`, and `4` emit; `UNCHANGED` emits nothing and status `2` is invalid. For status `3`, before/after accounted assets and checkpoint id are identical, and no `DeficitEntered` or `LossCheckpointed` record emits. If the continuing outer action later reverts, this surplus-accounting update and event revert with it; the next reconciliation observes the delta again. A standalone `checkpointBoundary` or successful outer action persists it.

For a sorted multi-boundary preflight, Ledger reconciles every listed boundary before movement. Overall status is `4` if any boundary returns `4`, else `3` if any returns `3`, else `1` if any returns `1`, else `0`; per-token records preserve each individual status. Overall status `4` stops the whole requested action. Statuses `0`, `1`, and `3` continue.

`DEFICIT_CHECKPOINTED` (`4`) MUST stop the requested value movement before any token call, position ownership change, action nonce consumption, or Core state/terminal write. The reconciliation-only transaction succeeds and returns/emits typed status `4` so the deficit checkpoint persists. The caller may retry against the new state.

When a Core preflight receives status `4`, Core MUST leave its deal state, terminal record, action nonce, and signatures unconsumed, return status `4`, and MUST NOT revert or wrap it in a revert. A wrapper that reverts successful status `4` is non-conforming because it would roll back the deficit checkpoint.

On retry:

- activation or reservation creation observes `DEFICIT` and returns/rejects with no new exposure and no nonce consumption;
- a healthy withdrawal observes `DEFICIT` and returns the typed `DEFICIT_CLAIM_REQUIRED` result without a push;
- recovery deposit proceeds only through §4.4;
- deficit claim materializes from the new checkpoint under §4.5; and
- terminal settlement uses the component-conserving §4.6 path.

All distinct boundaries for one atomic multi-token activation are reconciled before the first pull or position split. Status `4` in any one of them yields one reconciliation-only result and no funding in any boundary. A token transfer failure after status `0`, `1`, or `3` remains an ordinary atomic failure; no newly discovered deficit transition is being relied on in that call.

A Core action that needs a stateful optional module call before Ledger value movement uses two checks:

1. Ledger preflights every known deal/reservation boundary before the module call; status `3` continues and status `4` takes the persistent reconciliation-only branch.
2. After the module result, Ledger rechecks raw balances immediately before position movement.

At the second check, a quarantine-absorbed delta follows status-`3` accounting and continues. If an attributable residual loss appears, the whole action reverts atomically so the module's state change also rolls back. That reverted branch does not return status `4` and makes no claim that a deficit write persisted; anyone may then use `checkpointBoundary`. This is distinct from preflight status `4`, which MUST use the successful reconciliation-only branch.

### 4.3 Loss checkpoint

Immediately before an attributable loss, let:

```text
F = Σ fundedEntitlement_i = accountedAssets
B = attributable assets remaining after reconciliation
0 <= B < F
```

The exact checkpoint transformation is:

```text
fundedEntitlement_i' =
  fundedEntitlement_i * B / F

unfundedGap_i' =
  unfundedGap_i
  + (fundedEntitlement_i - fundedEntitlement_i')

paidAssets_i' = paidAssets_i
accountedAssets' = B
```

If `F == 0`, there is no position-funded value to lose. Duplicate loss observations are no-ops.

This transformation affects only unpaid funded value. Prior successful payments are final and cannot be clawed back.

### 4.4 Exact attributable recovery

`depositRecovery(token, from, amount)` is the only path that classifies a positive transfer as recovery.

Preconditions:

- mandatory §4.2 reconciliation did not return status `4` in this call;
- boundary is already `DEFICIT`;
- `amount > 0`;
- `amount <= G`, where `G = Σ unfundedGap_i`;
- exact §5.2 Ledger pull from the depositor to Ledger succeeds; and
- the depositor receives no position, units, receiver authority, or priority.

The exact checkpoint transformation for recovery `R = amount` is:

```text
unfundedGap_i' =
  unfundedGap_i * (G - R) / G

fundedEntitlement_i' =
  fundedEntitlement_i
  + (unfundedGap_i - unfundedGap_i')

paidAssets_i' = paidAssets_i
accountedAssets' = accountedAssets + R
```

Recovery above the aggregate gap rejects atomically; it is not partially accepted. A direct transfer to Ledger is quarantined surplus and MUST NOT be retroactively relabeled as recovery.

### 4.5 Recovery claim

Only a matured beneficiary position may claim. An active deal or unresolved reservation position cannot claim.

The operation first reconciles under §4.2. Status `3` continues. Status `4` persists the deficit checkpoint and returns without attempting a push; the retry computes payable value from that new checkpoint.

At the current materialized checkpoint, after applying a finite positive `maxAmount` or the `type(uint256).max` all-payable sentinel:

```text
available_i = floor(fundedEntitlement_i)
payable_i   = min(available_i, maxAmount)
```

If `payable_i == 0`, the operation returns the typed `ZERO_PAYABLE` result without changing the position or consuming a redirection nonce. Otherwise an exact push to the fixed beneficiary, or beneficiary-authorized alternate receiver, executes atomically:

```text
paidAssets_i'        = paidAssets_i + payable_i
fundedEntitlement_i' = fundedEntitlement_i - payable_i
unfundedGap_i'       = unfundedGap_i
accountedAssets'     = accountedAssets - payable_i
```

Failed token transfer or invalid redirection leaves the complete position and nonce unchanged. Any address may execute a claim to the predetermined receiver. Claim order among positions at the same checkpoint cannot change their exact funded entitlement. Deficit claims return `DEFICIT_PAID` for any positive payment; they do not relabel the irreversible boundary as healthy or consume remaining gap.

### 4.6 Terminal reassignment in deficit

An active deal position has:

```text
N_d = nominalUnits_d
P_d = 0
F_d = fundedEntitlement_d
G_d = unfundedGap_d
F_d + G_d = N_d
```

Core supplies the holder, provider-net, and completion-fee nominal allocations. Ledger coalesces allocations with the same beneficiary before component splitting, yielding at most three nonzero child amounts `n_j` with `Σ n_j = N_d`; the terminal record retains the uncoalesced semantic breakdown.

For each child position:

```text
nominalUnits_j       = n_j
paidAssets_j         = 0
fundedEntitlement_j  = F_d * n_j / N_d
unfundedGap_j        = G_d * n_j / N_d
```

The original deal position becomes consumed. No token transfer, unit creation, general beneficiary-to-beneficiary reallocation, or per-child checkpoint rounding occurs.

An active reservation position uses the identical transformation with `N_r`, `F_r`, and `G_r` after coalescing equal beneficiaries within that reservation, with at most the two nonzero §8.5 disposition amounts whose sum is `N_r`. Deal and reservation positions are materialized against the same current boundary checkpoint before splitting.

### 4.7 Rounding and complexity

- Checkpoint equations above use exact rational semantics.
- Production arithmetic MUST use proven full-precision indices/generations and `mulDiv`-equivalent floor/ceiling operations.
- Token payout is the only position-level floor.
- Stored gap MUST be conservative: representation error may delay dust but MUST NOT permit payment above nominal entitlement.
- Fractional and integer dust remains publicly attributable to the boundary. There is no sweep, governance recipient, or last-claimer rule.
- Deficit entry, sync, loss, recovery, claim, and terminal reassignment MUST each be O(1), independent of position count and checkpoint history.
- Lazy materialization is permitted only if observably identical to the equations and O(1).

No production Solidity implementation of this section is authorized until `test/helpers/ReferenceRecoveryModel.sol` and the implementation agree on every repeated-loss, partial-claim, recovery, split, dust, and claim-order vector required by §15.2.

---

## 5. Exact ERC-20 semantics

### 5.1 Supported call behavior

For `balanceOf`, `transfer`, and `transferFrom`:

- `token.code.length` MUST be nonzero;
- low-level call failure or revert rejects;
- return data of length zero is optional-return success;
- return data of exactly 32 bytes is success only when it canonically decodes to `true`;
- false, malformed, short, or extra return data rejects; and
- optional-return success never replaces delta verification.

`balanceOf` itself MUST return exactly one valid 32-byte amount.

### 5.2 Two-sided exact `transferFrom`

The generic source-to-destination helper for any nonzero `amount` is:

```text
exactTransferFrom(token, source, destination, amount):
  require source != address(0)
  require destination != address(0)
  require source != destination

  sourceBefore      = balanceOf(source)
  destinationBefore = balanceOf(destination)
  optionalReturnSafeTransferFrom(token, source, destination, amount)
  sourceAfter       = balanceOf(source)
  destinationAfter  = balanceOf(destination)

  require sourceAfter <= sourceBefore
  require destinationAfter >= destinationBefore
  require sourceBefore - sourceAfter == amount
  require destinationAfter - destinationBefore == amount
```

Ledger funding, reservation funding, and attributable recovery use `exactTransferFrom(token, source, Ledger, amount)`. Only that Ledger-destination specialization may increase Ledger `accountedAssets`, nominal liability, or funded entitlement, and it does so only under the operation-specific rules after exact receipt.

An external package toll or arbitration quote uses `exactExternalFee(token, payer, recipient, amount)`, defined exactly as `exactTransferFrom(token, payer, recipient, amount)`. Its destination is the signed non-custodial fee recipient—not Ledger—and it creates no Ledger asset, position, liability, recovery, surplus, or accounting entry. Zero amount skips the helper and token call.

### 5.3 Two-sided exact push

For a push of `amount` from Ledger to `receiver`:

```text
ledgerBefore   = balanceOf(Ledger)
receiverBefore = balanceOf(receiver)
optionalReturnSafeTransfer(receiver, amount)
ledgerAfter    = balanceOf(Ledger)
receiverAfter  = balanceOf(receiver)

require ledgerBefore - ledgerAfter == amount
require receiverAfter - receiverBefore == amount
```

Source and destination MUST differ. Zero-amount channels skip the token call. Fee, burn, bonus, reflection, short transfer, rebase-during-call, and self-transfer behavior therefore rejects. A failed call reverts accounting and token effects atomically.

### 5.4 Receiver restrictions

A fixed beneficiary and every authorized alternate receiver MUST be nonzero and differ from Ledger. Escrow and other protocol custody contracts MUST also be rejected as beneficiary receivers to avoid circular or unpayable protocol positions.

Native ETH is unsupported; payable fallbacks reject.

---

## 6. Signing, chain, version, and identifiers

### 6.1 EIP-712 domains

Escrow domain:

```text
EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)
name              = "PluriSwap"
version           = "2"
chainId           = immutable deployment chain
verifyingContract = CoreEscrow
```

Ledger redirection domain:

```text
name              = "PluriSwapCreditLedger"
version           = "2"
chainId           = immutable deployment chain
verifyingContract = CreditLedger
```

The constructor MUST reject if `block.chainid` does not fit the stored domain. Every signed action MUST recheck `block.chainid == chainId`; a fork or chain-id change cannot reuse the cached separator.

Document version `0.3.0-rc1` is not the EIP-712 protocol version. Deployment address plus immutable `techSpecHash` identify this candidate's code; protocol-domain version remains `"2"`.

### 6.2 Module binding hash

Normative element type:

```text
ModuleBinding(
  uint8 role,
  address module,
  bytes32 runtimeCodeHash,
  bytes32 policyHash,
  bytes32 manifestHash,
  bytes32 apiId,
  bytes32 moduleTermsHash,
  uint32 capabilityMask
)
```

```text
MODULE_BINDING_TYPEHASH = keccak256("ModuleBinding(uint8 role,address module,bytes32 runtimeCodeHash,bytes32 policyHash,bytes32 manifestHash,bytes32 apiId,bytes32 moduleTermsHash,uint32 capabilityMask)")
```

Bindings MUST be sorted ascending by role and unique. `bindingHash_i = hashStruct(ModuleBinding_i)`.

```text
modulesHash =
  bindingCount == 0
    ? bytes32(0)
    : keccak256(bindingHash_0 || ... || bindingHash_n)
```

### 6.3 Arbitration terms

When `ARBITRATION` is enabled, calldata MUST include this exact typed preimage:

```text
ArbitrationTerms(
  uint64 arbitrationDuration,
  address feeToken,
  address feeReceiver,
  bytes32 feeQuotePolicyHash,
  uint256 maxFee,
  bytes32 rulingPolicyHash,
  bytes32 stalematePolicyHash
)
```

```text
ARBITRATION_TERMS_TYPEHASH = keccak256("ArbitrationTerms(uint64 arbitrationDuration,address feeToken,address feeReceiver,bytes32 feeQuotePolicyHash,uint256 maxFee,bytes32 rulingPolicyHash,bytes32 stalematePolicyHash)")

arbitrationTermsHash = hashStruct(ArbitrationTerms)
```

`arbitrationDuration` MUST be positive and addition to an arbitration-open timestamp MUST fit `uint64`. `feeQuotePolicyHash`, `rulingPolicyHash`, and `stalematePolicyHash` MUST be nonzero and consistent with the selected arbitration binding. If `maxFee > 0`, `feeToken` and `feeReceiver` MUST be nonzero, distinct from protocol custody, and match the quote policy; if `maxFee == 0`, both MAY be zero only when the policy explicitly permits a zero court fee. `stalematePolicyHash` commits to the signed fixed 50/50 principal and reservation-disposition semantics.

For a pool deal with an operator, `rulingPolicyHash` and the arbitration binding's `moduleTermsHash` MUST commit the exact §6.10 `operatorFaultPolicyHash` and its authenticated evidence schema. A nonzero arbitration fault result rejects for a direct deal, a pool deal without an operator, or any mismatch.

When `ARBITRATION` is disabled, `arbitrationTermsHash` and every calldata preimage field MUST be the canonical zero value. Core snapshots the validated hash and duration at activation.

Arbitration open uses one exact runtime request:

```text
ArbitrationOpenRequestV1(
  bytes32 dealId,
  address caller,
  address payer,
  address quoteToken,
  uint256 quoteAmount,
  address quoteReceiver,
  uint256 quoteNonce,
  uint64  quoteExpiry,
  bytes32 quotePolicyHash,
  bytes32 adapterDataHash,
  bytes32 packageDataHash
)

ARBITRATION_OPEN_REQUEST_V1_TYPEHASH = keccak256("ArbitrationOpenRequestV1(bytes32 dealId,address caller,address payer,address quoteToken,uint256 quoteAmount,address quoteReceiver,uint256 quoteNonce,uint64 quoteExpiry,bytes32 quotePolicyHash,bytes32 adapterDataHash,bytes32 packageDataHash)")

arbitrationOpenRequestHash = hashStruct(ArbitrationOpenRequestV1)
```

`dealId` matches storage; `caller == payer == msg.sender` and caller is the exact §6.10 arbitration actor. This equality enforces `PROTOCOL.md` ARB-003C: the opening caller pays from its own wallet; sponsored or relayed court-fee payment is not supported by this candidate. `quotePolicyHash`, token, and receiver exactly match the snapshotted `ArbitrationTerms`; the receiver is non-custodial; `quoteAmount <= maxFee`; and `quoteExpiry >= block.timestamp`. When the policy permits a zero quote, amount is zero, no transfer occurs, and token/receiver use the canonical values required by the snapshotted terms. Otherwise amount, token, and receiver are nonzero.

The quote nonce is unused in `(dealId, arbitration adapter, quotePolicyHash, quoteNonce)`. Raw bounded data hashes are:

```text
adapterDataHash = adapterData.length == 0 ? bytes32(0) : keccak256(adapterData)
packageDataHash = packageData.length == 0 ? bytes32(0) : keccak256(packageData)

packageActionData = abi.encode(ArbitrationOpenRequestV1, packageData)
adapterActionData = abi.encode(ArbitrationOpenRequestV1, adapterData)
```

Each §7 `actionDataHash` is `keccak256` of its complete action-data encoding. When no package enhancement is requested, `packageDataHash == bytes32(0)` and no package call occurs. The adapter authenticates the quote and request by returning `ARBITRATION_OPENED` for the exact caller-bound context and adapter action data.

After that result, Core constructs and stores:

```text
ArbitrationOpenResultV1(
  bytes32 requestHash,
  bytes32 contextHash,
  bytes32 adapterEvidenceHash,
  uint64  arbitrationStartedAt,
  uint64  arbitrationDeadline
)

ARBITRATION_OPEN_RESULT_V1_TYPEHASH = keccak256("ArbitrationOpenResultV1(bytes32 requestHash,bytes32 contextHash,bytes32 adapterEvidenceHash,uint64 arbitrationStartedAt,uint64 arbitrationDeadline)")

arbitrationOpenResultHash = hashStruct(ArbitrationOpenResultV1)
```

`contextHash` is the adapter call context and `adapterEvidenceHash` is its nonzero `ModuleResult.evidenceHash`. The started time and checked deadline are Core-computed under §10.2. The complete request/result preimages and result hash are queryable Core storage.

The ordering is closed: (1) guard, chain, source-state, Core deadline, actor, request, quote, and unused-nonce checks; (2) Ledger preflight of all snapshotted deal/reservation boundaries, with reconciliation-only return on status `4`; (3) optional package-enhancement validation over the same request; (4) `exactExternalFee(feeToken, caller, feeRecipient, arbitrationOpenFee)` for the signed package toll, if any; (5) `exactExternalFee(quoteToken, payer, quoteReceiver, quoteAmount)` for the external court quote; (6) adapter command `ARBITRATION_OPEN_VALIDATE`; (7) Core state/nonce recheck; and (8) quote-nonce consumption plus request/result/deadline/state write. Both fee destinations are external and create no Ledger accounting. No other ordering is conforming. Revert, malformed result, inexact transfer, reentrancy, stale state, or later write failure rolls back both transfers, every module effect, the quote nonce, and all Core writes.

### 6.4 Deal terms

Principal and activation-fee funding use the same closed typed specification:

```text
1 PRINCIPAL
2 ACTIVATION_FEE

1 WALLET_PULL
2 LEDGER_POSITION

FundingSpec(
  uint8   purpose,
  uint8   sourceMode,
  address token,
  uint256 amount,
  address source,
  bytes32 sourcePositionId,
  address authority
)

FUNDING_SPEC_TYPEHASH = keccak256("FundingSpec(uint8 purpose,uint8 sourceMode,address token,uint256 amount,address source,bytes32 sourcePositionId,address authority)")

fundingSpecHash = hashStruct(FundingSpec)
```

For `WALLET_PULL`, `source == authority`, `sourcePositionId == bytes32(0)`, and Ledger executes `exactTransferFrom(token, source, Ledger, amount)` with both §5.2 deltas. A direct deal requires that address to be `holder`; a pool-origin deal requires it to be the exact §6.10 `pool`. The source's separate `FundingAuth` is required even when allowance exists, so allowance alone remains insufficient. Only after exact receipt does Ledger increase both `accountedAssets` and nominal outstanding by `amount` and allocate that same amount to the new deal or activation-fee position.

For `LEDGER_POSITION`, `sourcePositionId` is nonzero and identifies an existing HEALTHY matured beneficiary position in the same Ledger and token boundary; `source == authority` is its fixed beneficiary/payout authority, and its unpaid amount is at least `amount`. Direct funding requires that address to be `holder`; pool-origin funding requires it to be the exact §6.10 `pool`. Ledger reduces that source position by exactly `amount`, consuming it only when the remainder is zero, and allocates exactly `amount` to the new deal or activation-fee position. No token call occurs and boundary `accountedAssets` and nominal outstanding remain unchanged. Active deal/reservation positions, consumed positions, deficit positions, wrong-token positions, and insufficient positions reject. No mode permits allowance, a pool/module callback, or a caller-supplied address to substitute for signed authority.

All target ids and source sufficiency are checked before the first pull/debit. Across principal, fee, and reservations, every pull/debit/allocation is one atomic Ledger operation: a later failure restores source positions and boundary accounting, rolls back token transfers, creates no target position, and consumes no nonce.

`purpose`, token, and amount MUST match the corresponding `DealTerms` field:

```text
principalFundingHash     = hashStruct(PRINCIPAL FundingSpec)
activationFeeFundingHash =
  activationFee == 0
    ? bytes32(0)
    : hashStruct(ACTIVATION_FEE FundingSpec)
```

Principal is positive and requires one `PRINCIPAL` spec. A positive activation fee requires one distinct `ACTIVATION_FEE` spec; a zero activation fee requires no fee spec or authorization. Direct deals require principal and any fee `authority == holder`; pool-origin sources must be authorized by the exact §6.10 snapshot but remain separately signed below.

Each nonzero spec requires this Ledger-domain authorization:

```text
FundingAuth(
  bytes32 termsHash,
  bytes32 fundingSpecHash,
  uint8   purpose,
  address authority,
  uint256 nonce,
  uint64  expiry
)

FUNDING_AUTH_TYPEHASH = keccak256("FundingAuth(bytes32 termsHash,bytes32 fundingSpecHash,uint8 purpose,address authority,uint256 nonce,uint64 expiry)")
```

The exact `FundingSpec.authority` signs. Nonces are one-use in `(authority, purpose, nonce)` and are consumed only after every principal, fee, and reservation funding operation and Core activation write succeeds. A deal signature, token allowance, mandate, or operator acceptance does not replace `FundingAuth`. Expiry, signature, source-position, exact-pull, module, later-boundary, or activation failure reverts all pulls/splits and consumes no funding or action nonce.

Normative EIP-712 type:

```text
DealTerms(
  address holder,
  address provider,
  address holderReceiver,
  address providerReceiver,
  address token,
  bytes32 principalFundingHash,
  bytes32 activationFeeFundingHash,
  bytes32 tokenRiskHash,
  bytes32 custodyBoundaryId,
  uint256 principal,
  uint256 activationFee,
  address activationFeeRecipient,
  uint256 completionFee,
  address completionFeeRecipient,
  uint256 nonce,
  uint64 createExpiry,
  uint64 fiatDuration,
  uint64 releaseDuration,
  uint64 disputeDuration,
  uint16 disputeTimeoutProviderBps,
  bytes32 fiatCurrency,
  uint256 fiatAmount,
  bytes32 paymentMethod,
  bytes32 payeeCommitment,
  bytes32 paymentReferenceCommitment,
  uint32 profileFlags,
  bytes32 packageSelectionHash,
  bytes32 packageContestTermsHash,
  bytes32 poolAuthorityHash,
  bytes32 arbitrationTermsHash,
  bytes32 reservationsHash,
  bytes32 modulesHash,
  bytes32 extensionsHash
)
```

```text
DEAL_TERMS_TYPEHASH = keccak256("DealTerms(address holder,address provider,address holderReceiver,address providerReceiver,address token,bytes32 principalFundingHash,bytes32 activationFeeFundingHash,bytes32 tokenRiskHash,bytes32 custodyBoundaryId,uint256 principal,uint256 activationFee,address activationFeeRecipient,uint256 completionFee,address completionFeeRecipient,uint256 nonce,uint64 createExpiry,uint64 fiatDuration,uint64 releaseDuration,uint64 disputeDuration,uint16 disputeTimeoutProviderBps,bytes32 fiatCurrency,uint256 fiatAmount,bytes32 paymentMethod,bytes32 payeeCommitment,bytes32 paymentReferenceCommitment,uint32 profileFlags,bytes32 packageSelectionHash,bytes32 packageContestTermsHash,bytes32 poolAuthorityHash,bytes32 arbitrationTermsHash,bytes32 reservationsHash,bytes32 modulesHash,bytes32 extensionsHash)")
```

For direct Core deals, the principal and any activation-fee funding authorities equal `holder`, and `poolAuthorityHash == bytes32(0)`. A selected pool profile uses the exact §6.10 snapshot and may use its bound pool funding source only through the exact `FundingSpec` and `FundingAuth`.

`principalFundingHash` and `activationFeeFundingHash` follow this section; `packageSelectionHash` and `packageContestTermsHash` follow §6.9; `poolAuthorityHash` follows §6.10; `arbitrationTermsHash` follows §6.3; and `reservationsHash` follows §8.5. Each absent preimage uses its specified canonical zero hash. `extensionsHash` is zero for empty extension bytes, otherwise `keccak256(extensions)`. Raw extensions are bounded by §2.2. `termsHash` is the EIP-712 struct hash using `DEAL_TERMS_TYPEHASH` and the fields in the exact displayed order. The provider and the exact direct/pool activation authority in §6.10 sign the Escrow-domain digest; every nonzero funding hash also requires its separate Ledger-domain authorization.

### 6.5 Deal identifier

```text
DEAL_ID_TYPEHASH =
  keccak256("PluriSwapDealId(uint64 chainId,uint32 protocolVersion,address escrow,bytes32 termsHash,address holder,address provider,uint256 nonce)")

dealId = keccak256(abi.encode(
  DEAL_ID_TYPEHASH,
  chainId,
  protocolVersion,
  address(Escrow),
  termsHash,
  holder,
  provider,
  nonce
))
```

### 6.6 Resolution authorization

```text
ResolutionAuth(
  bytes32 dealId,
  uint8 action,
  uint256 resolutionNonce,
  uint64 expiry,
  uint16 providerShareBps,
  uint8 operatorFaultCode,
  bytes32 operatorFaultEvidenceHash,
  bytes32 reservationDispositionsHash,
  bytes32 extensionsHash
)
```

```text
RESOLUTION_AUTH_TYPEHASH = keccak256("ResolutionAuth(bytes32 dealId,uint8 action,uint256 resolutionNonce,uint64 expiry,uint16 providerShareBps,uint8 operatorFaultCode,bytes32 operatorFaultEvidenceHash,bytes32 reservationDispositionsHash,bytes32 extensionsHash)")
```

Closed action ids are `1 MUTUAL_CANCEL`, `2 COSIGNED_RELEASE`, and `3 MUTUAL_SPLIT`; zero/unknown values reject. The provider and exact §6.10 holder mutual-resolution authority sign.

`operatorFaultCode` may be `1 MUTUAL_OPERATOR_FAULT` only for `MUTUAL_SPLIT`, only with nonzero `operatorFaultEvidenceHash`, and only when the exact snapshotted operator also signs:

```text
OperatorFaultConsent(
  bytes32 dealId,
  bytes32 resolutionAuthHash,
  address operator,
  bytes32 operatorFaultEvidenceHash,
  uint256 nonce,
  uint64 expiry
)

OPERATOR_FAULT_CONSENT_TYPEHASH = keccak256("OperatorFaultConsent(bytes32 dealId,bytes32 resolutionAuthHash,address operator,bytes32 operatorFaultEvidenceHash,uint256 nonce,uint64 expiry)")
```

The consent uses the Escrow domain and is replay-protected. All other mutual actions require fault code zero and zero fault evidence. Code `2` can never be caller-asserted in `ResolutionAuth`.

For `MUTUAL_CANCEL` and `COSIGNED_RELEASE`, `reservationDispositionsHash` MUST be zero and no disposition-consent payload is accepted; Core derives every reservation allocation from the immutable ordinary outcome rule or default return. Only `MUTUAL_SPLIT` may use a nonzero hash, and only for reservations whose exact stored rule is `MUTUAL_AUTH`. That hash binds the §8.5 dispositions and every affected collateral authorization required by `PROTOCOL.md` RES-004. Nonces are keyed by `(dealId, action, resolutionNonce)` and consumed only on successful resolution.

### 6.7 Position payout authorization and typed result

```text
1 HEALTHY_WITHDRAW
2 DEFICIT_CLAIM

PositionPayoutAuth(
  uint8   action,
  address token,
  bytes32 positionId,
  address beneficiary,
  address to,
  uint256 maxAmount,
  uint256 nonce,
  uint64 expiry
)
```

```text
POSITION_PAYOUT_AUTH_TYPEHASH = keccak256("PositionPayoutAuth(uint8 action,address token,bytes32 positionId,address beneficiary,address to,uint256 maxAmount,uint256 nonce,uint64 expiry)")
```

It uses the Ledger domain and the position's stored beneficiary signs. Nonces are one-use in `(beneficiary, action, nonce)`. `maxAmount` MUST be finite and positive or exactly `type(uint256).max`, which authorizes the full amount payable at execution; zero is invalid and cannot be used to burn a nonce. The action, beneficiary, position, token, receiver, nonce, and expiry are all bound. A HEALTHY signature cannot authorize a deficit claim and vice versa.

Every payout returns:

```text
1 HEALTHY_PARTIAL
2 HEALTHY_FULL
3 DEFICIT_PAID
4 ZERO_PAYABLE
5 DEFICIT_CLAIM_REQUIRED
6 RECONCILIATION_ONLY

PositionPayoutResult(
  uint8   code,
  uint8   reconciliationStatus,
  bytes32 positionId,
  address receiver,
  uint256 paidAmount,
  uint256 nominalRemaining
)

POSITION_PAYOUT_RESULT_SCHEMA_HASH = keccak256("PositionPayoutResult(uint8 code,uint8 reconciliationStatus,bytes32 positionId,address receiver,uint256 paidAmount,uint256 nominalRemaining)")
```

An unknown position, wrong action/kind/beneficiary/token/receiver, invalid cap, or bad authorization rejects. For a known matured position in HEALTHY, `payable = min(unpaidNominal, maxAmount)`. An exact positive push atomically sets `positionUnpaid' = positionUnpaid - payable`, `accountedAssets' = accountedAssets - payable`, and `nominalOutstanding' = nominalOutstanding - payable`, then records `HEALTHY_PARTIAL` or `HEALTHY_FULL`; full payment consumes the position while retaining its tombstone. If reconciliation enters/persists deficit, the call succeeds with `RECONCILIATION_ONLY`, no push, and no nonce use; a retry of the healthy API in an already-deficit boundary returns `DEFICIT_CLAIM_REQUIRED`. The deficit API routes only through §4.5 and returns `DEFICIT_PAID`, `ZERO_PAYABLE`, or `RECONCILIATION_ONLY`.

`nominalRemaining` is the position's unpaid nominal cap after the call (`nominalUnits - paidAssets` in deficit); `paidAmount == 0` for every non-payment code. Permissionless fixed-receiver calls consume no authorization nonce. A signed alternate-receiver nonce is consumed only after a positive exact transfer and accounting update succeeds. `ZERO_PAYABLE`, `DEFICIT_CLAIM_REQUIRED`, `RECONCILIATION_ONLY`, revert, or transfer failure consumes none. A consumed known position returns `ZERO_PAYABLE`; it can never be recreated or paid twice.

### 6.8 Signature verification

- EOAs: accept canonical 65-byte ECDSA and 64-byte EIP-2098 signatures only; enforce valid `v`, low-`s`, nonzero recovered signer, and exact expected signer.
- Contracts: pass arbitrary signature bytes to ERC-1271 and require exact magic value `0x1626ba7e`; revert, malformed return, or wrong magic rejects.
- Mixed EOA/ERC-1271 bilateral signatures are valid.
- Failed calls do not consume nonces.
- Wrong chain, protocol version, verifying contract, deal, action, or expiry rejects.

### 6.9 Package selection and contest terms

Package selection is a typed cross-commitment, not an opaque hash that Core interprets:

```text
PACKAGE_SELECTION_SCHEMA_ID      = keccak256("pluriswap.package-selection.v1")
PACKAGE_SELECTION_SCHEMA_VERSION = 1
REFERENCE_PACKAGE_SPEC_HASH      = bytes32(0)

PackageEconomicsV1(
  uint256 activationFee,
  address activationFeeRecipient,
  uint256 completionFee,
  address completionFeeRecipient,
  bytes32 packageContestTermsHash
)

PACKAGE_ECONOMICS_V1_TYPEHASH = keccak256("PackageEconomicsV1(uint256 activationFee,address activationFeeRecipient,uint256 completionFee,address completionFeeRecipient,bytes32 packageContestTermsHash)")

PackageSelectionV1(
  bytes32 schemaId,
  uint16  schemaVersion,
  bytes32 packageId,
  uint32  packageVersion,
  address publisher,
  uint32  profileFlags,
  bytes32 policySemanticHash,
  bytes32 packageEconomicsHash,
  bytes32 arbitrationTermsHash,
  bytes32 poolAuthorityHash,
  bytes32 reservationsHash,
  bytes32 modulesHash,
  bytes32 extensionsHash,
  bytes32 referenceSpecHash
)

PACKAGE_SELECTION_V1_TYPEHASH = keccak256("PackageSelectionV1(bytes32 schemaId,uint16 schemaVersion,bytes32 packageId,uint32 packageVersion,address publisher,uint32 profileFlags,bytes32 policySemanticHash,bytes32 packageEconomicsHash,bytes32 arbitrationTermsHash,bytes32 poolAuthorityHash,bytes32 reservationsHash,bytes32 modulesHash,bytes32 extensionsHash,bytes32 referenceSpecHash)")

packageEconomicsHash = hashStruct(PackageEconomicsV1)
packageSelectionHash = hashStruct(PackageSelectionV1)
```

For a selected package, schema constants match, `packageId`, `packageVersion`, `publisher`, and `policySemanticHash` are nonzero, and every cross-committed field exactly equals `DealTerms` or its validated preimage. `PackageEconomicsV1` exactly repeats the signed activation/completion fees, recipients, and contest hash. `profileFlags`, arbitration, pool authority, reservations, modules, and extensions match exactly. A mismatch rejects before any module call or value movement.

For no package, `packageSelectionHash == bytes32(0)`, there is no package-selection/economics preimage, `packageContestTermsHash == bytes32(0)`, and no `PACKAGE_POLICY` binding exists. Every selection MUST satisfy `referenceSpecHash == REFERENCE_PACKAGE_SPEC_HASH`; in this candidate that means independent packages use zero and no nonzero reference-spec commitment can activate. `policySemanticHash` is a signed content address for clients and modules; Core verifies the typed cross-commitments, admitted bindings, and direct deal fields, but MUST NOT claim to understand or validate opaque policy content merely from `packageId` or `policySemanticHash`.

No reference SKU is executable under this candidate. The normative artifact `docs/v2/technical/REFERENCE_PACKAGE.md` does not yet exist, so `REFERENCE_PACKAGE_SPEC_HASH` is deliberately zero; a deployment MUST reject or omit every package advertised as a PluriSwap reference SKU, including any claimed reference IDs, fees, burn sink, or adapter set. Enabling one requires that exact artifact, a new nonzero frozen hash and candidate, complete typed SKU preimages, manifest identity, and conformance evidence. Business descriptions in `PROTOCOL.md` alone do not authorize Core enablement.

A selected package contest-fee channel uses this exact signed preimage:

```text
PackageContestTerms(
  address feeToken,
  address feeRecipient,
  uint256 disputeOpenFee,
  uint256 arbitrationOpenFee,
  bytes32 scheduleHash
)

PACKAGE_CONTEST_TERMS_TYPEHASH = keccak256("PackageContestTerms(address feeToken,address feeRecipient,uint256 disputeOpenFee,uint256 arbitrationOpenFee,bytes32 scheduleHash)")

packageContestTermsHash = hashStruct(PackageContestTerms)
```

When no package is selected, or the selected package binds no contest toll, `packageContestTermsHash` and every preimage field are zero. A nonzero contest hash requires nonzero `packageSelectionHash`; `feeToken`, `feeRecipient`, and `scheduleHash` are nonzero, the recipient is not protocol custody, and at least one fee is positive. Core verifies that exact hash through `PackageEconomicsV1` and `PackageSelectionV1`; it does not compare the schedule to an opaque package hash.

Base `openDispute` enforces `disputeOpenFee` itself through §5.2 `exactExternalFee(feeToken, caller, feeRecipient, disputeOpenFee)` before Core enters `DISPUTED`. It makes no package-module call. `openArbitration` analogously enforces `exactExternalFee(feeToken, caller, feeRecipient, arbitrationOpenFee)`; that toll is distinct from the `quoteToken` external court quote in §6.3. Neither transfer targets Ledger or changes Ledger accounting. A zero amount skips transfer. Any inexact/reverting transfer leaves state unchanged.

Base order is Core guard/authority/state/deadline validation, exact toll, then state write. Enhanced order is those Core checks, package validation, exact toll, Core state recheck, then state write. Any later failure reverts the toll and enhancement atomically.

The optional package-enhancement command may authenticate additional evidence but cannot change these amounts, recipient, source, Core authority, deadline, or state transition. Package-module failure cannot waive the signed toll and cannot block the ordinary base dispute path.

### 6.10 Direct and pool holder-authority snapshot

Core permission bits are:

```text
HOLDER_RELEASE     = 1 << 0
HOLDER_CONTEST     = 1 << 1
HOLDER_ARBITRATION = 1 << 2
```

All higher bits are zero. The pool preimages are:

These masks encode only active-deal Core actions. Per-deal operator acceptance is mandatory through `OperatorDealAcceptance`, not a fourth permission bit; pool-local permissions remain outside Core.

```text
PoolMandate(
  address pool,
  uint8   poolKind,
  bytes32 poolIdentityHash,
  bytes32 poolTermsHash,
  address controller,
  address operator,
  uint32 controllerPermissions,
  uint32 operatorPermissions,
  address operatorFeeRecipient,
  uint16 operatorFeeBps,
  uint256 operatorFeeCap,
  bytes32 operatorFaultPolicyHash,
  uint256 nonce,
  uint64 expiry
)

POOL_MANDATE_TYPEHASH = keccak256("PoolMandate(address pool,uint8 poolKind,bytes32 poolIdentityHash,bytes32 poolTermsHash,address controller,address operator,uint32 controllerPermissions,uint32 operatorPermissions,address operatorFeeRecipient,uint16 operatorFeeBps,uint256 operatorFeeCap,bytes32 operatorFaultPolicyHash,uint256 nonce,uint64 expiry)")

PoolHolderAuthority(
  address pool,
  uint8   poolKind,
  bytes32 poolIdentityHash,
  bytes32 poolTermsHash,
  address activationAuthority,
  address controller,
  address operator,
  uint32 controllerPermissions,
  uint32 operatorPermissions,
  address mutualResolutionAuthority,
  address operatorFeeRecipient,
  uint16 operatorFeeBps,
  uint256 operatorFeeCap,
  uint256 reservedOperatorFee,
  bytes32 operatorFaultPolicyHash,
  bytes32 mandateHash
)

POOL_HOLDER_AUTHORITY_TYPEHASH = keccak256("PoolHolderAuthority(address pool,uint8 poolKind,bytes32 poolIdentityHash,bytes32 poolTermsHash,address activationAuthority,address controller,address operator,uint32 controllerPermissions,uint32 operatorPermissions,address mutualResolutionAuthority,address operatorFeeRecipient,uint16 operatorFeeBps,uint256 operatorFeeCap,uint256 reservedOperatorFee,bytes32 operatorFaultPolicyHash,bytes32 mandateHash)")

OperatorDealAcceptance(
  bytes32 termsHash,
  bytes32 poolAuthorityHash,
  uint8   poolKind,
  address operator,
  uint32 permissions,
  address operatorFeeRecipient,
  uint256 reservedOperatorFee,
  bytes32 operatorFaultPolicyHash,
  uint256 nonce,
  uint64 expiry
)

OPERATOR_DEAL_ACCEPTANCE_TYPEHASH = keccak256("OperatorDealAcceptance(bytes32 termsHash,bytes32 poolAuthorityHash,uint8 poolKind,address operator,uint32 permissions,address operatorFeeRecipient,uint256 reservedOperatorFee,bytes32 operatorFaultPolicyHash,uint256 nonce,uint64 expiry)")
```

`mandateHash = hashStruct(PoolMandate)` and `poolAuthorityHash = hashStruct(PoolHolderAuthority)`. For a pool-origin deal:

- the authority's `pool == DealTerms.holder`; `poolKind`, pool, identity/terms hashes, `activationAuthority`, `controller`, and `mutualResolutionAuthority` are nonzero;
- when a mandate/acceptance exists, mandate pool/kind/identities/controller/operator/permissions/economics match the authority, while acceptance `poolKind` and `poolAuthorityHash` match exactly;
- every principal/activation-fee `FundingSpec.source == FundingSpec.authority == pool`;
- `holderReceiver` is the pool's fixed return receiver or its fixed Ledger-beneficiary receiver, never the controller's or operator's personal receiver;
- kind `OWNED` requires `activationAuthority == controller`, `mutualResolutionAuthority == controller`, and `controllerPermissions == 0x07`;
- kind `CUSTOM` requires `activationAuthority == pool` and `mutualResolutionAuthority == pool`; its controller permissions may be any subset of `0x07`;
- operator permissions may be any subset of `0x07`; unknown permission bits reject for either kind;
- if `operator == address(0)`, operator permissions, recipient, fee bps/cap/reserve, fault policy, and mandate hash are zero;
- if `operator != address(0)`, the controller-authorized mandate is unexpired and exactly matches the snapshot, `operatorFaultPolicyHash` is nonzero, and the operator signs the exact unexpired `OperatorDealAcceptance` under the Escrow domain;
- operator permissions, fee recipient, and fault policy match both mandate and acceptance; reserved fee matches acceptance, and fee bps/cap match mandate;
- `operatorFeeBps <= 10_000` and `reservedOperatorFee = min(operatorFeeCap, floor(DealTerms.principal * operatorFeeBps / 10_000))` using full precision; an absent fee schedule has zero recipient/bps/cap/reserve;
- a positive `reservedOperatorFee` requires a nonzero recipient and one exact matching `OPERATOR_FEE` reservation; zero reserved fee requires no such reservation; and
- operator acceptance is required whenever an operator is snapshotted, even when its fee and permissions are zero.

`poolAuthorityHash` is nonzero exactly when the `POOL` flag is selected with signed kind `OWNED` or `CUSTOM`. The admitted `POOL` binding's policy/config hash MUST support that exact kind. A direct deal requires `POOL` unset, `poolAuthorityHash == bytes32(0)`, and no pool preimage. Kind `CROWDFUNDED`, the `CROWDFUNDED_POOL` flag, and every mismatch reject.

The controller signs `PoolMandate` under the Escrow domain. Its nonce identifies a mandate version and is reusable for bounded deals until expiry/revocation; successful deal activation does not consume that mandate version. The per-deal `OperatorDealAcceptance` nonce and §6.10 activation nonce are one-use and are consumed only by successful activation. Core validates current mandate eligibility only at activation, then stores the exact snapshot and never consults later mandate state for the active deal.

The operator signature consents to the exact acceptance work, permissions, fee recipient/reserve, and closed fault policy for that deal. It does not give a profile module discretion to classify fault or redirect compensation beyond §§2.6, 6.6, 7.3, and 8.5.

The exact expected actor is closed:

| Core authorization | Direct deal | Pool-origin deal |
| --- | --- | --- |
| Activation signature | `holder` | `activationAuthority` |
| Unilateral release from `FIAT_SENT` | caller is `holder` | caller is snapshotted controller/operator with `HOLDER_RELEASE` |
| Open Core `DISPUTED` | caller is `holder` | caller is snapshotted controller/operator with `HOLDER_CONTEST` |
| Open selected arbitration | caller is `holder` | caller is snapshotted controller/operator with `HOLDER_ARBITRATION` |
| Holder signature on mutual resolution | `holder` | `mutualResolutionAuthority` |

Controller and operator permissions are independent; no permission implies another. If both roles use the same address, the action is valid when either corresponding snapshotted mask contains the required bit. Unilateral calls require the exact actor as `msg.sender`; relaying is available only for the typed activation/mutual signatures. Receivers, funding sources, pool modules, Coordinator entries, later mandates, and later controller/operator changes grant no Core action authority. Timeouts remain permissionless.

The activation nonce namespace is `(DealTerms.holder, expectedActivationAuthority, DealTerms.nonce)`. For a direct deal both authority addresses are `holder`; for a pool deal the economic holder remains `pool` while signature authority is the snapshotted `activationAuthority`.

---

## 7. Generic module admission, hooks, and runtime results

### 7.1 API and binding

```text
CORE_MODULE_API_V1 = keccak256("pluriswap.core.module.v1")
CORE_MODULE_MAGIC  = bytes4(keccak256("PLURISWAP_CORE_MODULE_V1"))
```

Every binding includes the fields in §6.2 and is signed. Coordinator admission keys the complete binding tuple. Address-only or role-only admission is non-conforming.

At activation Core MUST verify:

- direct module is a contract;
- live `extcodehash(module) == runtimeCodeHash`;
- API identity and capability mask are supported;
- policy/config and manifest identities are complete;
- Coordinator admits the exact tuple;
- role is sorted/unique and matches the enabled flag; and
- the module's live configuration commitment matches the binding when the API exposes one.

Upgradeable custody-adjacent modules are not production-qualifiable unless exact implementation and configuration identity is independently proven immutable. Proxy runtime code hash alone is insufficient.

After activation, Core stores the complete binding hash and never queries Coordinator again for that deal. Runtime still checks live code/config identity against the snapshot.

### 7.2 Closed commands

Core-to-module command ids are:

```text
0 ACTIVATION_VALIDATE
1 PACKAGE_CONTEST_ENHANCEMENT_VALIDATE
2 PAYMENT_PROOF_RELEASE_VALIDATE
3 ARBITRATION_OPEN_VALIDATE
4 ARBITRATION_RULING_VALIDATE
```

`capabilityMask` bit `n` declares support for command id `n`; all other bits MUST be zero.

No terminal callback or arbitration-timeout module command exists.

Role compatibility is closed:

| Role | Permitted/required command mask |
| --- | --- |
| `PAYMENT_PROOF_VERIFIER` | exactly `0x05` (`ACTIVATION_VALIDATE`, proof release) |
| `ARBITRATION_ADAPTER` | exactly `0x19` (activation, arbitration open, arbitration ruling) |
| `PACKAGE_POLICY` | `0x01` or `0x03`; bit `1` enables only the optional contest-enhancement entrypoint |
| `BOND_VAULT`, `POOL`, `HUMANITY_VERIFIER`, `REPUTATION_POLICY`, `RATE_POLICY` | exactly `0x01` (activation only) |

A selected binding without activation bit `0`, or with a command incompatible with its role, rejects activation.

For each call, Core computes:

```text
MODULE_CONTEXT_TYPEHASH = keccak256(
  "PluriSwapModuleContext(uint64 chainId,uint32 protocolVersion,address escrow,address ledger,bytes32 dealId,bytes32 termsHash,bytes32 bindingHash,address caller,uint8 command,uint8 state,uint64 observedAt,bytes32 actionDataHash)"
)

contextHash = keccak256(abi.encode(
  MODULE_CONTEXT_TYPEHASH,
  chainId,
  protocolVersion,
  address(Escrow),
  address(Ledger),
  dealId,
  termsHash,
  bindingHash,
  msg.sender,
  command,
  currentState,
  uint64(block.timestamp),
  actionData.length == 0 ? bytes32(0) : keccak256(actionData)
))
```

Activation uses the deterministic `dealId` and `NONE` state before funding. `caller` is always the external `msg.sender` that invoked the named Core entrypoint, never a module, funding source, receiver, or authority substituted by Core. Core passes the bounded `actionData` preimage with this context; the module result MUST echo `contextHash`.

### 7.3 Fixed result

A module returns one fixed-size result:

```text
ModuleResult {
  bytes4  magic;
  uint8   command;
  uint8   code;
  uint8   operatorFaultCode;
  bytes32 contextHash;
  bytes32 evidenceHash;
  bytes32 operatorFaultEvidenceHash;
  uint64  validAfter;
  uint64  validUntil;
}

MODULE_RESULT_SCHEMA_HASH = keccak256("ModuleResult(bytes4 magic,uint8 command,uint8 code,uint8 operatorFaultCode,bytes32 contextHash,bytes32 evidenceHash,bytes32 operatorFaultEvidenceHash,uint64 validAfter,uint64 validUntil)")
```

Result code `0` is invalid. Closed positive result codes are:

```text
1 ACCEPT
2 PAYMENT_VERIFIED
3 ARBITRATION_OPENED
4 ARBITRATION_HOLDER_WIN
5 ARBITRATION_PROVIDER_WIN
6 ARBITRATION_REFUSED
```

Zero/unknown codes, wrong magic, wrong command/context, malformed data, revert, reentrancy, or a result outside the command's allowed matrix rejects the action.

`evidenceHash` MUST be nonzero for every positive runtime result; activation MAY use zero only when the selected policy declares that no external evidence exists. In 0.3.0-rc1, modules control no Core clock: `validAfter` and `validUntil` MUST both be zero for every command. Nonzero timing data rejects. Arbitration timing comes only from the signed §6.3 duration and Core-snapshotted deadline.

`operatorFaultCode` and `operatorFaultEvidenceHash` MUST both be zero for commands `0..3`. `ARBITRATION_RULING_VALIDATE` permits either `(0, bytes32(0))` or `(2, nonzero evidence hash)`. Code `2` requires the selected arbitration policy to authenticate the exact fault schema committed by the pool's `operatorFaultPolicyHash`; the module cannot return mutual-fault code `1`. The adapter returns no reservation predicate or disposition—Core applies the stored §8.5 rule for the normalized class.

### 7.4 Closed command/state/role/result/timing matrix

`Fault result` is `operatorFaultCode / operatorFaultEvidenceHash`; `Result timing` is `validAfter / validUntil`.

| Command or Core action | Invoked role | Allowed source state and Core timing | Allowed positive result | Fault result | Result timing | Call order | Core-owned effect |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `ACTIVATION_VALIDATE` (`0`) | Every selected binding, once, ascending role ordinal | `NONE`; creation unexpired | `ACCEPT` (`1`) | `0 / 0` | `0 / 0` | After Ledger preflight status `0`, `1`, or `3`; before any funding | No transition; activation continues only after every selected role accepts |
| Base Core `openDispute` | **None** | `FIAT_SENT`, strictly before release deadline | **No module result** | N/A | N/A | No module call; deterministic signed package toll, if any, is enforced by Core | Core enters `DISPUTED` and snapshots the dispute deadline |
| `PACKAGE_CONTEST_ENHANCEMENT_VALIDATE` (`1`) | `PACKAGE_POLICY` only, through an explicit enhanced entrypoint | `FIAT_SENT` strictly before release deadline for enhanced dispute/arbitration open; `DISPUTED` strictly before dispute deadline for enhanced arbitration open | `ACCEPT` (`1`) | `0 / 0` | `0 / 0` | First runtime module call on that optional edge | Records package evidence and continues the requested enhanced edge; it never gates base `openDispute` |
| `PAYMENT_PROOF_RELEASE_VALIDATE` (`2`) | `PAYMENT_PROOF_VERIFIER` only | `FUNDED`, `FIAT_SENT`, or `DISPUTED`; deal nonterminal | `PAYMENT_VERIFIED` (`2`) | `0 / 0` | `0 / 0` | Sole action module call after Ledger preflight status `0`, `1`, or `3` | Core settles `RELEASED / PAYMENT_PROOF_RELEASE` with provider bps `10_000` |
| `ARBITRATION_OPEN_VALIDATE` (`3`) | `ARBITRATION_ADAPTER` only | `FIAT_SENT` strictly before release deadline, or `DISPUTED` strictly before dispute deadline | `ARBITRATION_OPENED` (`3`) | `0 / 0` | `0 / 0` | Exact §6.3 order: preflight, optional package validation, package toll, court-fee transfer, then adapter | Core stores the typed request/result, consumes quote nonce, enters `ARBITRATION_ACTIVE`, and snapshots `arbitrationDeadline = now + arbitrationDuration` |
| `ARBITRATION_RULING_VALIDATE` (`4`) | `ARBITRATION_ADAPTER` only | `ARBITRATION_ACTIVE`; before another terminal action wins | holder win (`4`), provider win (`5`), or refused (`6`) | `0 / 0` or `2 / nonzero` | `0 / 0` | Sole action module call after Ledger preflight status `0`, `1`, or `3` | Core normalizes class, matches signed reservation predicates, and computes fee eligibility; module chooses no rule, receiver, or amount |
| Core arbitration timeout | **None** | `ARBITRATION_ACTIVE` and `now >= arbitrationDeadline` | **No module result** | N/A | N/A | No module call | Anyone may settle `STALEMATE / ARBITRATION_TIMEOUT` at fixed provider bps `5_000` |
| Core mutual cancel | **None** | `FUNDED`, `FIAT_SENT`, `DISPUTED`, or `ARBITRATION_ACTIVE`; valid unexpired dual-signed payload | **No module result** | `0 / 0` | N/A | No module call | Core settles `CANCELLED / MUTUAL_CANCEL` |
| Core co-signed release | **None** | `FIAT_SENT`, `DISPUTED`, or `ARBITRATION_ACTIVE`; valid unexpired dual-signed payload | **No module result** | `0 / 0` | N/A | No module call | Core settles `RELEASED / COSIGNED_RELEASE` |
| Core mutual split | **None** | `FIAT_SENT`, `DISPUTED`, or `ARBITRATION_ACTIVE`; valid unexpired dual-signed payload | **No module result** | `0 / 0` or signed `1 / nonzero` | N/A | No module call | Core settles `RESOLVED_SPLIT / MUTUAL_SPLIT` and applies deterministic fee eligibility |

Core alone maps the result to state/outcome, normalizes the closed fault classification, matches signed reservation predicates, and computes receivers, fees, and provider basis points. A module cannot return arbitrary token addresses, call targets, states, outcomes, predicates, formulas, receivers, fee amounts, split values, or fault codes/evidence outside §7.3.

### 7.5 Bounded calls and failure isolation

- Activation invokes at most one validation call per selected binding, in role order.
- Enhanced dispute invokes only `PACKAGE_POLICY`. Arbitration-open follows the full request/payment/adapter order in §6.3; payment-proof and arbitration-ruling invoke only their one action role. No other ordering is conforming.
- Per-call module data is bounded; result size is fixed.
- Calls use ordinary external calls, never `delegatecall`; modules receive no token approval from Core.
- Reentrancy into Core or Ledger rejects.
- Activation hook failure reverts activation atomically.
- Runtime module failure reverts only that optional edge. It cannot disable state-valid Core cancel, release, mutual-resolution, claim, dispute, or timeout paths.
- The §10.4 Phase-B settlement commit and Ledger reassignment make no module calls.
- Arbitration timeout never queries the adapter, Coordinator, or another module and remains executable after adapter failure, delisting, or disappearance.

Base `openDispute` MUST execute from its Core authority/state/deadline checks without querying `PACKAGE_POLICY`, another module, or Coordinator. A selected package contest toll is enforced directly from the signed §6.9 preimage and therefore cannot make module availability a dispute gate.

An explicit `openDisputeWithPackageEnhancement` MAY invoke command `1`. Wrong result, revert, or unavailable package module fails that enhanced call atomically, including any attempted toll, but leaves the ordinary `openDispute` call immediately available under the same Core deadline and signed deterministic toll. No package is supported if it claims module acceptance is required before Core may enter `DISPUTED`.

The named payment-proof, arbitration-open, and arbitration-ruling entrypoints MUST execute this dispatcher when their profile is selected. They MUST NOT remain unconditional stubs. `arbitrationTimeout` and base `openDispute` are Core-computed actions, not dispatch entrypoints. When a profile is absent, its named arbitration/proof edges reject as disabled.

---

## 8. High-level API direction

Exact Solidity declarations, selectors, errors, and event declarations become accepted only when the interface artifacts under `src/interfaces/` preserve the following directions and the applicable §§15.2–15.6 gates pass. The 0.2.x interfaces and the superseded plan's interface shapes are not normative.

### 8.1 CoreEscrow

Core exposes:

- `activate(terms, principalFundingSpec, activationFeeFundingSpec, principalFundingAuth, activationFeeFundingAuth, packageSelection, packageEconomics, packageContestTerms, poolAuthority, poolMandate, operatorAcceptance, arbitrationTerms, reservationSpecs, reservationRules, activationSignature, providerSignature, moduleData)`;
- Core transitions: mark fiat, provider cancel, fiat timeout, holder release, claim, module-free base `openDispute`, dispute timeout, mutual resolve;
- optional `openDisputeWithPackageEnhancement(...)`, whose failure never disables base `openDispute`;
- only mutual split accepts bounded `ReservationDisposition[]` and disposition-consent signatures for stored `MUTUAL_AUTH` rules; mutual cancel/co-signed release require zero disposition hash and accept no allocation rewrite;
- live named dispatch: submit payment proof, typed `openArbitration(request, adapterData, packageData)`, and submit arbitration ruling;
- permissionless Core-computed `arbitrationTimeout(dealId)` with no module data or result;
- deal, state, terms-hash, funding, package-selection/economics/contest, pool-kind/authority/permission, arbitration-terms/open-request/open-result/deadline, reservation-snapshot, module-snapshot, nonce, and immutable-identity views; and
- stored terminal-record, terminal-hash, and terminal reservation-disposition views.

Core never exposes a generic arbitrary module call or token movement function.

### 8.2 CreditLedger

Ledger exposes:

- `preflightValueAction(tokens[])`, callable only by bound Escrow, to reconcile a bounded sorted/unique set before any stateful module call and return the §4.2 status; `0`, `1`, and `3` continue, `4` returns reconciliation-only, and `2` is invalid;
- `fundDealAndReservations(...)`, callable only by bound Escrow, to reconcile every touched boundary, validate the exact §6.4 funding specs/authorizations, exact-pull or same-vault debit principal/activation fee/reservations, and create the deterministic §3.3 positions atomically;
- `settleDealAndReservations(...)`, callable only by bound Escrow, to reconcile and consume/reassign the whole deal position plus every reservation against one stored terminal hash and exact disposition hash;
- healthy `withdrawPosition(positionId, maxAmount)` and signed `withdrawPositionTo(auth, signature)`, returning §6.7 `PositionPayoutResult`;
- permissionless `checkpointBoundary(token)`;
- permissionless `depositRecovery(token, from, amount)`;
- permissionless `claimRecovery(positionId, maxAmount)` and signed `claimRecoveryTo(auth, signature)`, returning the same typed result;
- boundary, position, reservation, accounted-asset, quarantined-surplus, checkpoint, and component views.

Ledger MUST NOT expose a module-callable reservation creator/disposer, the old general `credit(...)`, or beneficiary-to-beneficiary `reallocateRecovery(...)` authority. Completion-fee and terminal credits arise only from whole-deal settlement allocations. New healthy fee/reservation positions require exact attributable funding in the same atomic operation.

### 8.3 Coordinator

Coordinator exposes complete-binding admission lookup and future-only allow/disallow administration. Administration cannot call Core/Ledger, settle a deal, change a snapshot, or pause an exit.

### 8.4 Module API

The V1 module interface exposes bounded activation validation and bounded named-action validation returning §7.3. It MAY expose an immutable configuration commitment view. It has no generic Core callback or receiver-selection authority.

### 8.5 Generic reservation creation and disposition

Reservations are bounded Ledger positions, not arbitrary module custody. The closed reservation-kind ids are:

```text
1 BOND
2 OPERATOR_FEE
3 PROFILE_COLLATERAL
4 PROFILE_CREDIT
```

Kind `0` and unknown kinds reject. The kind labels the signed purpose; it does not grant the profile code custody or settlement authority.

The parties sign each exact reservation preimage through `reservationsHash` in `DealTerms`:

```text
ReservationSpec(
  uint8   slot,
  uint8   kind,
  address token,
  address source,
  bytes32 fundingPositionId,
  address dispositionAuthorizer,
  address returnReceiver,
  uint256 amount,
  bytes32 policyHash,
  bytes32 rulesHash
)

RESERVATION_SPEC_TYPEHASH = keccak256("ReservationSpec(uint8 slot,uint8 kind,address token,address source,bytes32 fundingPositionId,address dispositionAuthorizer,address returnReceiver,uint256 amount,bytes32 policyHash,bytes32 rulesHash)")
```

`slot` values are strictly ascending and unique; `amount`, `source`, `dispositionAuthorizer`, `returnReceiver`, and `policyHash` are nonzero. `fundingPositionId == 0` means an exact external pull from `source`. A nonzero value means an authorized same-Ledger split/debit of that exact existing position; `source` MUST be that position's fixed beneficiary/authority, nominal units MUST be conserved, and a deal, reservation, consumed, wrong-token, or wrong-authority position cannot be debited.

`ReservationSpec` intentionally has no generic `beneficiary` field. `returnReceiver` is the immutable default/unlock destination. Each generic rule that routes value to a primary destination binds that exact destination in its own `primaryBeneficiary`; rules for different outcomes may bind different beneficiaries. An `OPERATOR_FEE` reservation has no generic rules and takes its sole paid recipient from the exact signed §6.10 `operatorFeeRecipient`. This removes any ambiguous precedence between a spec-level beneficiary and a rule-level beneficiary.

Each non-operator-fee reservation has zero or more rules sorted and unique by `(slot, outcome, operatorFaultPredicate)`:

```text
ReservationRule(
  uint8   slot,
  uint8   outcome,
  uint8   operatorFaultPredicate,
  uint8   formula,
  uint16  bps,
  address primaryBeneficiary
)

RESERVATION_RULE_TYPEHASH = keccak256("ReservationRule(uint8 slot,uint8 outcome,uint8 operatorFaultPredicate,uint8 formula,uint16 bps,address primaryBeneficiary)")
```

Closed formula ids and canonical fields are:

| Formula | Id | Disposition | Canonical fields |
| --- | ---: | --- | --- |
| `RETURN_ALL` | `0` | Entire reservation to `returnReceiver` | `bps = 0`, beneficiary zero |
| `PRIMARY_ALL` | `1` | Entire reservation to `primaryBeneficiary` | `bps = 0`, beneficiary nonzero |
| `PRIMARY_BPS` | `2` | `floor(amount * bps / 10_000)` to primary; remainder to return receiver | `1 <= bps <= 10_000`, beneficiary nonzero |
| `PROVIDER_SHARE` | `3` | `floor(amount * providerGross / principal)` to primary; remainder to return receiver | `bps = 0`, beneficiary nonzero |
| `MUTUAL_AUTH` | `4` | Exact two-output disposition bound by `MUTUAL_SPLIT` authorization | `bps = 0`, beneficiary zero |

Before reservation evaluation, Core normalizes the terminal operator-fault classification under §§6.6 and 7.3. Rule matching is:

1. if the `(slot, outcome)` group contains `FAULT_ANY`, it MUST contain exactly that one predicate row and Core selects it;
2. otherwise Core selects the unique row whose class-specific predicate matches the normalized classification; and
3. if no row matches, disposition is `RETURN_ALL`.

`FAULT_MUTUAL` is valid only for `MUTUAL_SPLIT`. `FAULT_ARBITRATION` is valid only for `ARBITRATION_HOLDER_WIN`, `ARBITRATION_PROVIDER_WIN`, or `ARBITRATION_REFUSED`, and only when an operator/fault policy is snapshotted. Without an operator, only `FAULT_ANY` and `FAULT_NONE` are valid. Mixed any/specific rows, duplicate matches, impossible predicate/outcome pairs, and unknown predicates reject activation.

Thus two rows may share one arbitration outcome: `FAULT_NONE + RETURN_ALL` releases a reservation, while `FAULT_ARBITRATION + PRIMARY_ALL` slashes it to the signed beneficiary. The adapter supplies only authenticated class `2`; Core deterministically selects and executes the already signed row.

`OPERATOR_FEE` does not use caller-selected outcome rules:

```text
OPERATOR_FEE_RULES_V1 = keccak256("pluriswap.operator-fee.rules.v1")

operatorFeeEligible =
  operatorFaultCode == NO_OPERATOR_FAULT

operatorFeePaid =
  !operatorFeeEligible || providerGross == 0
    ? 0
    : floor(reservedOperatorFee * providerGross / principal)

operatorFeeUnlocked = reservedOperatorFee - operatorFeePaid
```

The existence of a valid `OPERATOR_FEE` reservation proves that the required per-deal operator acceptance was verified and its nonce was consumed atomically at activation; no separate acceptance-consumed boolean exists. The multiplication uses full precision before floor. Full provider gross therefore pays the full reservation; a partial gross pays the exact proportional floor. At most one `OPERATOR_FEE` reservation exists. It MUST match the §6.10 snapshot exactly:

- `token == DealTerms.token`;
- `source == pool`;
- `dispositionAuthorizer == operator`;
- `returnReceiver == holderReceiver`;
- `amount == reservedOperatorFee`;
- `policyHash == operatorFaultPolicyHash`; and
- `rulesHash == OPERATOR_FEE_RULES_V1`, with no `ReservationRule[]` entries for that slot.

The snapshotted `operatorFeeRecipient` and `returnReceiver` MUST differ. No-fault disposition pays the calculated amount only to `operatorFeeRecipient` and returns the remainder only to `returnReceiver`. Fault code `1` is accepted only from the fully signed mutual-split path; fault code `2` only from the authenticated arbitration result. Either code makes paid amount zero and unlocks the entire reservation. No caller, timeout, ordinary outcome label, or generic reservation formula can set fee fault or choose another amount/recipient.

`MUTUAL_AUTH` is permitted only when `outcome == MUTUAL_SPLIT`. It rejects for `MUTUAL_CANCEL`, `COSIGNED_RELEASE`, and every non-mutual outcome. Those outcomes use only their immutable ordinary rule or the `RETURN_ALL` default, so their resolution payload cannot rewrite reservation allocation. A missing matching outcome rule means `RETURN_ALL`. Rules are policy data fixed at activation; profile internals may decide which conforming rules to propose, but cannot change them later.

For rule and reservation hashes:

```text
ruleHash_i = keccak256(abi.encode(
  RESERVATION_RULE_TYPEHASH,
  slot,
  outcome,
  operatorFaultPredicate,
  formula,
  bps,
  primaryBeneficiary
))

genericRulesHash =
  ruleCount == 0
    ? bytes32(0)
    : keccak256(ruleHash_0 || ... || ruleHash_n)

rulesHash =
  kind == OPERATOR_FEE
    ? OPERATOR_FEE_RULES_V1
    : genericRulesHash

specHash_i = keccak256(abi.encode(
  RESERVATION_SPEC_TYPEHASH,
  slot,
  kind,
  token,
  source,
  fundingPositionId,
  dispositionAuthorizer,
  returnReceiver,
  amount,
  policyHash,
  rulesHash
))

reservationsHash =
  reservationCount == 0
    ? bytes32(0)
    : keccak256(specHash_0 || ... || specHash_n)

RESERVATION_ID_V1_TYPEHASH = keccak256("PluriSwapReservationIdV1(bytes32 custodyBoundaryId,bytes32 dealId,uint8 slot,bytes32 specHash)")

reservationId_i = keccak256(abi.encode(
  RESERVATION_ID_V1_TYPEHASH,
  custodyBoundaryId,
  dealId,
  slot,
  specHash_i
))
```

The `||` operands are fixed 32-byte hashes. Specs are ascending by slot; rules are lexicographically ascending by `(slot, outcome, operatorFaultPredicate)`, so concatenation is unambiguous. Counts MUST satisfy §2.2. The active reservation's Ledger position id is the §3.3 `RESERVATION` id with `sourceId = reservationId_i`; each matured output uses the corresponding `RESERVATION_TERMINAL` id. Id collisions and coalescing follow §3.3.

External or internal-position funding authority uses the Ledger EIP-712 domain:

```text
ReservationFundingAuth(
  bytes32 termsHash,
  uint8   slot,
  address source,
  bytes32 fundingPositionId,
  address token,
  uint256 amount,
  uint256 nonce,
  uint64  expiry
)

RESERVATION_FUNDING_AUTH_TYPEHASH = keccak256("ReservationFundingAuth(bytes32 termsHash,uint8 slot,address source,bytes32 fundingPositionId,address token,uint256 amount,uint256 nonce,uint64 expiry)")
```

The `source`, or the fixed authority of `fundingPositionId`, signs; a party's deal signature does not authorize an unrelated sponsor. Successful funding consumes the funding nonce. Failure, including another boundary's failure in the same activation, consumes none.

For a `MUTUAL_SPLIT` rule using `MUTUAL_AUTH`, the provider and §6.10 mutual-resolution authority bind `reservationDispositionsHash` in §6.6 and every affected `dispositionAuthorizer` signs the following under the Escrow EIP-712 domain:

```text
ReservationDispositionConsent(
  bytes32 dealId,
  bytes32 resolutionAuthHash,
  bytes32 reservationDispositionsHash,
  address authorizer,
  uint256 nonce,
  uint64  expiry
)

RESERVATION_DISPOSITION_CONSENT_TYPEHASH = keccak256("ReservationDispositionConsent(bytes32 dealId,bytes32 resolutionAuthHash,bytes32 reservationDispositionsHash,address authorizer,uint256 nonce,uint64 expiry)")
```

The consent rejects unless `ResolutionAuth.action == MUTUAL_SPLIT`. The disposition preimage is fixed:

```text
ReservationDisposition(
  bytes32 reservationId,
  address token,
  address beneficiary0,
  uint256 amount0,
  address beneficiary1,
  uint256 amount1
)

RESERVATION_DISPOSITION_TYPEHASH = keccak256("ReservationDisposition(bytes32 reservationId,address token,address beneficiary0,uint256 amount0,address beneficiary1,uint256 amount1)")
```

Core derives automatic dispositions from the matched stored rule and derives a `MUTUAL_AUTH` disposition from the fully signed preimage only on mutual split. Nonzero outputs are coalesced by beneficiary and sorted ascending by address; unused output fields are canonical zero. Every beneficiary is non-custodial, amounts sum exactly to the reservation amount, and output count is at most two.

```text
dispositionHash_i = hashStruct(ReservationDisposition_i)

reservationDispositionsHash =
  reservationCount == 0
    ? bytes32(0)
    : keccak256(dispositionHash_0 || ... || dispositionHash_n)
```

Dispositions are ordered by reservation slot. Core stores the complete disposition preimages with the terminal record. The hash alone is not a substitute for stored, queryable preimages.

The lifecycle is closed:

1. activation validates signed specs/rules, all funding/disposition authorities, profile consistency, and module activation results;
2. Ledger reconciles every distinct reservation-token boundary and, only while each is healthy, exact-pulls assets or conservatively splits an authorized funded position;
3. Ledger creates one non-withdrawable, non-claimable `RESERVATION` position per spec atomically with deal funding;
4. while active, no party, module, Coordinator, or source can resize, withdraw, replace, or retarget it;
5. a terminal Core path evaluates every stored rule before terminal commit; only mutual split may supply a signed `MUTUAL_AUTH` disposition, while cancel/release use immutable rules; and
6. `settleDealAndReservations` consumes each reservation once, coalesces equal beneficiaries within that reservation only, and reassigns its existing healthy amount or deficit components into the deterministic §3.3 output positions.

No terminal module callback exists. A reservation in `DEFICIT` uses the same component-conserving split as §4.6. A reservation never mints units at disposition, and an unresolved reservation cannot be claimed.

---

## 9. Activation

### 9.1 Ordered preconditions

Activation MUST:

1. enter a Core reentrancy guard;
2. verify live chain and protocol version;
3. require unexpired creation authorization;
4. validate positive principal, distinct nonzero parties, receivers, token, exact funding-spec preimages/hashes, separate funding signatures/nonces/expiries, and source-mode constraints;
5. reject Ledger/Escrow/protocol-custody receivers;
6. validate positive Core durations, `0..10_000` residual bps, and checked deadlines;
7. validate fee amounts/recipients and profile/package consistency;
8. derive and match `custodyBoundaryId`;
9. reject `CROWDFUNDED_POOL`;
10. validate `PackageSelectionV1`, `PackageEconomicsV1`, contest terms, every cross-commitment, or their canonical absence, and enforce the reference-package gate;
11. validate direct authority or the complete pool-kind/authority/mandate/operator-acceptance preimages, capability/permission masks, signatures, and nonce;
12. validate the arbitration preimage/hash and checked duration when enabled, or canonical zero values when absent;
13. validate sorted reservation specs/rules, fault predicates, `MUTUAL_AUTH` split-only compatibility, hashes, bounds, source authorities, operator-fee match, and funding nonces;
14. validate sorted module bindings, bounds, exact package-selection `modulesHash`, and complete Coordinator admission;
15. verify the provider and exact §6.10 activation-authority signatures and prove the activation-nonce tuple/deal id unused;
16. call Ledger's bounded preflight for every touched boundary; status `3` continues, while status `4` takes the reconciliation-only branch before any module call;
17. invoke `ACTIVATION_VALIDATE` once per selected role in ascending order;
18. ask Ledger to recheck and execute every exact wallet pull or authorized same-vault debit for principal, activation fee, and reservations atomically;
19. store the complete immutable deal, funding, package, authority, arbitration, reservation, position-id, and module snapshot; and
20. consume every successful action, funding, reservation-funding, and operator-acceptance nonce and emit activation only after Ledger succeeds.

Core-only direct activation requires no package, package-contest, pool-authority, arbitration, reservation, module-binding, or extension preimage; it still requires the exact principal and any nonzero activation-fee funding preimages/authorizations with holder as funding authority and activation authority.

### 9.2 Boundary failure

No new exposure may be admitted after a latent or persisted deficit. Activation uses the §4.2 status protocol rather than enter-and-revert:

- `checkpointBoundary` is a permissionless standalone persistence path;
- Core calls `preflightValueAction` for all distinct touched boundaries before activation modules;
- if reconciliation returns status `4`, Ledger persists the deficit checkpoint, performs no funding, and returns status `4`;
- Core then returns status `4` successfully with no deal/state/nonce/fee/reservation effect; and
- `fundDealAndReservations` rechecks immediately before its first pull/debit and creates no exposure if a boundary is already `DEFICIT`.

After preflight status `0`, `1`, or `3`, any funding signature, exact-pull, source-position debit, position-id collision, or token failure reverts the attempted activation atomically. A quarantine-absorbed delta at Ledger's post-module recheck applies status-`3` accounting and may continue; an attributable residual loss reverts that branch without returning status `4` or claiming persistence. Funding failure consumes no nonce and creates no partial position or fee. An implementation MUST NOT write `DEFICIT` and then revert in the same call while claiming that the write persisted.

---

## 10. Core transitions and settlement math

### 10.1 Mandatory transition catalog

| Action | From | Authority | Timing/result |
| --- | --- | --- | --- |
| Mark fiat | `FUNDED` | provider | enter `FIAT_SENT`; start release deadline |
| Provider cancel | `FUNDED` | provider | `CANCELLED`, provider-cancel outcome |
| Fiat timeout | `FUNDED` | anyone | at/after fiat deadline; `CANCELLED` |
| Holder release | `FIAT_SENT` | exact §6.10 release actor | `RELEASED`, voluntary-release outcome |
| Claim | `FIAT_SENT` | anyone | at/after release deadline; `RELEASED`, timeout-claim outcome |
| Base open dispute | `FIAT_SENT` | exact §6.10 contest actor | strictly before release deadline; no module; enforce signed toll; enter `DISPUTED` |
| Enhanced open dispute | `FIAT_SENT` | exact §6.10 contest actor | same Core checks/toll plus optional package command; its failure leaves base open available |
| Dispute timeout | `DISPUTED` | anyone | at/after dispute deadline; residual terminal |
| Mutual cancel | `FUNDED`, `FIAT_SENT`, `DISPUTED`, `ARBITRATION_ACTIVE` | provider + §6.10 mutual authority signatures | `CANCELLED` |
| Co-signed release | `FIAT_SENT`, `DISPUTED`, `ARBITRATION_ACTIVE` | provider + §6.10 mutual authority signatures | `RELEASED` |
| Mutual split | `FIAT_SENT`, `DISPUTED`, `ARBITRATION_ACTIVE` | provider + §6.10 mutual authority signatures | `RESOLVED_SPLIT` |
| Payment-proof release | `FUNDED`, `FIAT_SENT`, `DISPUTED` | anyone relays selected proof | exact §7 matrix result; `RELEASED` |
| Open arbitration | `FIAT_SENT`, `DISPUTED` | `ArbitrationOpenRequestV1.caller == payer == msg.sender`, exact §6.10 arbitration actor | selected profile; strict pre-deadline; exact quote/toll transfers and §6.3/§7 result; enter `ARBITRATION_ACTIVE` |
| Arbitration ruling | `ARBITRATION_ACTIVE` | anyone relays selected adapter evidence | exact §7 holder/provider/refused result; terminal |
| Arbitration timeout | `ARBITRATION_ACTIVE` | anyone | at/after snapshotted arbitration deadline; no module call; `STALEMATE` |

Optional payment-proof and arbitration transitions use §7 and the business outcome map. While `DISPUTED` or `ARBITRATION_ACTIVE`, unilateral holder release and permissionless claim reject.

Eligibility uses storage at execution. The first successful state-changing transaction wins; incompatible later calls revert without economic effect. Fiat timeout intentionally races mark-fiat at/after `fiatDeadline`.

### 10.2 Arbitration clock and races

Activation validates and snapshots the exact §6.3 arbitration terms. An open call validates and stores the typed request and follows the closed transfer/module order. After the adapter returns `ARBITRATION_OPENED`, Core constructs the typed result and performs:

```text
arbitrationStartedAt = uint64(block.timestamp)
arbitrationDeadline  = arbitrationStartedAt + arbitrationDuration
state                = ARBITRATION_ACTIVE
```

The checked sum MUST fit `uint64`; the duration and sum cannot be supplied or extended by the request, quote, or module result. `arbitrationStartedAt`, `arbitrationDeadline`, request hash, result preimage/hash, and quote-nonce use are written exactly once in the same atomic commit.

At or after `arbitrationDeadline`, `arbitrationTimeout(dealId)` reads only Core storage, requires `ARBITRATION_ACTIVE`, and settles the fixed 50/50 stalemate. It MUST NOT call or require validation from the arbitration adapter, Coordinator, package policy, or any other module.

The closed races from `ARBITRATION_ACTIVE` are:

| Competing actions | Eligibility at execution | Required race behavior |
| --- | --- | --- |
| Final ruling vs timeout | Ruling remains eligible while state is active; timeout is eligible only at/after `arbitrationDeadline` | At/after the deadline both may race; first successful terminal transaction wins |
| Mutual cancel vs ruling/timeout | Valid unexpired dual-signed cancel while state is active | First successful terminal transaction wins |
| Co-signed release vs ruling/timeout | Valid unexpired dual-signed release while state is active | First successful terminal transaction wins |
| Mutual split vs ruling/timeout | Valid unexpired dual-signed split while state is active | First successful terminal transaction wins |
| Duplicate or stale relay | Source state is no longer active, nonce used, or payload expired | Reject without token, reservation, nonce, or terminal-record effect |

No adapter callback can reserve priority. Transaction ordering is the only tie-breaker.

### 10.3 Nominal settlement math

For provider basis points `b`:

```text
providerGross = floor(principal * b / 10_000)
holderGross   = principal - providerGross

completionCollected =
  providerGross == 0
    ? 0
    : min(signedCompletionFee, providerGross)

providerNet = providerGross - completionCollected

holderGross + providerNet + completionCollected = principal
```

Provider multiplication uses full-precision floor. Principal remainder goes holder-side. Completion fee is zero only when provider gross or the signed fee is zero.

Outcome basis points:

| Outcome | Provider bps |
| --- | --- |
| voluntary/co-signed/proof release, timeout claim, arbitration provider win | `10_000` |
| provider cancel, fiat-timeout cancel, mutual cancel, arbitration holder win | `0` |
| mutual split | dual-signed value |
| arbitration refused/timeout | `5_000` |
| Core dispute timeout | snapshotted `disputeTimeoutProviderBps` |

Core normalizes the terminal `operatorFaultCode` and evidence only from §6.6 mutual consent or §7.3 arbitration output, matches §8.5 reservation predicates, then computes all fixed dispositions plus `operatorFeePaid`/`operatorFeeUnlocked`. Every other path uses `NO_OPERATOR_FAULT`.

### 10.4 Pre-settlement validation and module-free commit

A terminal entrypoint may contain a pre-settlement validation phase followed by one hard commit boundary. The whole transaction is atomic, but only the first phase may invoke an optional module.

**Phase A — pre-settlement validation:**

1. enter the reentrancy guard and validate authority, timing, source state, replay protection, and selected capability without consuming a nonce;
2. call Ledger's bounded preflight for every snapshotted deal/reservation boundary;
3. if preflight reports `DEFICIT_CHECKPOINTED` (`4`), return status `4` successfully with no module call, position change, action-nonce use, or terminal write;
4. invoke and validate the optional module result when the §7 matrix requires one;
5. recheck the unchanged Core source state and unused nonce after the module returns; and
6. normalize operator fault, compute in memory the final nominal allocations and every reservation disposition, coalesce only equal-beneficiary outputs within each §3.3 source, derive every deterministic output position id, and compute the full terminal record, disposition hash, and terminal hash.

Completion of step 6 starts the settlement commit. No code path may return to module validation or accept new module data after this point.

**Phase B — module-free settlement commit:**

1. call `Ledger.settleDealAndReservations` with only the final precomputed hashes, coalesced allocations, and deterministic position ids;
2. Ledger rechecks raw balances immediately before position movement;
3. if that recheck sees a quarantine-absorbed delta, apply status-`3` accounting and continue; if it sees an attributable residual loss, revert the whole transaction, including Phase-A module effects, without returning status `4` or claiming a persisted checkpoint;
4. otherwise Ledger rejects any id collision, consumes/reassigns the deal and every reservation position exactly once, and creates only the §3.3 terminal positions;
5. Core stores terminal state, outcome, timestamp, the full terminal record, full reservation-disposition preimages, and terminal hash;
6. Core consumes the action nonce when applicable and emits the canonical terminal event; and
7. any later mandatory failure reverts both phases atomically.

Phase B invokes no module, receiver, custom pool, reputation system, package policy, post-terminal consumer, or arbitrary target. It performs no receiver token transfer. Ledger handles HEALTHY and DEFICIT through one settlement API, and Core MUST NOT branch to a general recovery-unit reallocation path.

---

## 11. Canonical terminal record

### 11.1 Stored record

Core MUST store, not merely emit, one terminal record per deal:

```text
TerminalRecord {
  uint64  chainId;
  uint32  protocolVersion;
  address escrow;
  address ledger;
  bytes32 dealId;
  uint8   terminalState;
  uint8   outcome;
  uint8   operatorFaultCode;
  bytes32 operatorFaultEvidenceHash;
  address token;
  uint256 principal;
  uint256 holderSideReturn;
  uint256 providerGross;
  uint256 providerNet;
  uint256 completionCollected;
  uint256 operatorFeePaid;
  uint256 operatorFeeUnlocked;
  address holderReceiver;
  address providerReceiver;
  address completionFeeRecipient;
  address operatorFeeRecipient;
  address operatorFeeReturnReceiver;
  bytes32 termsHash;
  bytes32 modulesHash;
  bytes32 evidenceHash;
  bytes32 reservationsHash;
  bytes32 reservationDispositionsHash;
  uint64  terminatedAt;
}
```

The record obeys:

```text
holderSideReturn + providerGross = principal
providerNet + completionCollected = providerGross
operatorFeePaid + operatorFeeUnlocked = reservedOperatorFee
```

These fields record nominal terminal allocations, not immediate token transfers. `holderSideReturn` is the exact deal-token principal nominally reassigned to the signed holder receiver; it excludes separate bond or collateral outputs. For every deal without an `OPERATOR_FEE` reservation—including a pool deal whose computed reserve is zero—`reservedOperatorFee`, both operator amounts, and both terminal-record operator addresses are zero. When an operator reservation exists, `operatorFeePaid` is its nominal amount assigned to the snapshotted operator-fee recipient and `operatorFeeUnlocked` is its nominal amount returned to the snapshotted pool/return receiver. Those addresses/amounts MUST equal the corresponding stored `ReservationDisposition` outputs exactly. In `DEFICIT`, each amount carries its proportional funded/gap components under §4.6. At most one `OPERATOR_FEE` reservation is permitted.

`reservationsHash` is the activation commitment from §8.5. `reservationDispositionsHash` commits the exact stored, queryable `ReservationDisposition[]` preimages from §8.5; it is zero exactly when `reservationsHash` is zero. There is no opaque or undefined terminal extension hash.

`operatorFaultCode` and evidence are the normalized §2.6 classification used to compute operator-fee eligibility. Code zero requires zero evidence; codes `1` and `2` require the exact nonzero authenticated evidence hash. They do not replace `outcome`.

`evidenceHash` is the validated module result's evidence hash for proof/ruling outcomes, the stored `arbitrationOpenResultHash` for arbitration timeout, the `ResolutionAuth` struct hash for mutual outcomes, and zero for other deterministic unilateral/Core-timeout outcomes. `terminatedAt` is the checked `uint64(block.timestamp)` of the winning terminal transaction.

Zero-value principal allocations retain their signed receiver fields but create no Ledger position. Equal-beneficiary deal allocations are coalesced only for position creation; the terminal record retains the semantic holder/provider/fee breakdown. Unused operator fields use canonical zero values.

### 11.2 Hash

```text
TERMINAL_RECORD_TYPEHASH = keccak256(
  "PluriSwapTerminalRecord(uint64 chainId,uint32 protocolVersion,address escrow,address ledger,bytes32 dealId,uint8 terminalState,uint8 outcome,uint8 operatorFaultCode,bytes32 operatorFaultEvidenceHash,address token,uint256 principal,uint256 holderSideReturn,uint256 providerGross,uint256 providerNet,uint256 completionCollected,uint256 operatorFeePaid,uint256 operatorFeeUnlocked,address holderReceiver,address providerReceiver,address completionFeeRecipient,address operatorFeeRecipient,address operatorFeeReturnReceiver,bytes32 termsHash,bytes32 modulesHash,bytes32 evidenceHash,bytes32 reservationsHash,bytes32 reservationDispositionsHash,uint64 terminatedAt)"
)

terminalHash = keccak256(abi.encode(
  TERMINAL_RECORD_TYPEHASH,
  all fields in the exact order above
))
```

Core stores `terminalHash`, the full fixed record, and the full bounded reservation-disposition preimages. Ledger stores the same terminal hash and disposition hash on every consumed deal/reservation position and rejects a second, omitted, duplicated, or mismatched settlement.

The terminal event includes at least indexed deal id, terminal state, outcome, and terminal hash. Fine-grained events do not alter the canonical preimage.

---

## 12. Logical storage semantics

Physical slots are not frozen by this candidate, but runtime meaning is:

### 12.1 Core

- immutable chain/version/document hashes and Ledger/Coordinator links;
- deal snapshot keyed by deal id;
- principal/activation-fee funding hashes and complete funding preimages;
- package-selection/economics/contest preimages, every cross-commitment, any enhanced-open evidence, and complete direct/pool holder-authority snapshot;
- pool kind, mandate/operator-acceptance hashes, permissions, recipients, fee, fault policy, and consumed nonces when selected;
- arbitration-terms hash, duration, complete open request/result preimages and hashes, consumed quote nonce, open timestamp, and one-write deadline when selected;
- complete reservation specs, rules, and terminal disposition preimages;
- complete module binding hashes and capability snapshots;
- activation nonce use keyed by economic holder and expected activation authority;
- action-specific resolution, operator-fault-consent, and disposition-consent nonce use;
- full terminal record and hash.

Core stores no active-principal balance or token liability scalar.

### 12.2 Ledger

- immutable Escrow/chain/version binding;
- per-token boundary mode, accounted assets, healthy nominal outstanding, quarantined surplus, fixed deficit units, and checkpoint/index state;
- every §3.3 position-id preimage, explicit live position, and permanent consumed tombstone;
- per-position nominal, paid, funded, and gap materialization state in deficit;
- principal/fee funding, payout-redirection, and reservation-funding authorization nonces; and
- consumed deal/reservation terminal and disposition hashes.

Storage MAY encode rational funded/gap values through global indices and lazy snapshots only after differential agreement with `test/helpers/ReferenceRecoveryModel.sol` under §15.2. It MUST NOT encode the old single `cumulativeDistributable`/`claimed` model.

---

## 13. Deployment intent and immutable manifest

### 13.1 V1 top-level ABI schema

```text
MANIFEST_SCHEMA_ID      = keccak256("pluriswap.mandatory-core.manifest.v1")
MANIFEST_SCHEMA_VERSION = 1
DEPLOYMENT_KIND         = 1 // MANDATORY_CORE
```

The exact top-level preimage is:

```text
MandatoryCoreManifestV1(
  bytes32 schemaId,
  uint16  schemaVersion,
  uint8   deploymentKind,
  uint64  chainId,
  uint32  protocolVersion,
  bytes32 charterHash,
  bytes32 techSpecHash,
  bytes32 buildHash,
  bytes32 deploymentMethodHash,
  bytes32 coreDeployerArtifactHash,
  bytes32 factoryArtifactHash,
  bytes32 ledgerArtifactHash,
  bytes32 coordinatorArtifactHash,
  bytes32 escrowArtifactHash,
  address coreDeployer,
  address ledger,
  address coordinator,
  address escrow,
  bytes32 capabilityHash,
  bytes32 governanceHash,
  bytes32 verificationHash,
  bytes32 predecessorManifestHash
)

MANDATORY_CORE_MANIFEST_V1_TYPEHASH = keccak256("MandatoryCoreManifestV1(bytes32 schemaId,uint16 schemaVersion,uint8 deploymentKind,uint64 chainId,uint32 protocolVersion,bytes32 charterHash,bytes32 techSpecHash,bytes32 buildHash,bytes32 deploymentMethodHash,bytes32 coreDeployerArtifactHash,bytes32 factoryArtifactHash,bytes32 ledgerArtifactHash,bytes32 coordinatorArtifactHash,bytes32 escrowArtifactHash,address coreDeployer,address ledger,address coordinator,address escrow,bytes32 capabilityHash,bytes32 governanceHash,bytes32 verificationHash,bytes32 predecessorManifestHash)")

manifestHash = keccak256(abi.encode(
  MANDATORY_CORE_MANIFEST_V1_TYPEHASH,
  schemaId,
  schemaVersion,
  deploymentKind,
  chainId,
  protocolVersion,
  charterHash,
  techSpecHash,
  buildHash,
  deploymentMethodHash,
  coreDeployerArtifactHash,
  factoryArtifactHash,
  ledgerArtifactHash,
  coordinatorArtifactHash,
  escrowArtifactHash,
  coreDeployer,
  ledger,
  coordinator,
  escrow,
  capabilityHash,
  governanceHash,
  verificationHash,
  predecessorManifestHash
))

deploymentIdentity = manifestHash
```

`schemaId`, `schemaVersion`, and `deploymentKind` MUST equal the constants above. `coreDeployer` and all triad addresses are nonzero, equal their artifact and deployment-method preimages, and match live immutable readback/reverse links. Same addresses on another chain produce a different identity.

`charterHash = keccak256(exact raw bytes of PROTOCOL.md)` and `techSpecHash = keccak256(exact raw bytes of this frozen specification)`. Line endings and final newline are part of those preimages; a normalized rendering is not.

### 13.2 Required nested preimages

Every nonzero nested hash uses `keccak256(abi.encode(TYPEHASH, fields...))` in the exact displayed order. The manifest distribution MUST include each full nested preimage, not only its hash.

Artifact identity:

```text
ArtifactV1(
  address deployedAddress,
  bytes32 creationCodeHash,
  bytes32 runtimeCodeHash,
  bytes32 constructorSchemaHash,
  bytes32 constructorArgsHash
)

ARTIFACT_V1_TYPEHASH = keccak256("ArtifactV1(address deployedAddress,bytes32 creationCodeHash,bytes32 runtimeCodeHash,bytes32 constructorSchemaHash,bytes32 constructorArgsHash)")
```

`creationCodeHash = keccak256(raw creation bytecode)`. `runtimeCodeHash = extcodehash(deployedAddress)`. `constructorSchemaHash = keccak256(bytes(exact canonical constructor ABI signature))`, and `constructorArgsHash = keccak256(exact abi.encode constructor arguments)`. The raw creation bytecode, constructor signature, typed argument values, and encoded argument bytes are required published preimages. There is one nonzero artifact preimage each for mandatory CoreDeployer, Ledger, Coordinator, and Escrow, plus one for a factory when method `2` is used.

Compiler and build identity:

```text
CompilerSettingsV1(
  bytes32 compilerNameHash,
  bytes32 compilerVersionHash,
  bool    optimizerEnabled,
  uint32  optimizerRuns,
  bool    viaIR,
  bytes32 evmVersionHash,
  bytes32 metadataBytecodeHashModeHash,
  bool    metadataLiteralContent,
  bool    appendCBOR
)

COMPILER_SETTINGS_V1_TYPEHASH = keccak256("CompilerSettingsV1(bytes32 compilerNameHash,bytes32 compilerVersionHash,bool optimizerEnabled,uint32 optimizerRuns,bool viaIR,bytes32 evmVersionHash,bytes32 metadataBytecodeHashModeHash,bool metadataLiteralContent,bool appendCBOR)")

DependencyV1(
  bytes32 nameHash,
  bytes32 versionHash,
  bytes32 sourceArchiveHash
)

DEPENDENCY_V1_TYPEHASH = keccak256("DependencyV1(bytes32 nameHash,bytes32 versionHash,bytes32 sourceArchiveHash)")

BuildV1(
  bytes32 sourceCommitHash,
  bytes32 sourceArchiveHash,
  bytes32 standardJsonInputHash,
  bytes32 compilerSettingsHash,
  bytes32 dependenciesHash
)

BUILD_V1_TYPEHASH = keccak256("BuildV1(bytes32 sourceCommitHash,bytes32 sourceArchiveHash,bytes32 standardJsonInputHash,bytes32 compilerSettingsHash,bytes32 dependenciesHash)")
```

Dependency preimages are sorted ascending by `(nameHash, versionHash, sourceArchiveHash)` and unique:

```text
dependenciesHash =
  dependencyCount == 0
    ? bytes32(0)
    : keccak256(dependencyHash_0 || ... || dependencyHash_n)
```

Text hashes are `keccak256` of the exact UTF-8 bytes with no Unicode or case normalization. `sourceCommitHash` hashes the lowercase, no-prefix commit identifier; source/dependency archive hashes identify the exact distributed bytes. `standardJsonInputHash` hashes the exact compiler input bytes.

Deployment method and creation order:

```text
DeploymentTransactionV1(
  uint16  ordinal,
  address sender,
  uint256 nonce,
  bytes32 transactionHash,
  uint64  blockNumber,
  bytes32 blockHash
)

DEPLOYMENT_TRANSACTION_V1_TYPEHASH = keccak256("DeploymentTransactionV1(uint16 ordinal,address sender,uint256 nonce,bytes32 transactionHash,uint64 blockNumber,bytes32 blockHash)")

ChildCreationV1(
  uint8   ordinal,
  uint8   role,
  uint8   method,
  address creator,
  uint256 createNonce,
  address child,
  bytes32 artifactHash,
  bytes32 salt,
  bytes32 initCodeHash,
  bytes32 transactionHash
)

CHILD_CREATION_V1_TYPEHASH = keccak256("ChildCreationV1(uint8 ordinal,uint8 role,uint8 method,address creator,uint256 createNonce,address child,bytes32 artifactHash,bytes32 salt,bytes32 initCodeHash,bytes32 transactionHash)")

DeploymentMethodV1(
  uint8   method,
  address transactionSender,
  address factory,
  address coreDeployer,
  bytes32 salt,
  bytes32 coreDeployerInitCodeHash,
  bytes32 childCreationOrderHash,
  bytes32 deploymentTransactionsHash
)

DEPLOYMENT_METHOD_V1_TYPEHASH = keccak256("DeploymentMethodV1(uint8 method,address transactionSender,address factory,address coreDeployer,bytes32 salt,bytes32 coreDeployerInitCodeHash,bytes32 childCreationOrderHash,bytes32 deploymentTransactionsHash)")
```

Closed deployment method ids are `1 DIRECT_CORE_DEPLOYER` and `2 CREATE2_FACTORY_CORE_DEPLOYER`. Both methods create mandatory CoreDeployer first; no direct-triad or absent-deployer method exists. Closed child creation method ids are `1 CREATE` and `2 CREATE2`. Closed child role ids are `1 LEDGER`, `2 COORDINATOR`, and `3 ESCROW`. Transaction preimages are sorted by unique contiguous ordinal starting at zero; child preimages are sorted by actual unique creation ordinal. Their roots use the same fixed-hash concatenation rule as `dependenciesHash`. Every child `creator` MUST equal the top-level `coreDeployer`. A `CREATE` child has its exact positive `createNonce` and zero salt; a `CREATE2` child has zero `createNonce` and nonzero salt. Every `initCodeHash` MUST equal the hash of the artifact's published creation bytecode concatenated with its exact constructor encoding, and every child address MUST recompute under its declared method.

For method `1`, the transaction sender creates CoreDeployer directly and `factory`, `salt`, and `factoryArtifactHash` are zero. For method `2`, the declared factory CREATE2-creates CoreDeployer and those fields are nonzero and match its artifact/address. `transactionSender` MUST equal the sender of the transaction that initiates CoreDeployer creation. `coreDeployerInitCodeHash`, top-level and deployment-method CoreDeployer address, all child addresses, actual create order, and creation transaction hashes MUST recompute from the published sender/nonces, preimages, receipts, and live chain facts.

Capability identity:

```text
ModuleCommandRuleV1(
  uint8  command,
  uint8  role,
  uint16 sourceStateMask,
  uint16 resultCodeMask,
  uint8  faultCodeMask,
  uint8  callOrder,
  uint8  coreEffect,
  bool   permitsTiming
)

MODULE_COMMAND_RULE_V1_TYPEHASH = keccak256("ModuleCommandRuleV1(uint8 command,uint8 role,uint16 sourceStateMask,uint16 resultCodeMask,uint8 faultCodeMask,uint8 callOrder,uint8 coreEffect,bool permitsTiming)")

ReservationSchemaV1(
  bytes32 specTypeHash,
  bytes32 ruleTypeHash,
  bytes32 dispositionTypeHash,
  bytes32 reservationIdTypeHash,
  bytes32 operatorFeeRulesHash,
  bytes32 operatorFaultRuleSchemaId,
  uint8   operatorFaultClassMask,
  uint8   operatorFaultPredicateMask,
  uint16  kindMask,
  uint16  formulaMask,
  uint8   maxReservations,
  uint8   maxRules,
  uint8   maxOutputs
)

RESERVATION_SCHEMA_V1_TYPEHASH = keccak256("ReservationSchemaV1(bytes32 specTypeHash,bytes32 ruleTypeHash,bytes32 dispositionTypeHash,bytes32 reservationIdTypeHash,bytes32 operatorFeeRulesHash,bytes32 operatorFaultRuleSchemaId,uint8 operatorFaultClassMask,uint8 operatorFaultPredicateMask,uint16 kindMask,uint16 formulaMask,uint8 maxReservations,uint8 maxRules,uint8 maxOutputs)")

CoreSurfaceSchemaV1(
  bytes32 fundingSpecTypeHash,
  bytes32 fundingAuthTypeHash,
  bytes32 positionIdTypeHash,
  bytes32 positionPayoutAuthTypeHash,
  bytes32 positionPayoutResultSchemaHash,
  bytes32 packageEconomicsTypeHash,
  bytes32 packageSelectionTypeHash,
  bytes32 packageContestTermsTypeHash,
  bytes32 moduleContextTypeHash,
  bytes32 arbitrationOpenRequestTypeHash,
  bytes32 arbitrationOpenResultTypeHash,
  bytes32 referencePackageSpecHash
)

CORE_SURFACE_SCHEMA_V1_TYPEHASH = keccak256("CoreSurfaceSchemaV1(bytes32 fundingSpecTypeHash,bytes32 fundingAuthTypeHash,bytes32 positionIdTypeHash,bytes32 positionPayoutAuthTypeHash,bytes32 positionPayoutResultSchemaHash,bytes32 packageEconomicsTypeHash,bytes32 packageSelectionTypeHash,bytes32 packageContestTermsTypeHash,bytes32 moduleContextTypeHash,bytes32 arbitrationOpenRequestTypeHash,bytes32 arbitrationOpenResultTypeHash,bytes32 referencePackageSpecHash)")

CapabilityV1(
  bytes32 moduleApiId,
  bytes32 moduleResultSchemaHash,
  uint32  supportedProfileBits,
  uint32  disabledProfileBits,
  uint8   supportedPoolKindMask,
  uint8   disabledPoolKindMask,
  uint16  maxModulesPerDeal,
  uint16  maxModuleCallsPerAction,
  uint32  maxModuleDataBytes,
  uint32  maxExtensionBytes,
  bytes32 commandMatrixHash,
  bytes32 reservationSchemaHash,
  bytes32 coreSurfaceSchemaHash
)

CAPABILITY_V1_TYPEHASH = keccak256("CapabilityV1(bytes32 moduleApiId,bytes32 moduleResultSchemaHash,uint32 supportedProfileBits,uint32 disabledProfileBits,uint8 supportedPoolKindMask,uint8 disabledPoolKindMask,uint16 maxModulesPerDeal,uint16 maxModuleCallsPerAction,uint32 maxModuleDataBytes,uint32 maxExtensionBytes,bytes32 commandMatrixHash,bytes32 reservationSchemaHash,bytes32 coreSurfaceSchemaHash)")
```

For `sourceStateMask`, bits `0..4` mean `NONE`, `FUNDED`, `FIAT_SENT`, `DISPUTED`, and `ARBITRATION_ACTIVE`. `resultCodeMask` bit `n` means result code `n`; `faultCodeMask` uses the same convention for §2.6. Role `255` means every selected activation role in ascending order. `callOrder` values are `0 FIRST_OR_SOLE`, `1 AFTER_PACKAGE_POLICY_AND_EXACT_FEES`, and `255 ASCENDING_ACTIVATION_ROLE`; value `1` has the exact §6.3 toll/quote ordering, not merely relative module order. Core effects are `0 CONTINUE`, `1 PROOF_RELEASE`, `2 ENTER_ARBITRATION`, and `3 ARBITRATION_TERMINAL`.

`commandMatrixHash` is the concatenated-hash root, in command-id order, of exactly these five §7.4 rows:

```text
(0, 255, 0x0001, 0x0002, 0x01, 255, 0, false)
(1,   7, 0x000c, 0x0002, 0x01,   0, 0, false)
(2,   0, 0x000e, 0x0004, 0x01,   0, 1, false)
(3,   1, 0x000c, 0x0008, 0x01,   1, 2, false)
(4,   1, 0x0010, 0x0070, 0x05,   0, 3, false)
```

`reservationSchemaHash` is `hashStruct(ReservationSchemaV1)` with the §8.5 spec, rule, disposition, and reservation-id type hashes, `operatorFeeRulesHash = OPERATOR_FEE_RULES_V1`, `operatorFaultRuleSchemaId = OPERATOR_FAULT_RULE_SCHEMA_V1`, `operatorFaultClassMask = 0x07`, `operatorFaultPredicateMask = 0x0f`, `kindMask = 0x001e`, `formulaMask = 0x001f`, and the exact §2.2 reservation limits. It therefore commits both deterministic reservation identity and the authenticated classifications/closed rule predicates. `supportedProfileBits` is the exact implemented set. `disabledProfileBits` is a subset of that set which cannot be selected on this deployment and MUST include `CROWDFUNDED_POOL`; bits in neither set are unsupported. The exact selectable set is `supportedProfileBits & ~disabledProfileBits`.

`coreSurfaceSchemaHash` is `hashStruct(CoreSurfaceSchemaV1)` with the exact type hashes from §§3.3, 6.3, 6.4, 6.7, and 6.9. Its `referencePackageSpecHash` equals the candidate constant, which is zero and therefore disables reference SKUs. A zero or mismatched surface hash rejects the manifest; package, funding, position, payout, or arbitration-open wire schemas cannot drift independently of deployment identity.

Pool-kind mask bit `k` means §2.5 `PoolKind k`. Only bits `1` (`OWNED`) and `2` (`CUSTOM`) may be set in `supportedPoolKindMask`; `disabledPoolKindMask` is a subset. If `POOL` is unsupported both masks are zero. If `POOL` is supported, `supportedPoolKindMask` is nonzero; when `POOL` is disabled all supported kinds are disabled, otherwise at least one kind is selectable. A deal's kind must be in `supportedPoolKindMask & ~disabledPoolKindMask`; kind `0`, kind `3`, unknown bits, and every profile/kind-mask inconsistency reject. `moduleApiId` equals `CORE_MODULE_API_V1`, and `moduleResultSchemaHash` equals `MODULE_RESULT_SCHEMA_HASH`.

Coordinator governance and verification:

```text
CoordinatorGovernanceV1(
  address authority,
  uint16  signerCount,
  uint16  threshold,
  uint64  minDelay,
  uint32  permissionMask,
  bytes32 authorityRuntimeCodeHash,
  bytes32 policyHash
)

COORDINATOR_GOVERNANCE_V1_TYPEHASH = keccak256("CoordinatorGovernanceV1(address authority,uint16 signerCount,uint16 threshold,uint64 minDelay,uint32 permissionMask,bytes32 authorityRuntimeCodeHash,bytes32 policyHash)")

ReadbackV1(
  uint8   category,
  address target,
  bytes4  selector,
  bytes32 returnDataHash
)

READBACK_V1_TYPEHASH = keccak256("ReadbackV1(uint8 category,address target,bytes4 selector,bytes32 returnDataHash)")

EvidenceV1(
  uint16  ordinal,
  bytes32 kindHash,
  bytes32 locatorHash,
  bytes32 contentHash
)

EVIDENCE_V1_TYPEHASH = keccak256("EvidenceV1(uint16 ordinal,bytes32 kindHash,bytes32 locatorHash,bytes32 contentHash)")

VerificationV1(
  uint64  finalityBlockNumber,
  bytes32 finalityBlockHash,
  bytes32 reverseLinksHash,
  bytes32 immutableReadbackHash,
  bytes32 evidenceRoot
)

VERIFICATION_V1_TYPEHASH = keccak256("VerificationV1(uint64 finalityBlockNumber,bytes32 finalityBlockHash,bytes32 reverseLinksHash,bytes32 immutableReadbackHash,bytes32 evidenceRoot)")
```

Coordinator permission bits are `1 ALLOW_FUTURE_BINDING` and `2 DISALLOW_FUTURE_BINDING`; all other bits are zero. Authority, threshold, delay, code identity, and policy hash MUST match live readback. `policyHash = keccak256(exact published governance-policy bytes)`.

Readback category `1` is a reverse link and category `2` is another immutable readback; other values reject. `returnDataHash = keccak256(exact canonical ABI return bytes)`. Entries are unique and sorted by `(category, target, selector)`. `reverseLinksHash` is the fixed-hash concatenation root of category-1 entry hashes, and `immutableReadbackHash` is the corresponding category-2 root.

Evidence entries use unique contiguous ordinals starting at zero. `kindHash` and `locatorHash` hash exact UTF-8 bytes, and `contentHash` hashes the exact evidence artifact bytes. `evidenceRoot` is their ordinal-order fixed-hash concatenation root. Finality facts MUST identify a canonical block at or after every listed deployment transaction.

### 13.3 Canonical absence and validation

Canonical absence is zero of the field's ABI type: `address(0)`, `bytes32(0)`, or numeric zero. An absent array root is `bytes32(0)`, not `keccak256("")`. An unused fixed field is zero; omitted fields and JSON `null` are not ABI values.

Conditional absence encoded as canonical zero is limited to:

- top-level `factoryArtifactHash` plus deployment-method `factory` and `salt` for method `1`;
- top-level `predecessorManifestHash` when there is no conforming predecessor;
- nested `BuildV1.dependenciesHash` when the verified build truly has no external dependency.

Separately, the sole required nested hash field intentionally fixed to canonical zero in this candidate is `CoreSurfaceSchemaV1.referencePackageSpecHash`. It MUST be present in the ABI preimage and equal `REFERENCE_PACKAGE_SPEC_HASH == bytes32(0)`, recording that reference SKUs are disabled; it is not an omitted preimage. This exception does not make the enclosing schema optional: `coreSurfaceSchemaHash = hashStruct(CoreSurfaceSchemaV1)` MUST be nonzero and exact, and the enclosing `CapabilityV1`/`capabilityHash` MUST also be nonzero and exact.

Every other required nested hash/address and every other top-level hash/address is nonzero. Method-specific zero numeric/salt fields follow their exact §13.2 rules and are not missing preimages. A present artifact with empty constructor bytes uses `keccak256(bytes(""))` for `constructorArgsHash`, not zero. Missing preimages, placeholder values, unknown schema/method/role/bit values, duplicate or unsorted arrays, hash mismatch, live-code/readback mismatch, or a noncanonical absent value rejects the manifest.

JSON, CBOR, and repository files are transport representations only. A verifier MUST decode to the exact ABI fields above, recompute every nested hash bottom-up, and finally recompute `manifestHash`.

### 13.4 Release metadata

Conformance status, release class, audits, incidents, endorsements, deprecation, and successor recommendations are append-only metadata and do not alter `manifestHash`, deployment identity, or execution.

---

## 14. Normative invariants

### 14.1 Custody

1. Ledger is the only triad contract with protocol-token balance.
2. Healthy accounted assets equal healthy outstanding positions after reconciliation.
3. Active principal and matured credits for one `(chain, version, Ledger, token)` share one physical boundary.
4. Raw surplus is quarantined and never funds a gap.
5. No token or boundary subsidizes another.
6. Every token or position value movement begins with §4.2 reconciliation.
7. Preflight status `4` persists in a successful reconciliation-only transaction before the requested action can retry.
8. A negative raw delta fully absorbed by quarantine changes only quarantine, emits status `3`, and does not stop the requested action or enter deficit; only status `4` enters/persists deficit and stops the requested action.

### 14.2 Positions and deficit

1. Deficit is irreversible and rejects all new units/exposure.
2. Fixed deficit nominal units equal the outstanding nominal liability at entry.
3. Every position satisfies `nominal = paid + funded + gap`.
4. Loss changes only funded/gap; recovery changes only gap/funded; claim changes only funded/paid.
5. Prior payments are final.
6. Same-checkpoint claim order cannot change entitlement.
7. Whole-deal and whole-reservation settlement conserve nominal, funded, and gap components.
8. Every operation is O(1); no beneficiary/deal/checkpoint iteration.
9. Payout never exceeds nominal units and floor dust has no privileged recipient.
10. Position ids follow the closed §3.3 preimages; consumed ids never revive, and coalescing occurs only within one declared source and beneficiary.
11. Healthy partial/full withdrawal and deficit claim use the typed §6.7 routing/results, finite-or-sentinel caps, and success-only redirection nonce consumption.

### 14.3 Core state

1. Every deal has at most one terminal record and Ledger settlement.
2. Terminal membership is explicit; arbitration-active is nonterminal.
3. Every mandatory timeout remains permissionlessly executable until another valid transition wins.
4. `DISPUTED` and `ARBITRATION_ACTIVE` block unilateral release and claim.
5. Core dispute timeout never burns principal.
6. Module failure cannot block an independent Core exit.
7. Arbitration timeout is computed from the signed duration and stored deadline and makes no module call.
8. Mutual cancel, co-signed release, and mutual split remain available from `ARBITRATION_ACTIVE`; first successful terminal action wins.
9. Core does not revert Ledger preflight status `4`.
10. Base `openDispute` never requires or calls a module; an enhanced package call cannot disable it.
11. After the §10.4 commit boundary, settlement makes no module or optional callback.
12. Arbitration open authenticates the exact caller/payer and quote, pays only the bounded signed destinations in the closed order, stores the typed result, and rolls every effect back on failure.

### 14.4 Consent and identity

1. Activation requires provider consent plus the exact direct/pool activation authority.
2. Nonces are one-use only on success.
3. Chain/version/contract replay fails.
4. Module binding is complete, admitted at activation, and immutable for the deal.
5. Coordinator changes are future-only.
6. Principal/fee funding, package selection/economics/contest, pool-authority, arbitration/open, and reservation preimages are fully typed and included in consent or the exact named runtime request.
7. Terminal records and deployment manifests are domain-separated and reproducible.
8. `manifestHash` is the exact V1 ABI struct hash with all published nested preimages.
9. Signed pool kind selects the exact owned/custom authority matrix; controller/operator permissions are independent, snapshotted, and future mandate changes cannot alter active authority.
10. Operator-fee recipient, bps, cap, reserve, return receiver, acceptance, and fault policy are signed before activation.
11. Modules authenticate only the closed fault classification; Core alone matches the signed reservation predicate and executes its fixed formula.
12. Core validates package cross-commitments but never claims to interpret an opaque package label/policy hash; reference SKUs remain disabled while `REFERENCE_PACKAGE_SPEC_HASH` is zero.
13. Every supported deployment method uses the nonzero manifest-bound CoreDeployer as creator of all three triad children.

---

## 15. Conformance intent for implementation and tests

A production-candidate implementation MUST provide evidence for at least:

### 15.1 Sole-vault and healthy paths

- direct activation places principal and activation fee only in Ledger;
- Escrow balance remains zero through every transition;
- every Core-only terminal path reassigns one deal position exactly;
- fee and holder-dust math at bps extremes and odd principal;
- wallet and same-vault principal/fee funding, wrong mode/source/authority/token/amount/position, separate signatures, nonce/expiry, and all-or-nothing rollback;
- deterministic ids and collision/tombstone rejection for deal, activation-fee, deal-terminal, reservation, and reservation-terminal positions;
- healthy finite partial/full and max-sentinel withdrawal; zero-payable, deficit-routing, alternate receiver, and exact nonce-consumption results;
- failed receiver transfer preserves the position and nonce;
- healthy principal/fee/reservation funding is atomic and all reservation positions are non-withdrawable while active;
- no general credit or recovery reallocation authority exists.

### 15.2 Deficit reference and differential paths

- deficit entry with active deals and matured credits;
- partial claims, repeated claims, full loss, partial/full recovery;
- loss after payment, recovery after loss, and repeated alternating checkpoints;
- terminal reassignment before and after recovery;
- same beneficiary across multiple positions;
- every claim-order permutation at a fixed checkpoint;
- raw positive balance quarantine and over-recovery rejection;
- negative raw deltas below/equal/above quarantine, including status, accounting/event fields, continuation, and exact deficit boundary;
- preflight status `4` immediately before activation, healthy withdrawal, recovery deposit, deficit claim, and terminal settlement persists, moves no value, and succeeds on the correct retry path;
- no test relies on a deficit write surviving an outer revert;
- no new exposure after full gap refill;
- O(1) gas growth across position and checkpoint history; and
- differential agreement between the implementation and `test/helpers/ReferenceRecoveryModel.sol`.

### 15.3 Token and signature paths

- no-return, true-return, false-return, malformed-return, fee, bonus, short, burn, blacklist, external seizure, and reentrant tokens;
- both source and destination deltas on every pull/push;
- 65-byte, EIP-2098, high-`s`, malformed EOA signatures;
- all EOA/ERC-1271 signer combinations, wrong magic/revert/malformed return;
- wrong chain, version, Escrow, Ledger, deal, action, and expiry;
- funding-spec/auth, package-selection/economics/contest, pool-kind/authority/mandate/operator acceptance, arbitration terms/open request/quote, reservation funding, mutual disposition/fault, and replay-domain mismatches;
- failed-call nonce rollback.

### 15.4 Modules

- full-tuple admission, sorted uniqueness, flag/binding consistency, bounds;
- activation rollback on module failure;
- active snapshot survives Coordinator delisting;
- code/config drift rejects only the optional edge;
- every exact role/state/result/call-order row and malformed result;
- base `openDispute` succeeds with a reverting/missing package module while an enhanced call fails closed and still enforces the same signed toll;
- module success followed by the hard settlement commit proves no further module call is possible;
- every allowed/forbidden operator-fault code/evidence pair;
- proof that an adapter cannot select a reservation predicate/formula/beneficiary and that Core maps class `2` only through signed rules;
- nonzero module timing fields reject;
- wrong `ModuleContext.caller`, arbitration request/action-data/context hash, quote fields, nonce, expiry, or maximum rejects;
- arbitration-open package toll and court quote execute in the exact §6.3 order and roll back with adapter or later failure;
- arbitration duration/deadline is Core-computed and timeout succeeds with a reverting, delisted, or missing adapter;
- no arbitrary receiver/state/outcome/split command;
- reentrancy rejection and preservation of Core fallback exits;
- payment-proof and arbitration open/ruling entrypoints dispatch rather than remain stubs.

### 15.5 Reservations and terminal records

- exhaustive explicit terminal classification;
- reservation bounds, spec-without-generic-beneficiary semantics, per-rule primary beneficiaries, `(slot,outcome,faultPredicate)` ordering, any-versus-specific exclusivity, exact fault-class matches, impossible-predicate rejection, default return, every closed formula, split-only `MUTUAL_AUTH` signer coverage, and cancel/release rewrite rejection;
- same arbitration outcome with no-fault release versus authenticated-fault slash under fixed signed rows;
- exact operator bps/cap reserve derivation and `OPERATOR_FEE` spec match, full/partial/zero provider gross, mutual/arbitration fault, no-fault timeout, one-time consumption, and full unlock remainder;
- healthy and deficit reservation disposition conserves every component;
- one terminal record in storage plus stored disposition preimages and golden terminal-hash vectors;
- explicit holder-side return and operator-fee paid/unlocked vectors for every outcome;
- no undefined extension-terminal hash;
- Ledger terminal/disposition-hash match and duplicate settlement rejection.

### 15.6 Deployment

- required deployment inputs and placeholder rejection;
- mandatory nonzero CoreDeployer under both methods, deterministic addresses, creation/runtime hashes, constructor schemas/preimages, CoreDeployer-only child order, and reverse links;
- every V1 nested preimage/hash, canonical absent value, sorted array root, and one-bit mismatch rejection;
- exact nonzero `coreSurfaceSchemaHash`/`capabilityHash` with the sole required nested hash field fixed to canonical zero, `referencePackageSpecHash`;
- supported/disabled pool-kind masks and every kind/flag/authority-matrix mismatch;
- reservation fault schema id/class/predicate masks and one-bit mismatch rejection;
- golden `manifestHash` vectors from exact ABI encoding, including method `1` and method `2`;
- EIP-170/EIP-3860 size gates and reproducible build;
- pinned Arbitrum fork evidence for the approved release token/code set.

Passing tests is necessary but not sufficient for ratification, audit, candidate, qualified, or production claims under `PROTOCOL.md`.

---

## 16. Out of scope for this candidate

- The low-level recovery index/generation formula until `test/helpers/ReferenceRecoveryModel.sol` and §15.2 prove it
- Final Solidity selectors, physical slot packing, errors, and event declarations until the `src/interfaces/` artifacts pass the applicable §§15.2–15.6 acceptance gates
- Payment-proof verifier and nullifier internals
- Arbitration court, quote-policy generation, appeal, and ruling-policy internals (not the typed §6.3 open request, bound maximum, exact payment, result, or rollback surface)
- Bond formulas and vault internals
- Pool constitution, NAV, mandates, operator logic, and rate-policy internals
- Humanity, reputation, and exposure-policy internals
- Crowdfunded pools before CF-GATE
- Native ETH and cross-chain settlement
- Migration of positions from an experimental predecessor

These exclusions do not permit topology, holder authority, fee/fault disposition, state, token, module, terminal-record, or observable accounting semantics frozen above to remain unimplemented in a production-conformant Mandatory Core.
