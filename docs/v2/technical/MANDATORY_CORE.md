# PluriSwap V2 Technical Specification — Mandatory Core

**Document identity:** `pluriswap.v2.technical.mandatory-core`  
**Protocol version bound:** 2  
**Business charter:** `PROTOCOL.md` (content hash bound at ratification)  
**Pass:** 1 — Direct bilateral Core only  
**Status:** Draft for technical elaboration (not yet protocol-ratified)  
**Target runtime:** Arbitrum L2 (One / Sepolia and compatible Orbit chains with EVM timestamp semantics)  
**Custody architecture:** Two mutually bound immutable contracts (Engine + Custody) plus external libraries  

---

## 0. Authority and scope

### 0.1 Precedence

1. `PROTOCOL.md` defines normative business behavior.
2. This document defines exact data, formulas, interfaces, signatures, events, and state representation for **Mandatory Core**.
3. Executable requirements and code derive from (1) and (2). They cannot redefine either.

Stable technical requirement identifiers use the prefix `TECH-CORE-`. They SHALL NOT be reassigned.

### 0.2 In scope (Pass 1)

A conforming Pass-1 deployment MUST implement:

- direct bilateral deal activation from EIP-712 (+ EIP-1271) consent;
- exact principal custody for ERC-20 and native ETH;
- the Core state machine in `PROTOCOL.md` §8 (solid edges only);
- activation and completion fee channels (amounts MAY be zero);
- pull credits and withdrawal (including alternate-receiver authorization);
- per-token custody-boundary solvency and deficit recovery ledger;
- permissionless timeout and claim paths;
- independent public reconstructability of deals, credits, and outcomes from chain data.

### 0.3 Out of scope (Pass 1)

The following MUST reject (or be absent) in a Pass-1 Core deployment. Selecting them in signed terms MUST cause activation to revert:

| Profile / capability | Activation behavior |
| --- | --- |
| POOL / pool-origin deals | Reject |
| PAYMENT_PROOF | Reject |
| ARBITRATION | Reject |
| BONDS | Reject |
| REPUTATION (as admission gate) | Reject |
| HUMANITY (as admission gate) | Reject |
| CROWDFUNDED_POOL | Reject |
| RATE_POLICY | Reject |
| Operator acceptance fee | Reject (no operator role) |
| Batch execution as deal authority | N/A — not a deal profile; native entrypoints remain required |

Extension-point transitions (`CASE-PAY-*`, `CASE-ARB-*`) MUST revert with `ProfileDisabled`.

### 0.4 Locked architecture decisions

| ID | Decision |
| --- | --- |
| `TECH-CORE-ARCH-001` | **Custody** is the sole Core asset boundary: it holds tokens/ETH, deal records, credits, and deficit ledgers. |
| `TECH-CORE-ARCH-002` | **Engine** is the sole user-facing state-transition surface for deal lifecycle calls. Both Engine and Custody are immutable after creation. No proxy, no admin upgrade, no pause, no arbitrary call, no post-deploy setter for the peer address. |
| `TECH-CORE-ARCH-003` | Heavy pure logic lives in **external libraries** (EIP-712 digests, settlement math, token-risk hash/flag checks) to stay under the 24,576-byte runtime limit. |
| `TECH-CORE-ARCH-004` | Engine and Custody are **mutually bound** at construction (each stores the other’s address as `immutable`). Only the bound Engine may invoke Custody deal-mutation entrypoints. |
| `TECH-CORE-ARCH-005` | Protocol clock is `block.timestamp` as observed by the settling chain on the contract executing the transition (Engine for auth checks; Custody for recorded timestamps written in the same transaction). |
| `TECH-CORE-ARCH-006` | Consent uses EIP-712 typed data. Contract wallets authorize via EIP-1271 `isValidSignature`. |
| `TECH-CORE-ARCH-007` | Assets are exact-delta ERC-20 tokens and native ETH represented by `NATIVE_ASSET = address(0)`. |
| `TECH-CORE-ARCH-008` | Settlement is accounting-first: terminal transitions mint irrevocable credits, then optional external transfer on withdraw. |
| `TECH-CORE-ARCH-009` | Pass-1 deals are direct holder↔provider only. Holder-side authority is always the signed `holder` address. |
| `TECH-CORE-ARCH-010` | Core deal clocks (`fiat`, `release`, `dispute`) are signed in **whole hours**, minimum 1 hour, maximum **5 days (120 hours)**. |
| `TECH-CORE-ARCH-011` | Native ETH activation requires `msg.sender == holder` and exact `msg.value` on the Engine call; Engine forwards value to Custody atomically. |
| `TECH-CORE-ARCH-012` | Document identity hashes are `keccak256` of the **raw file bytes** (Section 1.5). |
| `TECH-CORE-ARCH-013` | Activation submits and stores the `TokenRiskRecord` preimage; hash must match signed `tokenRiskId`. |
| `TECH-CORE-ARCH-014` | No upgradeable Diamond/proxy custody. Size relief is libraries + the two-contract split only. |

### 0.5 Deployment topology (normative)

```text
                    users / relayers / keepers
                              |
                              v
                     +------------------+
                     |  PluriSwapEngine |  <-- EIP-712 verifyingContract
                     |  (immutable)     |  <-- signatures, transitions, payable activate
                     +--------+---------+
                              |
                              | onlyEngine deal-mutation calls
                              | (+ forward msg.value on ETH activate)
                              v
                     +------------------+
                     | PluriSwapCustody |  <-- holds ETH/ERC-20
                     |  (immutable)     |  <-- deals, credits, deficit
                     +--------+---------+
                              ^
                              |
              permissionless withdraw / claimRecovery
                              |
                           anyone

External libraries (linked / called, not custody holders):
  - PluriSwapEIP712Lib
  - PluriSwapSettlementLib
  - PluriSwapRiskLib
```

**Responsibilities**

| Component | Holds assets? | Stores deals? | User calls? | Peer auth |
| --- | --- | --- | --- | --- |
| `PluriSwapEngine` | No (except transient `msg.value` forward) | No | Yes — all lifecycle entrypoints | Immutable `CUSTODY` |
| `PluriSwapCustody` | Yes | Yes | Yes — only `withdraw`, `withdrawTo`, `contributeRecovery`, `claimRecovery`, views | Immutable `ENGINE`; deal mutations `require(msg.sender == ENGINE)` |
| External libraries | No | No | Indirect | Stateless pure/view helpers |

**Construction / addressing**

`TECH-CORE-DEP-002` — Peer addresses are constructor immutables only. Deployment MUST use **CREATE2** (or an equivalent deterministic scheme) so each constructor can embed the other’s final address without any initializer, owner, or rewrite.

`TECH-CORE-DEP-003` — Runtime bytecode of Engine and of Custody MUST each independently satisfy the EIP-170 limit. Linked library addresses are fixed in the deployment manifest.

`TECH-CORE-DEP-004` — Future optional profiles MUST be separate modules, not merged into Engine/Custody bytecode. Core entrypoints remain callable without them.

---

## 1. Identifiers, constants, and numeric ranges

### 1.1 Protocol identity constants

Implementations MUST expose these immutables (constructor-set or compile-time constants) and bind them in the EIP-712 domain and deal terms:

| Name | Type | Meaning |
| --- | --- | --- |
| `PROTOCOL_ID` | `bytes32` | Canonical identity: `keccak256("pluriswap.protocol.v2")` |
| `CHARTER_HASH` | `bytes32` | Content hash of ratified `PROTOCOL.md` (Section 1.5) |
| `TECH_SPEC_HASH` | `bytes32` | Content hash of the ratified aggregate technical specification (Section 1.5) |
| `PROTOCOL_VERSION` | `uint32` | `2` |
| `CHAIN_ID` | `uint64` | Settling chain id (e.g. `42161` Arbitrum One, `421614` Arbitrum Sepolia) |
| `ENGINE` | `address` | Deal-engine address (EIP-712 `verifyingContract`) |
| `CUSTODY` | `address` | Custody / asset-boundary address |

