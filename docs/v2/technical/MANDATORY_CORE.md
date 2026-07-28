# PluriSwap V2 Technical Specification — Mandatory Core

**Document identity:** `pluriswap.v2.technical.mandatory-core`  
**Protocol version bound:** 2  
**Business charter:** `PROTOCOL.md` (content hash bound at ratification)  
**Pass:** 1 — Direct bilateral Core only  
**Status:** Draft for technical elaboration (not yet protocol-ratified)  
**Target runtime:** Arbitrum L2 (One / Sepolia and compatible Orbit chains with EVM timestamp semantics)  
**Custody architecture:** Single immutable escrow contract per deployment  

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
| `TECH-CORE-ARCH-001` | One escrow contract holds all Core custody for the deployment. |
| `TECH-CORE-ARCH-002` | Escrow bytecode is immutable after creation. No proxy, no admin upgrade, no pause, no arbitrary call. |
| `TECH-CORE-ARCH-003` | Protocol clock is `block.timestamp` as observed by the escrow on the settling chain. |
| `TECH-CORE-ARCH-004` | Consent uses EIP-712 typed data. Contract wallets authorize via EIP-1271 `isValidSignature`. |
| `TECH-CORE-ARCH-005` | Assets are exact-delta ERC-20 tokens and native ETH represented by `NATIVE_ASSET = address(0)`. |
| `TECH-CORE-ARCH-006` | Settlement is accounting-first: terminal transitions mint irrevocable credits, then optional external transfer on withdraw. |
| `TECH-CORE-ARCH-007` | Pass-1 deals are direct holder↔provider only. Holder-side authority is always the signed `holder` address. |

---

## 1. Identifiers, constants, and numeric ranges

### 1.1 Protocol identity constants

Implementations MUST expose these immutables (constructor-set or compile-time constants) and bind them in the EIP-712 domain and deal terms:

| Name | Type | Meaning |
| --- | --- | --- |
| `PROTOCOL_ID` | `bytes32` | Canonical identity: `keccak256("pluriswap.protocol.v2")` |
| `CHARTER_HASH` | `bytes32` | Content hash of ratified `PROTOCOL.md` |
| `TECH_SPEC_HASH` | `bytes32` | Content hash of the ratified aggregate technical specification |
| `PROTOCOL_VERSION` | `uint32` | `2` |
| `CHAIN_ID` | `uint64` | Settling chain id (e.g. `42161` Arbitrum One, `421614` Arbitrum Sepolia) |
| `ESCROW` | `address` | This deployment’s escrow address (`address(this)` at runtime) |

`TECH-CORE-ID-001` — Activation MUST reject if signed terms’ identity fields disagree with the deployment’s immutables.

### 1.2 Numeric ranges

| Quantity | Type | Range / rule |
| --- | --- | --- |
| Token amounts | `uint256` | `> 0` for principal; fees `>= 0`; no overflow in checked arithmetic |
| Basis points | `uint16` | `0..=10_000` |
| Durations (`fiatDuration`, `releaseDuration`, `disputeDuration`) | `uint64` | `>= 1` and `<= MAX_DURATION` |
| `MAX_DURATION` | `uint64` | `3660 days` (`316_224_000` seconds) |
| Absolute timestamps / deadlines | `uint64` | Unix seconds; addition MUST NOT overflow `uint64` |
| Creation expiry | `uint64` | Strictly `> block.timestamp` at activation |
| Nonces | `uint256` | Unique per signing domain usage as defined below |
| Decimals (disclosure field) | `uint8` | Bound in terms; NOT used to rescale principal onchain |

`TECH-CORE-NUM-001` — All duration and deadline arithmetic uses checked `uint64` addition. Overflow rejects before state change.

### 1.3 Sentinels

| Name | Value | Meaning |
| --- | --- | --- |
| `NATIVE_ASSET` | `address(0)` | Native ETH asset key |
| `BPS_DENOM` | `10_000` | Basis-point denominator |
| `EMPTY_PROFILE_HASH` | `bytes32(0)` | Profile disabled / absent |
| `NO_DEAL` | `bytes32(0)` | Uninitialized deal id |

### 1.4 Deal and credit identifiers

```text
termsHash = keccak256(abi.encode(EIP712_DEAL_TERMS_TYPEHASH, /* canonical field encoding */))
dealId    = keccak256(abi.encode(PROTOCOL_ID, CHAIN_ID, ESCROW, termsHash))
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
verifyingContract: ESCROW
```

