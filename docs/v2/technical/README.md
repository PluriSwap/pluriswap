# PluriSwap V2 Technical Specifications

**Authority:** Subordinate to [`PROTOCOL.md`](../../../PROTOCOL.md) (business source of truth).  
If this directory conflicts with `PROTOCOL.md`, this directory is non-conformant until repaired.

## Pass status

| Artifact | Status | Notes |
| --- | --- | --- |
| [`MANDATORY_CORE.md`](./MANDATORY_CORE.md) | **Draft — Pass 1** | Direct bilateral Core escrow only |
| [`OPTIONAL_PROFILES.md`](./OPTIONAL_PROFILES.md) | Deferred | Profiles after Core ratification of this pass |
| Aggregate `PLURISWAP_OPEN_PROTOCOL_SPEC.md` | Regenerated from authored sources | See [`scripts/generate-protocol-spec.sh`](../../../scripts/generate-protocol-spec.sh) |

## Locked decisions for Pass 1

These choices are binding for this technical pass and are not reopened by implementation convenience:

1. **Scope:** Mandatory Core only (direct deals). Optional profiles reject at activation.
2. **Architecture:** One immutable escrow contract per deployment (no custody proxy, no owner, no pause).
3. **Target chain family:** Arbitrum (canonical L2 timestamp clock).
4. **Consent:** EIP-712 typed data; contract parties via EIP-1271.
5. **Assets:** Exact-balance ERC-20 plus native ETH (`address(0)` sentinel).
6. **Deal clocks:** Whole hours, `1..=120` (max 5 days) for fiat / release / dispute windows.
7. **ETH activate:** `msg.sender == holder` with exact `msg.value`.
8. **Identity hashes:** `keccak256(raw file bytes)` for charter and aggregate tech spec.
9. **Security posture:** Replay/nonce journals, pull credits, exact funding, no admin surface (see `MANDATORY_CORE.md` §11).

## Document order

1. Ratified / draft business charter — `PROTOCOL.md`
2. Technical specification — this directory
3. Executable requirements (EARS) — regenerate after tech-spec approval
4. Implementation plan — after tech-spec + deviation report

## Conformance note

A deployment that implements only Mandatory Core MAY claim Core conformance for the behaviors specified in `MANDATORY_CORE.md`. It MUST NOT claim support for POOL, PAYMENT_PROOF, ARBITRATION, BONDS, REPUTATION, HUMANITY, CROWDFUNDED_POOL, or RATE_POLICY until those profiles are specified and evidenced.