`TECH-CORE-ID-001` — Activation MUST reject if signed terms’ identity fields disagree with the deployment’s immutables (`ENGINE`, `CUSTODY`, hashes, version, chain).

### 1.2 Numeric ranges and deal clocks

**What `MAX_DURATION` is.** It is **not** a single global timeout. Each deal signs three independent Core clocks:

| Clock | Starts when | Ends at | Permissionless / authority effect |
| --- | --- | --- | --- |
| Fiat window | activation success | `fiatDeadline` | Anyone may `fiatTimeoutCancel` at/after deadline while still `Funded` |
| Release window | `markFiatSent` success | `releaseDeadline` | Anyone may `claim` at/after deadline while still `FiatSent`; holder may `openDispute` only **before** it |
| Dispute window | `openDispute` success | `disputeDeadline` | Anyone may `disputeTimeout` at/after deadline while still `Disputed` |

Signed fields are **whole hours**. Onchain deadlines convert with `HOUR_SECONDS = 3600`.

| Quantity | Type | Range / rule |
| --- | --- | --- |
| Token amounts | `uint256` | `> 0` for principal; fees `>= 0`; checked arithmetic only |
| Basis points | `uint16` | `0..=10_000` |
| `fiatDurationHours` | `uint16` | `1..=MAX_DURATION_HOURS` |
| `releaseDurationHours` | `uint16` | `1..=MAX_DURATION_HOURS` |
| `disputeDurationHours` | `uint16` | `1..=MAX_DURATION_HOURS` |
| `MAX_DURATION_HOURS` | `uint16` | `120` (5 days) |
| `HOUR_SECONDS` | `uint64` | `3600` |
| Absolute timestamps / deadlines | `uint64` | Unix seconds; checked addition only |
| `createExpiry` | `uint64` | `block.timestamp < createExpiry <= block.timestamp + MAX_CREATE_LEAD_SECONDS` |
| `MAX_CREATE_LEAD_SECONDS` | `uint64` | `86_400` (24 hours) — limits stale signed-activation warehouses |
| Resolution / redirect `expiry` | `uint64` | `block.timestamp < expiry <= block.timestamp + MAX_AUTH_LEAD_SECONDS` at consumption |
| `MAX_AUTH_LEAD_SECONDS` | `uint64` | `86_400` (24 hours) |
| Nonces | `uint256` | Per journal in Section 3.7; never reused after success |
| Decimals (risk-record field) | `uint8` | Offchain disclosure only; NOT used to rescale principal onchain |

Deadline derivation (checked `uint64`):

```text
fiatDeadline    = activatedAt + uint64(fiatDurationHours)    * HOUR_SECONDS
releaseDeadline = markedAt    + uint64(releaseDurationHours) * HOUR_SECONDS
disputeDeadline = disputedAt  + uint64(disputeDurationHours) * HOUR_SECONDS
```

`TECH-CORE-NUM-001` — Duration and deadline arithmetic uses checked `uint64` addition/multiplication. Overflow or out-of-range hours rejects before state change.

`TECH-CORE-NUM-002` — Partial hours are forbidden in signed terms. Clients MUST present clocks in hours; escrow MUST reject `0` and `> 120`.

### 1.5 Content hashing algorithm

`TECH-CORE-HASH-001` — Normative content hash for charter and technical-specification identity:

```text
CHARTER_HASH    = keccak256(raw_bytes(PROTOCOL.md))
TECH_SPEC_HASH  = keccak256(raw_bytes(PLURISWAP_OPEN_PROTOCOL_SPEC.md))
```

Rules:

1. Hash the **exact file bytes** as published in the ratified git commit (no canonicalization, no line-ending rewrite, no JSON re-encoding).
2. Algorithm is **keccak256** (EVM native).
3. Ratification records MUST publish the git commit, file paths, byte lengths, and hashes.
4. Escrow immutables MUST equal those ratified hashes; deals binding other hashes reject.

`TECH-CORE-HASH-002` — `tokenRiskId` uses the same keccak256 function over the canonical risk-record bytes defined in Section 1.6.

### 1.6 Token risk identity (`tokenRiskId` + saved preimage)

`tokenRiskId` is **not** an allowlist entry and does **not** make escrow trust the token issuer.

Plain language:

- The **preimage** is the filled-out risk form (`TokenRiskRecord` fields below).
- `tokenRiskId` is `keccak256` of that form.
- Parties **sign** `tokenRiskId` inside deal terms.
- At activation, the caller **submits the form again**; escrow re-hashes it, checks it matches the signed id, checks it matches the deal’s token/chain, **stores both**, and emits them so anyone can verify the parties signed that exact disclosure.

**Canonical preimage struct:**

```solidity
struct TokenRiskRecord {
    uint64  chainId;
    address token;                 // address(0) for native ETH
    uint8   decimals;              // 18 for ETH; ERC-20 decimals at disclosure time
    bool    isNativeEth;
    bool    issuerCanUpgrade;
    bool    issuerCanPause;
    bool    issuerCanFreezeOrBlacklist;
    bool    hasCallbacksOrHooks;
    bool    hasPermit;
    bool    isRebasing;
    bool    hasTransferFeeOrHaircut;
    bool    exactBalanceAssumed;   // MUST be true for Core activation
    bytes32 evidenceUriHash;       // keccak256 of a disclosure URI or document
    bytes32 notesHash;             // keccak256 of free-form notes (may be keccak256(""))
}
```

**Hash formula (must match signed `terms.tokenRiskId`):**

```text
tokenRiskId = keccak256(abi.encode(
  keccak256("pluriswap.v2.TokenRiskRecord.v1"),
  chainId, token, decimals, isNativeEth,
  issuerCanUpgrade, issuerCanPause, issuerCanFreezeOrBlacklist,
  hasCallbacksOrHooks, hasPermit, isRebasing, hasTransferFeeOrHaircut,
  exactBalanceAssumed, evidenceUriHash, notesHash
))
```

| Rule | Requirement |
| --- | --- |
| `TECH-CORE-RISK-001` | `terms.tokenRiskId != bytes32(0)`. |
| `TECH-CORE-RISK-002` | No canonical “unknown / skip disclosure” sentinel. Thin disclosure still uses an explicit record. |
| `TECH-CORE-RISK-003` | `activate` MUST take `TokenRiskRecord calldata risk`. Recompute hash; require equality with `terms.tokenRiskId` or revert `TokenRiskMismatch`. |
| `TECH-CORE-RISK-004` | Require `risk.chainId == terms.chainId`, `risk.token == terms.token`, and `risk.isNativeEth == (terms.token == address(0))`. |
| `TECH-CORE-RISK-005` | Require `risk.exactBalanceAssumed == true`. Require `risk.isRebasing == false` and `risk.hasTransferFeeOrHaircut == false` (Core exact-funding profile). |
| `TECH-CORE-RISK-006` | On success, persist **both** `tokenRiskId` and the full `TokenRiskRecord` in deal storage, and emit them on `DealActivated` / `TokenRiskBound`. |
| `TECH-CORE-RISK-007` | Escrow still does **not** attest that the flags are factually true in the real world—only that the signed hash equals this saved disclosure. Exact transfer checks remain independent. |

### 1.7 Sentinels

| Name | Value | Meaning |
| --- | --- | --- |
| `NATIVE_ASSET` | `address(0)` | Native ETH asset key |
| `BPS_DENOM` | `10_000` | Basis-point denominator |
| `PROFILE_SET_NONE` | `keccak256("pluriswap.profiles.none.v2")` | Pass-1 empty profile set |
| `NO_DEAL` | `bytes32(0)` | Uninitialized deal id |