`TECH-CORE-SIG-001` — Verification MUST recompute the domain separator from live `block.chainid` and `address(this)` and reject mismatches. This prevents replay across chains and deployments.

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
  address escrow,
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
  uint64 fiatDuration,
  uint64 releaseDuration,
  uint64 disputeDuration,
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
| `holder`, `provider` | Nonzero, distinct |
| `holderReceiver`, `providerReceiver` | Nonzero; each `!= ESCROW` (`TOKEN-010A`) |
| `token` | `address(0)` (ETH) or ERC-20 contract with code |
| `custodyBoundaryId` | Pass-1 MUST equal `keccak256(abi.encode(PROTOCOL_ID, CHAIN_ID, ESCROW, token))` |
| `tokenRiskId` | Nonzero content-addressed risk record id (client-disclosed; escrow stores, does not interpret) |
| `principal` | `> 0` |
| `holderFee`, `providerFee` | `>= 0`; `providerFee <= principal` |
| Fee recipients | If fee `> 0`, recipient nonzero and `!= ESCROW`; if fee `== 0`, recipient MUST be `address(0)` |
| Durations | Each in `1..=MAX_DURATION` |
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
  address escrow,
  bytes32 dealId,
  uint8 action,                 // ResolutionAction
  uint256 resolutionNonce,
  uint64 expiry,
  uint16 providerShareBps       // required for Split; MUST be 0 for other actions
)
```

`TECH-CORE-RES-001` — Mutual cancel and co-signed release MUST present `providerShareBps == 0` in the signed payload (unused). Split requires `0..=10_000`.

`TECH-CORE-RES-002` — Both snapshotted holder and provider MUST sign the identical digest. Anyone may relay.

`TECH-CORE-RES-003` — `resolutionNonce` is scoped to `(dealId, action)` and is one-use.

### 3.5 CreditRedirectAuthorization

```text
CreditRedirectAuthorization(
  bytes32 protocolId,
  uint64 chainId,
  address escrow,
  address token,
  address beneficiary,
  address alternateReceiver,
  uint256 amount,               // exact credit amount authorized; MUST equal current credit
  uint256 nonce,
  uint64 expiry
)
```

`TECH-CORE-CRED-001` — Only the credit beneficiary may authorize redirection. `alternateReceiver` nonzero and `!= ESCROW`.

### 3.6 Nonce journals

| Journal | Key | Rule |
| --- | --- | --- |
| Activation nonce | `(holder, provider, nonce)` or global `termsHash` spent flag | Spent iff activation succeeds |
| Resolution nonce | `(dealId, action, resolutionNonce)` | Spent iff resolution succeeds |
| Redirect nonce | `(beneficiary, token, nonce)` | Spent iff redirect withdraw succeeds |

`TECH-CORE-NONCE-001` — Failed attempts MUST leave nonces unspent (`ACT-007`, `RES-005`).

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
    uint64 activatedAt;
    uint64 fiatDeadline;
    uint64 releaseDeadline;            // 0 until FiatSent
    uint64 disputeDeadline;            // 0 until Disputed
    uint64 disputedAt;                 // 0 until Disputed
    bytes32 termsHash;
    bytes32 tokenRiskId;
    bytes32 custodyBoundaryId;
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

### 5.1 Escrow surface (Pass 1)

```solidity
interface IPluriSwapCore {
    // --- activation ---
    function activate(
        DealTerms calldata terms,
        bytes calldata holderSignature,
        bytes calldata providerSignature
    ) external payable returns (bytes32 dealId);

    // --- FUNDED ---
    function markFiatSent(bytes32 dealId) external;
    function providerCancel(bytes32 dealId) external;
    function fiatTimeoutCancel(bytes32 dealId) external;

    // --- FIAT_SENT ---
    function release(bytes32 dealId) external;
    function claim(bytes32 dealId) external;
    function openDispute(bytes32 dealId) external;

    // --- dual-sign (FUNDED / FIAT_SENT / DISPUTED as allowed) ---
    function resolve(
        bytes32 dealId,
        ResolutionAuthorization calldata auth,
        bytes calldata holderSignature,
        bytes calldata providerSignature
    ) external;

    // --- DISPUTED ---
    function disputeTimeout(bytes32 dealId) external;

    // --- credits ---
    function withdraw(address token, address beneficiary) external;
    function withdrawTo(
        CreditRedirectAuthorization calldata auth,
        bytes calldata beneficiarySignature
    ) external;

    // --- deficit recovery ---
    function contributeRecovery(address token) external payable;
    function claimRecovery(address token, address beneficiary) external;

