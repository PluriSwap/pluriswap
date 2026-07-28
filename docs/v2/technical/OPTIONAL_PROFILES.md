# PluriSwap V2 Technical Specification — Optional Profiles

**Document identity:** `pluriswap.v2.technical.optional-profiles`  
**Protocol version bound:** 2  
**Business charter:** `PROTOCOL.md`  
**Status:** Deferred — not authored in Pass 1

---

## Pass 1 disposition

Mandatory Core Pass 1 deliberately excludes optional profiles. A Core-only deployment MUST treat every profile below as disabled:

| Profile | Business sections | Pass-1 technical status |
| --- | --- | --- |
| POOL | `PROTOCOL.md` §14 | OUT_OF_SCOPE — activation rejects pool-origin terms |
| PAYMENT_PROOF | §12 | OUT_OF_SCOPE — extension transitions revert |
| ARBITRATION | §13 | OUT_OF_SCOPE — extension transitions revert |
| BONDS | §11 | OUT_OF_SCOPE |
| REPUTATION | §16.3 | OUT_OF_SCOPE as admission gate |
| HUMANITY | §16.1 | OUT_OF_SCOPE as admission gate |
| RATE_POLICY | §14.10 | OUT_OF_SCOPE |
| CROWDFUNDED_POOL | §15 | OUT_OF_SCOPE until CF-GATE |

This file is a placeholder so the aggregate generator and documentation hierarchy remain stable. Profile technical requirements, interfaces, typed data, events, and traceability IDs will be added in a later pass without changing Core signed meaning.

## Authorship gate

Do not implement optional profiles against informal notes. Author the corresponding sections here (or successor files), regenerate the aggregate technical specification, and rematerialize executable requirements before claiming profile conformance (`PROFILE-003`).