### 1.8 Deal and credit identifiers

```text
termsHash = keccak256(abi.encode(EIP712_DEAL_TERMS_TYPEHASH, /* canonical field encoding */))
dealId    = keccak256(abi.encode(PROTOCOL_ID, CHAIN_ID, ENGINE, CUSTODY, termsHash))
```

`TECH-CORE-ID-002` — `dealId` is deterministic from terms and deployment identity. Relayers cannot choose an alternate id.

`TECH-CORE-ID-003` — Credit keys are `(token, beneficiary)` for ordinary pull credits, plus typed journals for deficit recovery units (Section 10).
---

## 2. Types and enums

### 2.1 DealState

```solidity
enum DealState {
    Nonexistent,                 // 0 — default storage
    Funded,                      // 1 — FUNDED
    FiatSent,                    // 2 — FIAT_SENT
    Disputed,                    // 3 — DISPUTED
    Released,                    // 4 — RELEASED (terminal)
    ResolvedSplit,               // 5 — RESOLVED_SPLIT (terminal)
    ResolvedByDisputeTimeout,    // 6 — RESOLVED_BY_DISPUTE_TIMEOUT (terminal)
    Cancelled                    // 7 — CANCELLED (terminal)
}
```

`TECH-CORE-STATE-001` — Extension-only states (`ArbitrationActive`, `ResolvedByArbitration`, `Stalemate`) are **not** present in Pass-1 storage. Attempts to transition into them revert.

Terminal states: `Released`, `ResolvedSplit`, `ResolvedByDisputeTimeout`, `Cancelled`.

### 2.2 OutcomeCode

Distinguishes economically similar terminals for indexing and future reputation packages. Stored once at terminalization.

```solidity
enum OutcomeCode {
    None,                 // 0 — active / unset
    VoluntaryRelease,     // CASE-OUT-001
    CosignedRelease,      // CASE-OUT-001A
    TimeoutClaim,         // CASE-OUT-003
    ProviderCancel,       // CASE-OUT-004
    FiatTimeoutCancel,    // CASE-OUT-005
    MutualCancel,         // CASE-OUT-006
    MutualSplit,          // CASE-OUT-007
    DisputeTimeout        // CASE-OUT-013
}
```

`TECH-CORE-OUT-001` — `TimeoutClaim` MUST use state `Released` and outcome `TimeoutClaim` (not a separate state).  
`TECH-CORE-OUT-002` — `DisputeTimeout` MUST use state `ResolvedByDisputeTimeout` and outcome `DisputeTimeout`, even when `disputeTimeoutProviderBps == 5000`.

### 2.3 ResolutionAction

```solidity
enum ResolutionAction {
    MutualCancel,      // RES-001
    CosignedRelease,   // RES-002A
    Split              // RES-002
}
```

### 2.4 AssetKind

Internal helper only (not necessarily stored):

```solidity
enum AssetKind { NativeEth, Erc20 }
// NativeEth  <=> token == address(0)
// Erc20      <=> token != address(0)
```

---

## 3. EIP-712 signing domain and typed data

### 3.1 Domain separator

```solidity
// EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)
name:              "PluriSwap"
version:           "2"
chainId:           CHAIN_ID          // must equal block.chainid at verify time
verifyingContract: ENGINE            // Deal engine, not Custody
```

`TECH-CORE-SIG-001` — Verification MUST recompute the domain separator from live `block.chainid` and `ENGINE` (`address(this)` inside Engine) and reject mismatches. This prevents replay across chains and deployments.

`TECH-CORE-SIG-002` — `PROTOCOL_ID`, `CHARTER_HASH`, `TECH_SPEC_HASH`, and `PROTOCOL_VERSION` are bound **inside deal terms and resolution payloads**, not only in the domain name string.

### 3.2 Signature verification algorithm

For each required signer `S` and digest `D`:

1. If `S.code.length == 0`: recover ECDSA signer from `signature` (`r,s,v` or compact equivalent) and require equality with `S`.
2. Else: call `IERC1271(S).isValidSignature(D, signature)` and require magic value `0x1626ba7e`.
3. Otherwise revert `InvalidSignature`.

`TECH-CORE-SIG-003` — Both holder and provider signatures are required for activation. Order in calldata is `(holderSig, providerSig)`.

`TECH-CORE-SIG-004` — Holder and provider MUST be distinct nonzero addresses (`ACT-004`).

### 3.3 DealTerms (activation consent)

Canonical EIP-712 primary type:

```text
DealTerms(
  bytes32 protocolId,
  bytes32 charterHash,
  bytes32 techSpecHash,
  uint32 protocolVersion,
  uint64 chainId,
  address engine,
  address custody,
  address holder,
  address provider,
  address holderReceiver,
  address providerReceiver,
  address token,
  bytes32 custodyBoundaryId,
  bytes32 tokenRiskId,
  uint256 principal,
  uint256 holderFee,
  address holderFeeRecipient,
  uint256 providerFee,
  address providerFeeRecipient,
  uint256 nonce,
  uint64 createExpiry,
  uint16 fiatDurationHours,
  uint16 releaseDurationHours,
  uint16 disputeDurationHours,
  uint16 disputeTimeoutProviderBps,
  bytes32 fiatCurrency,
  uint256 fiatAmount,
  bytes32 paymentMethod,
  bytes32 payeeCommitment,
  bytes32 paymentReferenceCommitment,
  bytes32 quoteSemantics,
  bytes32 profileSetHash
)
```

**Field rules**

| Field | Rule |
| --- | --- |
| Identity fields | Exact match to deployment immutables |
| `engine`, `custody` | Exact `ENGINE` and `CUSTODY` |
| `holder`, `provider` | Nonzero, distinct |
| `holderReceiver`, `providerReceiver` | Nonzero; each `!= CUSTODY` and `!= ENGINE` (`TOKEN-010A`) |
| `token` | `address(0)` (ETH) or ERC-20 contract with code |
| `custodyBoundaryId` | Pass-1 MUST equal `keccak256(abi.encode(PROTOCOL_ID, CHAIN_ID, CUSTODY, token))` |
| `tokenRiskId` | Nonzero; must equal hash of activation `risk` preimage (Section 1.6) |
| `principal` | `> 0` |
| `holderFee`, `providerFee` | `>= 0`; `providerFee <= principal` |
| Fee recipients | If fee `> 0`, recipient nonzero and `!= CUSTODY` and `!= ENGINE`; if fee `== 0`, recipient MUST be `address(0)` |
| Duration hours | Each in `1..=120` |
| `createExpiry` | Future and within `MAX_CREATE_LEAD_SECONDS` (Section 1.2) |
| `nonce` | Unused in activation journals (Section 3.7) |
| `disputeTimeoutProviderBps` | `0..=10_000` |
| Fiat commitment fields | Each nonzero (`bytes32` / `uint256` as typed); opaque to escrow beyond presence |
| `profileSetHash` | Pass-1 MUST equal `keccak256("pluriswap.profiles.none.v2")` |

`TECH-CORE-TERMS-001` — Onchain validation enforces the table above. Escrow does **not** authenticate that fiat was paid; fiat fields are consent commitments only.

`TECH-CORE-TERMS-002` — `profileSetHash` is the sole Pass-1 profile gate. Any other hash rejects activation.

### 3.4 ResolutionAuthorization

```text
ResolutionAuthorization(
  bytes32 protocolId,
  bytes32 charterHash,
  bytes32 techSpecHash,
  uint32 protocolVersion,
  uint64 chainId,
  address engine,
  address custody,
  bytes32 dealId,
  uint8 action,                 // ResolutionAction
  uint256 resolutionNonce,
  uint64 expiry,
  uint16 providerShareBps       // required for Split; MUST be 0 for other actions
)
```