    // --- views ---
    function getDeal(bytes32 dealId) external view returns (Deal memory);
    function quoteSettlement(bytes32 dealId, OutcomeCode outcome, uint16 providerShareBps)
        external view returns (uint256 holderGross, uint256 providerGross, uint256 providerFeeCollected);
}
```

`TECH-CORE-IFACE-001` — Function names above are normative for Pass-1 ABI compatibility claims. Additional view helpers MAY be added without a protocol version bump if they cannot change state.

### 5.2 Token adapters (internal)

**ERC-20 path**

1. Record `before = balanceOf(escrow)`.
2. `transferFrom(funder, escrow, amount)` (or pull pattern equivalent).
3. Require `balanceOf(escrow) - before == amount`.
4. Reentrancy lock around the full activation/settlement critical section.

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

`TECH-CORE-ACT-001` — ERC-20 principal+fee are pulled from `terms.holder` using that holder’s allowance to the escrow. `msg.sender` may be any relayer. Native ETH MUST be supplied as `msg.value` by the transaction sender; for ETH deals the sender MUST be the holder (Pass-1 simplification) **or** a documented paymaster pattern is out of scope — **normative Pass-1:** for `NATIVE_ASSET`, `msg.sender == terms.holder` and `msg.value == requiredIn`.

Rationale: prevents silent third-party ETH funding confusion in Core-only without a permit/paymaster profile.

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
- `block.timestamp < createExpiry`.
- Holder and provider signatures valid over `termsHash` digest.
- `termsHash` / activation nonce unspent.
- Boundary not in DEFICIT for `token` (no new exposure).
- Exact funding received.

**Effects**

```text
dealId = H(PROTOCOL_ID, CHAIN_ID, ESCROW, termsHash)
state = Funded
activatedAt = block.timestamp
fiatDeadline = activatedAt + fiatDuration
activePrincipal[token] += principal
if holderFee > 0: credit(holderFeeRecipient, token, holderFee)  // matured immediately
mark nonce spent
```

Activation fee is non-refundable after success (`FEE-H-003`).

### 6.2 CASE-CORE-002 — `markFiatSent`

- Caller `== provider`.
- State `Funded`.
- Effects: `state = FiatSent`; `releaseDeadline = block.timestamp + releaseDuration`.

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
- Effects: `state = Disputed`; `disputedAt = block.timestamp`; `disputeDeadline = disputedAt + disputeDuration`.
- No fee, no bond (`DISPUTE-007`).

### 6.8 Dual-sign — `resolve`

| Action | Allowed states | Outcome / economics |
| --- | --- | --- |
| `MutualCancel` | `Funded`, `FiatSent`, `Disputed` | Cancel, `MutualCancel` |
| `CosignedRelease` | `FiatSent`, `Disputed` | Provider-full, `CosignedRelease` |
| `Split` | `FiatSent`, `Disputed` | Partial by `providerShareBps`, `MutualSplit` |

Common checks: signatures, `auth` binds `dealId` and identity, `block.timestamp < auth.expiry`, nonce fresh, `auth.action` matches.

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
| Receiver equals escrow | `InvalidReceiver` |

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

## 11. Reentrancy and concurrency

`TECH-CORE-RE-001` — A non-reentrant guard covers `activate`, all state transitions, withdraw paths, and recovery claims.

`TECH-CORE-RE-002` — Checks-effects-interactions: credit accounting updates before external calls.

`TECH-CORE-RE-003` — Token callbacks cannot change deal state or mint unauthorized credits.

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
- chain id, escrow address, create tx, deployment block
- compiler version, optimizer settings, bytecode hash (creation + runtime)
- constructor preimage: `(PROTOCOL_ID, CHARTER_HASH, TECH_SPEC_HASH)` if set in constructor
- enabled profile set: empty / `profiles.none.v2`
- governance/emergency: **absent** for Core custody (no roles)
- predecessor: present or explicit null sentinel

`TECH-CORE-DEP-001` — Core escrow constructor MUST NOT set an owner, pauser, or upgrade admin.

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
6. Zero-fee Core deal.
7. EIP-1271 holder and provider contract wallets.
8. Replay across chainId / escrow / nonce.
9. Exact funding reject (short ERC-20 transfer mock).
10. Withdraw failure preserves credit; redirect withdraw.
11. Deficit entry, pro-rata claims, contribute recovery.
12. Receiver `== escrow` rejected.
13. Activation after `createExpiry` rejected.
14. All dual-sign expiry and nonce replay rejects.

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

## 17. Open points requiring human confirmation before ratification

These do not block drafting or prototype coding, but MUST be closed before `TECH_SPEC_HASH` ratification:

1. **Final `MAX_DURATION` value** — currently `3660 days`; confirm product bound.
2. **ETH activation sender rule** — Pass-1 requires `msg.sender == holder`; confirm no relayer-ETH exception.
3. **Fee recipient when fee is zero** — Pass-1 requires `address(0)`; confirm client UX.
4. **`tokenRiskId` nullity** — Pass-1 requires nonzero; confirm whether a canonical “unknown risk” hash is allowed.
5. **Gas budgets** — replace provisional numbers with measured Arbitrum traces.
6. **Charter/tech-spec hash algorithm** — confirm `keccak256` of raw file bytes vs canonicalized encoding.

Until these are closed, this document remains **Draft — Pass 1**.

---

## 18. Change control

Edits to this document that change signed meaning, custody, transitions, fees, or credit semantics require a new technical-specification version and a new `TECH_SPEC_HASH`. Active deals on prior deployments remain governed by their snapshotted hashes.