`TECH-CORE-RES-001` — Mutual cancel and co-signed release MUST present `providerShareBps == 0` in the signed payload (unused). Split requires `0..=10_000`.

`TECH-CORE-RES-002` — Both snapshotted holder and provider MUST sign the identical digest. Anyone may relay.

`TECH-CORE-RES-003` — `resolutionNonce` is scoped to `(dealId, action)` and is one-use (Section 3.7).

`TECH-CORE-RES-004` — At consumption, `expiry` MUST satisfy the lead-time window in Section 1.2.

### 3.5 CreditRedirectAuthorization

```text
CreditRedirectAuthorization(
  bytes32 protocolId,
  uint64 chainId,
  address engine,
  address custody,
  address token,
  address beneficiary,
  address alternateReceiver,
  uint256 amount,               // exact credit amount authorized; MUST equal current credit
  uint256 nonce,
  uint64 expiry
)
```

`TECH-CORE-CRED-001` — Only the credit beneficiary may authorize redirection. `alternateReceiver` nonzero and `!= CUSTODY` and `!= ENGINE`.

`TECH-CORE-CRED-003` — All EIP-712 verification runs on **Engine** (`verifyingContract = ENGINE`). `withdrawTo` is an Engine entrypoint that verifies the redirect auth then calls Custody. Ordinary `withdraw(token, beneficiary)` MAY be called **directly on Custody** (no signature).

`TECH-CORE-CRED-002` — Redirect nonce rules are in Section 3.7; lead-time rules match Section 1.2.

### 3.6 Signature security requirements

`TECH-CORE-SIG-005` — ECDSA signatures MUST be normalized: `v ∈ {27,28}` (or equivalent compact form) and `s` in the lower half of the curve order (EIP-2). Malleable signatures reject.

`TECH-CORE-SIG-006` — Each EIP-712 primary type has a distinct `TYPEHASH`. Activation, resolution, and redirect digests MUST NOT be interchangeable.

`TECH-CORE-SIG-007` — EIP-1271 wallets are a **chosen trust edge**. Escrow MUST use the standard magic-value check and MUST NOT grant the wallet extra custody powers beyond the signed digest. A malicious 1271 implementation can DoS its own deal actions; that cannot spend another deal’s assets (`TRUST-005`).

`TECH-CORE-SIG-008` — Signature verification precedes nonce consumption and external token calls. Failed verification leaves all journals unchanged.

### 3.7 Nonce journals (normative)

Nonces are a primary replay-defense. Pass-1 defines **three disjoint journals**. Success consumes; any revert leaves journals unchanged.

#### 3.7.1 Activation nonce

Deal terms include a single `uint256 nonce`.

Storage:

```solidity
mapping(bytes32 => bool) public termsHashConsumed;           // termsHash => spent
mapping(address => mapping(uint256 => bool)) public activationNonceUsed; // party => nonce => spent
```

On successful `activate` only:

1. Require `!termsHashConsumed[termsHash]`.
2. Require `!activationNonceUsed[holder][nonce]`.
3. Require `!activationNonceUsed[provider][nonce]`.
4. Effects (after all other checks, before/with deal write): set all three to `true`.

`TECH-CORE-NONCE-001` — The same `nonce` value cannot be reused by that holder or that provider for any later activation on this deployment’s Custody, even with different counterparties or terms. Pass-1 nonce journals live on **Custody** and are mutated only through Engine-authenticated calls.

`TECH-CORE-NONCE-002` — `termsHashConsumed` prevents replaying an identical signed terms blob if nonce journaling were ever bypassed by a client bug.

`TECH-CORE-NONCE-003` — Recommended client practice: sample `nonce` as 256-bit CSPRNG. Escrow does not require sequential nonces (sequential nonces enable cross-wallet privacy leaks and stuck counters).

#### 3.7.2 Resolution nonce

```solidity
mapping(bytes32 => mapping(uint8 => mapping(uint256 => bool))) public resolutionNonceUsed;
// dealId => action => resolutionNonce => spent
```

`TECH-CORE-NONCE-004` — Consumed only when `resolve` succeeds. Scoped to `(dealId, action, resolutionNonce)` so a used cancel nonce cannot block a later split nonce.

`TECH-CORE-NONCE-005` — Cross-deal, cross-action, cross-deployment, or wrong-`dealId` payloads reject without consumption.

#### 3.7.3 Credit-redirect nonce

```solidity
mapping(address => mapping(address => mapping(uint256 => bool))) public redirectNonceUsed;
// beneficiary => token => nonce => spent
```

`TECH-CORE-NONCE-006` — Consumed only on successful `withdrawTo`. Ordinary `withdraw` does not use this journal.

#### 3.7.4 Failure and ordering

`TECH-CORE-NONCE-007` — Failed activation/resolve/withdrawTo MUST leave every nonce bit unspent (`ACT-007`, `RES-005`).

`TECH-CORE-NONCE-008` — Checks-effects: mark nonce spent only after signature, expiry, state, and funding checks pass, and under the reentrancy lock, before external interactions that can fail after partial side effects. If an external transfer can still fail after consumption, the whole transaction MUST revert (including nonce bits) — Solidity revert semantics satisfy this when consumption and external calls share one transaction without catching reverts.

`TECH-CORE-NONCE-009` — Nonces are deployment-local. They do not synchronize across chains or successor escrows; domain binding prevents cross-deployment replay instead.

---

## 4. Storage model

### 4.1 Deal record

```solidity
struct Deal {
    DealState state;
    OutcomeCode outcome;
    address holder;
    address provider;
    address holderReceiver;
    address providerReceiver;
    address token;
    uint256 principal;
    uint256 holderFee;                 // snapshotted; informational after collection
    address holderFeeRecipient;
    uint256 providerFee;               // signed absolute completion fee
    address providerFeeRecipient;
    uint16 disputeTimeoutProviderBps;
    uint16 fiatDurationHours;
    uint16 releaseDurationHours;
    uint16 disputeDurationHours;
    uint64 activatedAt;
    uint64 fiatDeadline;
    uint64 releaseDeadline;            // 0 until FiatSent
    uint64 disputeDeadline;            // 0 until Disputed
    uint64 disputedAt;                 // 0 until Disputed
    bytes32 termsHash;
    bytes32 tokenRiskId;               // signed hash
    TokenRiskRecord tokenRisk;         // saved preimage checked at activation
    bytes32 custodyBoundaryId;
    uint256 activationNonce;           // snapshotted for reconstructability
    // fiat commitments stored for reconstructability
    bytes32 fiatCurrency;
    uint256 fiatAmount;
    bytes32 paymentMethod;
    bytes32 payeeCommitment;
    bytes32 paymentReferenceCommitment;
    bytes32 quoteSemantics;
}
```

Mapping: `mapping(bytes32 dealId => Deal)`.

`TECH-CORE-STORE-001` — After activation, economic and authority fields are immutable for the deal’s life. Only `state`, `outcome`, and deadline fields that are defined to be written once may change, and only via the closed transition catalog.

### 4.2 Credits

```solidity
// Ordinary matured credits (solvent boundary)
mapping(address token => mapping(address beneficiary => uint256)) public creditOf;

// Deficit ledger (per token boundary)
struct DeficitLedger {
    bool inDeficit;
    uint256 totalRecoveryUnits;
    uint256 cumulativeDistributableAssets;
    // beneficiary => recovery units
    mapping(address => uint256) unitsOf;
    // beneficiary => already claimed assets
    mapping(address => uint256) claimedOf;
}
mapping(address token => DeficitLedger) internal deficit;
```

`TECH-CORE-STORE-002` — Active principal is tracked as deal liability, not as a matured credit, until terminalization.

### 4.3 Aggregates for solvency

Per token boundary:

```solidity
struct TokenBoundary {
    uint256 activePrincipal;     // sum of principal in non-terminal deals
    uint256 maturedCredits;      // sum of creditOf[token][*]
    // assetsControlled measured live via balance / address(this).balance
}
```

`TECH-CORE-SOLV-001` — After every successful value-moving action, if the boundary is not in deficit and the token still satisfies exact-balance assumptions:

```text
assetsControlled >= activePrincipal + maturedCredits
```

---

## 5. External interfaces

### 5.1 Engine surface (user-facing, Pass 1)

```solidity
interface IPluriSwapEngine {
    function custody() external view returns (address);

    function activate(
        DealTerms calldata terms,
        TokenRiskRecord calldata risk,
        bytes calldata holderSignature,
        bytes calldata providerSignature
    ) external payable returns (bytes32 dealId);

    function markFiatSent(bytes32 dealId) external;
    function providerCancel(bytes32 dealId) external;
    function fiatTimeoutCancel(bytes32 dealId) external;
    function release(bytes32 dealId) external;
    function claim(bytes32 dealId) external;
    function openDispute(bytes32 dealId) external;

    function resolve(
        bytes32 dealId,
        ResolutionAuthorization calldata auth,
        bytes calldata holderSignature,
        bytes calldata providerSignature
    ) external;

    function disputeTimeout(bytes32 dealId) external;

    function withdrawTo(
        CreditRedirectAuthorization calldata auth,
        bytes calldata beneficiarySignature
    ) external;

    function quoteSettlement(bytes32 dealId, OutcomeCode outcome, uint16 providerShareBps)
        external view returns (uint256 holderGross, uint256 providerGross, uint256 providerFeeCollected);
}
```

### 5.2 Custody surface (Pass 1)

```solidity
interface IPluriSwapCustody {
    function engine() external view returns (address);

    // --- engine-only deal mutations (msg.sender == ENGINE) ---
    function engineActivate(/* packed activation effects + funding pull */) external payable returns (bytes32 dealId);
    function engineApplyTransition(bytes32 dealId, /* transition opcode + args */) external;
    function engineWithdrawTo(address token, address beneficiary, address receiver, uint256 amount) external;

    // --- permissionless value exits / recovery ---
    function withdraw(address token, address beneficiary) external;
    function contributeRecovery(address token) external payable;
    function claimRecovery(address token, address beneficiary) external;

    // --- views ---
    function getDeal(bytes32 dealId) external view returns (Deal memory);
    function creditOf(address token, address beneficiary) external view returns (uint256);
}
```

`TECH-CORE-IFACE-001` — Engine function names in §5.1 are normative for Pass-1 client ABI claims.

`TECH-CORE-IFACE-002` — Custody `engine*` methods are **not** a public product ABI for wallets. They MUST authenticate `msg.sender == ENGINE`. Exact internal calldata packing MAY use tightly packed structs, but effects MUST equal Sections 6–7.

`TECH-CORE-IFACE-003` — Libraries expose pure functions only (digests, math, risk hash/flags). They MUST NOT hold balances or deal storage.

### 5.2 Token adapters (internal)

**ERC-20 path**

1. Record `before = balanceOf(CUSTODY)`.
2. `transferFrom(funder, CUSTODY, amount)` (or pull pattern equivalent).
3. Require `balanceOf(CUSTODY) - before == amount`.
4. Reentrancy locks on both Engine and Custody critical sections.

**Native ETH path**

1. Require `token == address(0)`.
2. Require `msg.value == amount` for the funded component(s) in that call.
3. Reject nonzero `msg.value` on pure ERC-20 activations.

`TECH-CORE-TOK-001` — Fee-on-transfer, short transfer, false return, or reentrant funding reverts atomically (`CASE-TOK-002`).

`TECH-CORE-TOK-002` — Native ETH and ERC-20 MUST NOT be mixed in one deal. One `token` field per deal.

### 5.3 Activation funding composition

For `activate`:

```text
requiredIn = principal + holderFee
```

- If `token == NATIVE_ASSET`: `msg.value == requiredIn`; holder fee credited/transferred as ETH credit to `holderFeeRecipient` (or immediate credit).
- If ERC-20: `msg.value == 0`; pull `requiredIn` from `msg.sender` **or** from `terms.holder` via allowance — Pass-1 normative rule:

`TECH-CORE-ACT-001` — ERC-20 principal+fee are pulled from `terms.holder` using that holder’s allowance to **Custody** (not Engine). Engine `msg.sender` may be any relayer and MUST send `msg.value == 0`.

`TECH-CORE-ACT-002` — For `NATIVE_ASSET`, require Engine `msg.sender == terms.holder` and `msg.value == requiredIn`. Engine forwards the full value to Custody in the same transaction; if Custody activation reverts, the whole call reverts. Third-party ETH funding and paymasters are out of scope for Pass 1.

`TECH-CORE-ACT-003` — Users never need to send assets to Engine for storage. Engine MUST NOT retain balances across transactions.

---

## 6. State machine transitions

All transitions share:

1. Reentrancy lock.
2. Load deal; reject `Nonexistent` unless activating.
3. Authority / timing / payload checks.
4. Effects; emit event.
5. Solvency / deficit preflight on value movement.

### 6.1 CASE-CORE-001 — `activate`

**Preconditions**

- Terms validate (Section 3.3).
- Token-risk preimage validates (Section 1.6): hash == `terms.tokenRiskId`, token/chain bind, Core flags.
- `block.timestamp < createExpiry <= block.timestamp + MAX_CREATE_LEAD_SECONDS`.
- Holder and provider signatures valid over deal-terms digest.
- Activation nonce journals unspent (Section 3.7.1).
- Boundary not in DEFICIT for `token` (no new exposure).
- Exact funding received (`TECH-CORE-ACT-001` / `TECH-CORE-ACT-002`).

**Effects**

```text
dealId = H(PROTOCOL_ID, CHAIN_ID, ENGINE, CUSTODY, termsHash)
// Engine verifies sigs/risk/nonces/time; Custody writes state + takes funds
state = Funded
activatedAt = block.timestamp
fiatDeadline = activatedAt + uint64(fiatDurationHours) * HOUR_SECONDS
store tokenRiskId and full TokenRiskRecord preimage (on Custody)
activePrincipal[token] += principal
if holderFee > 0: credit(holderFeeRecipient, token, holderFee)  // matured immediately
consume activation nonces on Custody (Section 3.7.1)
emit DealActivated + TokenRiskBound from Custody
```

Activation fee is non-refundable after success (`FEE-H-003`).

### 6.2 CASE-CORE-002 — `markFiatSent`

- Caller `== provider`.
- State `Funded`.
- Effects: `state = FiatSent`; `releaseDeadline = block.timestamp + uint64(releaseDurationHours) * HOUR_SECONDS`.

Note: eligible even after `fiatDeadline` if still `Funded` (races timeout — `TIME-005`).

### 6.3 CASE-CORE-004 — `providerCancel`

- Caller `== provider`.
- State `Funded`.
- Terminalize cancel with `OutcomeCode.ProviderCancel` (Section 7).

### 6.4 CASE-CORE-005 — `fiatTimeoutCancel`

- Anyone.
- State `Funded`.
- `block.timestamp >= fiatDeadline`.
- Terminalize cancel with `OutcomeCode.FiatTimeoutCancel`.

### 6.5 CASE-CORE-007 — `release`

- Caller `== holder`.
- State `FiatSent` (not `Disputed`).
- Terminalize provider-full with `OutcomeCode.VoluntaryRelease`.

### 6.6 CASE-CORE-009 — `claim`

- Anyone.
- State `FiatSent`.
- `block.timestamp >= releaseDeadline`.
- Terminalize provider-full with `OutcomeCode.TimeoutClaim`.

### 6.7 CASE-CORE-021 — `openDispute`

- Caller `== holder`.
- State `FiatSent`.
- `block.timestamp < releaseDeadline` (strict).
- Effects: `state = Disputed`; `disputedAt = block.timestamp`; `disputeDeadline = disputedAt + uint64(disputeDurationHours) * HOUR_SECONDS`.
- No fee, no bond (`DISPUTE-007`).

### 6.8 Dual-sign — `resolve`

| Action | Allowed states | Outcome / economics |
| --- | --- | --- |
| `MutualCancel` | `Funded`, `FiatSent`, `Disputed` | Cancel, `MutualCancel` |
| `CosignedRelease` | `FiatSent`, `Disputed` | Provider-full, `CosignedRelease` |
| `Split` | `FiatSent`, `Disputed` | Partial by `providerShareBps`, `MutualSplit` |

Common checks: signatures, `auth` binds `dealId` and identity, `block.timestamp < auth.expiry <= block.timestamp + MAX_AUTH_LEAD_SECONDS`, resolution nonce fresh (Section 3.7.2), `auth.action` matches.

### 6.9 CASE-CORE-025 — `disputeTimeout`

- Anyone.
- State `Disputed`.
- `block.timestamp >= disputeDeadline`.
- `providerGross = floor(principal * disputeTimeoutProviderBps / 10_000)`.
- Terminalize with state `ResolvedByDisputeTimeout`, outcome `DisputeTimeout`.

### 6.10 Hard rejects

| Condition | Error |
| --- | --- |
| `release` or `claim` while `Disputed` | `DisputeFreeze` (`CASE-CORE-027`) |
| Any state-changing call on terminal deal | `DealTerminal` (`CASE-CORE-020`) |
| Profile extension entrypoints | `ProfileDisabled` |
| Receiver equals `CUSTODY` or `ENGINE` | `InvalidReceiver` |
| Non-engine caller hits Custody `engine*` | `UnauthorizedEngine` |

### 6.11 Race semantics (implementation)

`TECH-CORE-RACE-001` — Eligibility is re-checked against storage at execution. First successful transaction wins; losers revert. No second economic effect (`CASE-RACE-007`).

Deadline inequalities:

| Action | Predicate |
| --- | --- |
| Open dispute | `t < releaseDeadline` |
| Claim | `t >= releaseDeadline` |
| Open dispute vs claim | Never both eligible at same `t` (`CASE-RACE-003`) |
| Dispute timeout | `t >= disputeDeadline` |
| Fiat timeout | `t >= fiatDeadline` while `Funded` |

---

## 7. Settlement formulas

### 7.1 Provider-gross fee rule

```text
providerGross = floor(principal * providerBps / 10_000)
holderGross   = principal - providerGross
providerFeeCollected =
    providerGross == 0 ? 0 : min(signedProviderFee, providerGross)
providerNet   = providerGross - providerFeeCollected
```

Applicable `providerBps`:

| Outcome | providerBps |
| --- | --- |
| Voluntary / co-signed release, claim | `10_000` |
| Mutual / provider / fiat-timeout cancel | `0` |
| Mutual split | signed `providerShareBps` |
| Dispute timeout | snapshotted `disputeTimeoutProviderBps` |

`TECH-CORE-FEE-001` — Rounding always floors provider side; remainder stays holder-side (`ECON-009`).  
`TECH-CORE-FEE-002` — Completion fee never exceeds provider gross; charged at most once.  
`TECH-CORE-FEE-003` — No burn sink; principal always goes to holder and/or provider receivers (`DISPUTE-005`).

### 7.2 Terminalization procedure

On first terminal transition:

1. Require deal active.
2. Compute `holderGross`, `providerGross`, `providerFeeCollected`.
3. Require `holderGross + providerGross == principal`.
4. `activePrincipal[token] -= principal`.
5. If boundary solvent (not DEFICIT):
   - `credit(holderReceiver, token, holderGross)` if `holderGross > 0`
   - `credit(providerReceiver, token, providerNet)` if `providerNet > 0`
   - `credit(providerFeeRecipient, token, providerFeeCollected)` if `> 0`
6. If boundary in DEFICIT: reallocate the deal’s fixed recovery units under the same proportions (Section 10) without increasing total units.
7. Set `state`, `outcome`; emit `DealTerminated`.

### 7.3 Quote helper

`quoteSettlement` MUST use the same formulas as terminalization for offchain display. It MUST NOT revert solely because the outcome is not currently eligible (view simulation), except on nonexistent deals.

---

## 8. Events

Normative event signatures:

```solidity
event DealActivated(
    bytes32 indexed dealId,
    bytes32 indexed termsHash,
    address indexed token,
    address holder,
    address provider,
    uint256 principal,
    uint256 holderFee,
    uint64 fiatDeadline
);

event TokenRiskBound(
    bytes32 indexed dealId,
    bytes32 indexed tokenRiskId,
    TokenRiskRecord risk
);

event FiatMarked(bytes32 indexed dealId, uint64 releaseDeadline);

event DisputeOpened(bytes32 indexed dealId, uint64 disputeDeadline);

event DealTerminated(
    bytes32 indexed dealId,
    DealState state,
    OutcomeCode outcome,
    uint256 holderGross,
    uint256 providerGross,
    uint256 providerFeeCollected
);

event CreditMinted(address indexed token, address indexed beneficiary, uint256 amount);

event CreditWithdrawn(
    address indexed token,
    address indexed beneficiary,
    address indexed receiver,
    uint256 amount
);

event BoundaryDeficitEntered(address indexed token, uint256 totalRecoveryUnits, uint256 assets);

event RecoveryContributed(address indexed token, uint256 amount, uint256 cumulativeDistributable);

event RecoveryClaimed(address indexed token, address indexed beneficiary, uint256 amount);
```

`TECH-CORE-EVT-001` — Indexers MUST be able to reconstruct full economic history from these events plus `getDeal` storage reads.

---

## 9. Errors

```solidity
error InvalidSignature();
error InvalidTerms();
error InvalidReceiver();
error InvalidState();
error DealTerminal();
error DisputeFreeze();
error DeadlineNotReached();
error DeadlinePassed();          // e.g. openDispute at/after releaseDeadline
error NonceSpent();
error Expired();
error ExactFundingRequired();
error MsgValueUnexpected();
error ProfileDisabled();
error BoundaryInDeficit();       // rejecting new exposure
error InsufficientCredit();
error Reentrancy();
error IdentityMismatch();
error TokenRiskMismatch();       // preimage hash != terms.tokenRiskId or bind/flag fail
error UnauthorizedEngine();      // Custody deal mutation from non-ENGINE caller
```

Custom errors are normative for Pass-1 interface claims; string reverts are non-conformant for these cases.

---

## 10. Credits, withdrawal, and deficit

### 10.1 Ordinary withdraw

`withdraw(token, beneficiary)`:

1. `amount = creditOf[token][beneficiary]`; require `> 0`.
2. If boundary in DEFICIT, revert ordinary withdraw (`use claimRecovery`).
3. Zero credit, then transfer exact `amount` to `beneficiary`.
4. On transfer failure: restore credit and revert (`TOKEN-009`).

Anyone may call; receiver is fixed.

### 10.2 Redirect withdraw

`withdrawTo(auth, sig)` verifies beneficiary signature and pays `alternateReceiver` instead. Consumes the full credit amount authorized.

### 10.3 Transfer primitives

- ERC-20: `safeTransfer` with exact post-balance delta check when feasible; for standard ERC-20, require return-true/no-return per common SafeERC20 rules **and** reject fee-on-transfer by delta check on escrow balance when the token is not known-rebasing (Pass-1 assumes exact tokens; unexplained negative delta → deficit path).
- ETH: `call{value: amount}("")`; failure restores credit.

### 10.4 Deficit detection

Before admitting new exposure and before ordinary withdraw:

```text
assets = token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this))
liabilities = activePrincipal[token] + maturedCredits[token]
```

If `assets < liabilities` and not already in deficit:

1. Enter DEFICIT irreversibly for that token.
2. `totalRecoveryUnits = liabilities` (snapshot).
3. Assign units to each active deal’s principal (held by deal id journal) and each matured credit beneficiary equal to their nominal amounts.
4. `cumulativeDistributableAssets = assets`.
5. Emit `BoundaryDeficitEntered`.

`TECH-CORE-DEF-001` — New `activate` on a deficit token reverts. Terminalization still runs by reallocating units.

### 10.5 Recovery claim

```text
entitled = floor(cumulativeDistributable * unitsOf[b] / totalRecoveryUnits)
payout   = entitled - claimedOf[b]
```

Pays `payout`, increments `claimedOf`. Rounding dust remains in the boundary (`TOKEN-018`).

`contributeRecovery` increases controlled assets and `cumulativeDistributable` by exact contributed amount; mints no units.

---

## 11. Security model (Pass-1 Core)

Core security goal: **no unauthorized custody movement, no invented outcome, no cross-deal contamination, and no stuck path that only a privileged actor can unblock.** Offchain fiat honesty remains a chosen-counterparty risk (`PROTOCOL.md` §2–3); this section hardens the machine.

### 11.1 Trust boundaries

| In trust / assumed | Out of trust / must not rely on |
| --- | --- |
| Settling chain execution and `block.timestamp` monotonic enough for deadline predicates | Relayers, keepers, indexers, frontends |
| Signed EIP-712 consent + EIP-1271 magic-value check | Token issuer honesty beyond exact-delta assumption |
| Immutable Engine + Custody bytecode and mutual bind | Any admin, pause, upgrade, or DAO switch |
| Parties’ key / wallet security | Offchain fiat rails |

`TECH-CORE-SEC-001` — Absence of owner/pause/upgrade is a security requirement, not an omission.

### 11.2 Replay and signature attacks

| Attack | Mitigation |
| --- | --- |
| Cross-chain replay | EIP-712 `chainId` + terms `chainId` + live `block.chainid` check |
| Cross-deployment replay | `verifyingContract = ENGINE` + terms `engine`/`custody` bind |
| Custody called by spoof engine | Immutable `ENGINE`; `msg.sender` check on every mutation |
| Cross-version replay | `PROTOCOL_ID`, `PROTOCOL_VERSION`, charter/tech-spec hashes in payload |
| Activation replay | `termsHashConsumed` + per-party `activationNonceUsed` (Section 3.7.1) |
| Resolution replay | Per `(dealId, action, resolutionNonce)` journal |
| Redirect replay | Per `(beneficiary, token, nonce)` journal |
| Typed-data confusion | Distinct primary types / TYPEHASHes (`TECH-CORE-SIG-006`) |
| ECDSA malleability | EIP-2 low-`s` + valid `v` (`TECH-CORE-SIG-005`) |
| Stale signature warehouse | `createExpiry` / auth expiry lead caps (24h) |
| Relayer term mutation | Relayer supplies calldata; digest must match stored/signed terms exactly |

`TECH-CORE-SEC-002` — Security tests MUST include successful and failing vectors for every row above.

### 11.3 Custody and token attacks

| Attack | Mitigation |
| --- | --- |
| Fee-on-transfer / short transfer | Exact balance-delta funding (`TECH-CORE-TOK-001`) |
| False ERC-20 return value | Safe transfer patterns + delta check |
| Reentrant ERC-777/hook token | Nonreentrant guard on all value paths; CEI |
| ERC-20 path with stray `msg.value` | Require `msg.value == 0` (`TECH-CORE-ACT-001`) |
| Third-party ETH spoof funding | `msg.sender == holder` for ETH (`TECH-CORE-ACT-002`) |
| Force-sent ETH / airdrop dust | Surplus is not a liability; cannot fund another deal (`TOKEN-013`) |
| Receiver reverts to brick settlement | Pull credits; terminalization does not require external transfer success |
| Self-receiver black hole | Receivers / fee recipients `!= CUSTODY` and `!= ENGINE` |
| Approval front-run to wrong custody | Users approve specific `CUSTODY`; clients warn; not a protocol bypass |
| Engine retains ETH | Forward-only; activation atomic with Custody; no balance left on Engine |
| Rebasing / silent balance cut | Exact-asset assumption; unexplained deficit → boundary DEFICIT ledger, no cross-subsidy |
| Using deal A assets for deal B | Per-deal principal accounting + per-token boundary isolation |

`TECH-CORE-SEC-003` — Implementations MUST ship adversarial token mocks covering every row that is onchain-testable.

### 11.4 State-machine and race attacks

| Attack / concern | Handling |
| --- | --- |
| Double terminalization | Terminal state rejects further economic changes |
| Claim after dispute freeze | `DisputeFreeze` |
| Open dispute at/after release deadline | Reject; claim eligible instead (`CASE-RACE-003`) |
| Fiat-timeout vs mark-fiat | Intentional race; first success wins (`TIME-005`) — not a bug |
| Keeper censorship of timeouts | Anyone may execute; rights persist until competing transition wins |
| Duplicate relay spam | Later calls revert; no double spend |
| Unauthorized caller on holder/provider actions | Strict `msg.sender` checks on Engine |
| Dual-sign with one forged side | Both signatures required over identical digest |
| Direct Custody deal mutation | Blocked unless `msg.sender == ENGINE` |

`TECH-CORE-SEC-004` — Invariant tests MUST prove: one terminal outcome; principal conservation; fee caps; credit totals match terminal math; nonce monotonic consumption.

### 11.5 Economic griefing within Core (accepted vs closed)

| Behavior | Status |
| --- | --- |
| Provider marks fiat falsely; holder silent → claim | Accepted Core silence default; holder defense is free `openDispute` |
| Holder opens dispute after real fiat → residual risk | Accepted counterparty risk; packages later may add bonds |
| Nonzero activation fee kept on abort | Accepted (`FEE-H-003`) |
| Dust principal / spam deals at zero fee | Accepted in Core; clients/packages may require fees |
| Malicious EIP-1271 wallet DoS its own signatures | Chosen wallet trust; cannot spend others’ funds |
| Token issuer blacklist after credit mint | Credit remains attributable; issuer risk disclosed via `tokenRiskId` |

`TECH-CORE-SEC-005` — Reviews MUST NOT “fix” accepted rows by adding Core admin powers, hidden fees, or identity gates.

### 11.6 Operational security requirements for clients

Conforming clients MUST:

1. Show every EIP-712 field before signing (amounts, receivers, hours, bps, fee recipients, hashes).
2. Build, display, and sign over `tokenRiskId`; at activate submit the same `TokenRiskRecord` preimage Custody will store.
3. Verify Engine + Custody bytecode, mutual bind, library addresses, `CHARTER_HASH`, and `TECH_SPEC_HASH` against the published manifest.
4. Generate 256-bit random activation and resolution nonces.
5. Never ask users to sign unbounded `createExpiry` or auth expiry beyond the lead caps.
6. Default Core clocks to explicit hours (not silent multi-week values).

### 11.7 Required security verification before CANDIDATE

- Unit/integration coverage of Section 11.2–11.4 tables.
- Stateful fuzzing: conservation, replay, races, deadline edges, fee caps.
- Static analysis + compiler warnings clean on Engine, Custody, and libraries.
- No `delegatecall` to untrusted targets, no `selfdestruct`, no upgrade slot, no `tx.origin` auth.
- Explicit reentrancy tests with callback tokens on activate, withdraw, and contributeRecovery.
- Size check: each of Engine and Custody runtime bytecode `<= 24576` bytes.

### 11.8 Reentrancy and concurrency controls

`TECH-CORE-RE-001` — A non-reentrant guard covers `activate`, all state transitions, withdraw paths, and recovery claims.

`TECH-CORE-RE-002` — Checks-effects-interactions: credit accounting updates before external calls.

`TECH-CORE-RE-003` — Token callbacks cannot change deal state or mint unauthorized credits.

`TECH-CORE-RE-004` — View functions are non-mutating and MUST NOT call untrusted contracts.

---

## 12. Gas and complexity budgets (provisional)

Pass-1 publishes soft budgets for Arbitrum L2. Final qualification updates these with measured medians.

| Path | Provisional upper bound (gas) |
| --- | --- |
| `activate` (ERC-20) | 350_000 |
| `activate` (ETH) | 250_000 |
| `markFiatSent` | 80_000 |
| Unilateral cancel / timeout / claim / release / openDispute | 120_000 |
| `resolve` (dual-sign) | 220_000 |
| `disputeTimeout` | 150_000 |
| `withdraw` | 100_000 |

`TECH-CORE-GAS-001` — No unbounded loops over deals or credits in any public path (`DOD-ENG-006`).

---

## 13. Deployment manifest (Core branch)

A Pass-1 immutable deployment manifest MUST include at minimum:

- manifest schema identity: `pluriswap.v2.manifest.core-only`
- `CHARTER_HASH`, `TECH_SPEC_HASH`, `PROTOCOL_VERSION`
- chain id
- `ENGINE` address, `CUSTODY` address, CREATE2 salts / factories, create txs, deployment blocks
- each external library address and bytecode hash
- compiler version, optimizer settings, bytecode hashes (creation + runtime) for Engine, Custody, libraries
- proof that Engine.custody == CUSTODY and Custody.engine == ENGINE
- constructor preimages including protocol identity hashes
- enabled profile set: empty / `profiles.none.v2`
- governance/emergency: **absent** for Core (no roles)
- predecessor: present or explicit null sentinel
- measured runtime code sizes for Engine and Custody

`TECH-CORE-DEP-001` — Neither Engine nor Custody constructor MAY set an owner, pauser, upgrade admin, or rewriteable peer address.

---

## 14. Traceability matrix (Core cases → functions)

| Business case | Function | OutcomeCode / notes |
| --- | --- | --- |
| CASE-CORE-001 | `activate` | → `Funded` |
| CASE-CORE-002 | `markFiatSent` | → `FiatSent` |
| CASE-CORE-004 | `providerCancel` | `ProviderCancel` |
| CASE-CORE-005 | `fiatTimeoutCancel` | `FiatTimeoutCancel` |
| CASE-CORE-006 | `resolve(MutualCancel)` from `Funded` | `MutualCancel` |
| CASE-CORE-007 | `release` | `VoluntaryRelease` |
| CASE-CORE-009 | `claim` | `TimeoutClaim` |
| CASE-CORE-011 | `resolve(MutualCancel)` from `FiatSent` | `MutualCancel` |
| CASE-CORE-012 | `resolve(Split)` from `FiatSent` | `MutualSplit` |
| CASE-CORE-021 | `openDispute` | → `Disputed` |
| CASE-CORE-022 | `resolve(MutualCancel)` from `Disputed` | `MutualCancel` |
| CASE-CORE-023 | `resolve(CosignedRelease)` from `Disputed` | `CosignedRelease` |
| CASE-CORE-024 | `resolve(Split)` from `Disputed` | `MutualSplit` |
| CASE-CORE-025 | `disputeTimeout` | `DisputeTimeout` |
| CASE-CORE-026 | `resolve(CosignedRelease)` from `FiatSent` | `CosignedRelease` |
| CASE-CORE-027 | `release`/`claim` in `Disputed` | revert `DisputeFreeze` |
| CASE-CORE-020 | any transition on terminal | revert `DealTerminal` |
| CASE-OUT-001..007,013 | terminalization | Section 7 |
| CASE-TOK-001..015 | funding / credits / deficit | Sections 5, 10 |
| CASE-RACE-001,002,003,005,007,008 | storage eligibility | Section 6.11 |

Payment-proof and arbitration cases are OUT_OF_SCOPE for Pass-1 (`ProfileDisabled`).

---

## 15. Deterministic test vectors (required before CANDIDATE)

The executable-requirements pass MUST include vectors for at least:

1. Happy path: activate → markFiat → release (ERC-20 and ETH).
2. Claim after silence; claim rejected after dispute open.
3. Fiat-timeout vs mark-fiat race (both orderings).
4. Free `openDispute` then dual-sign cancel / co-release / split / dispute timeout at `0`, `5000`, `10000` bps.
5. Completion fee gross cap on split and residual.
6. Zero-fee Core deal (recipients `address(0)`).
7. EIP-1271 holder and provider contract wallets.
8. Replay across chainId / engine / custody / activation nonce / termsHash / resolution nonce / redirect nonce.
9. Exact funding reject (short ERC-20 transfer mock); ERC-20 activate with nonzero `msg.value` reject.
10. ETH activate with `msg.sender != holder` reject.
11. Duration hours `0` and `121` reject; deadlines equal `hours * 3600`.
12. `createExpiry` beyond 24h lead reject; auth expiry beyond 24h lead reject.
13. Withdraw failure preserves credit; redirect withdraw consumes redirect nonce once.
14. Deficit entry, pro-rata claims, contribute recovery; no cross-token subsidy.
15. Receiver `== CUSTODY` or `ENGINE` rejected; malleable ECDSA `s` rejected; non-engine Custody mutation rejected.
16. Same holder nonce with different provider rejected after first success.
17. Section 11.2–11.4 adversarial matrix cases.
18. Token risk: matching preimage succeeds and is stored; wrong hash / wrong token / rebase or fee-on-transfer flags / `exactBalanceAssumed=false` revert.

Each vector binds expected storage deltas, events, and balances.

---

## 16. Explicit non-goals and deferred work

Deferred to later technical passes (not silent Core features):

- Pool-origin holder authority and operator mandates
- Bond reservation and slash schedules
- Payment-proof verifier hooks
- Arbitration adapters
- Package fee schedule enforcement beyond Core’s two fee channels
- Paymaster / third-party native ETH funding
- Cross-chain settlement
- Crowdfunded pools

`TECH-CORE-SCOPE-001` — Implementers MUST NOT add hidden onchain fee splits, allowlists, or identity gates to “improve” Core.

---

## 17. Closed decisions (this revision)

| Topic | Decision |
| --- | --- |
| Deal clocks | Signed in **hours**; each clock `1..=120` hours (max **5 days**) |
| ETH activation | `msg.sender == holder` and exact `msg.value` |
| Zero fee recipients | MUST be `address(0)` |
| `tokenRiskId` | Required nonzero hash of canonical `TokenRiskRecord`; no skip-disclosure sentinel |
| Risk preimage | Submitted at `activate`, hash-checked against signed id, **both hash and full record saved + emitted** |
| Content hashing | `keccak256(raw file bytes)` for charter and aggregate tech spec |
| Nonces | Full journals in Section 3.7 (activation, resolution, redirect) |
| Auth freshness | 24h max lead for `createExpiry` and resolution/redirect expiry at consumption |
| Contract split | External libraries + immutable **Engine** + immutable **Custody**, CREATE2 mutual bind |

## 18. Remaining open points

1. **Gas budgets** — replace provisional Section 12 numbers with measured Arbitrum traces before QUALIFIED.
2. **Default client clock recommendations** (e.g. suggest 24h/24h/24h) — product UX, not Engine consensus.
3. **Exact Custody `engine*` calldata packing** — may be finalized at implementation as long as effects match this spec.

Until optional items above are closed as needed, this document remains **Draft — Pass 1**, but the Section 17 decisions are binding for this draft.

---

## 19. Change control

Edits to this document that change signed meaning, custody, transitions, fees, nonces, clocks, or credit semantics require a new technical-specification version and a new `TECH_SPEC_HASH`. Active deals on prior deployments remain governed by their snapshotted hashes.
