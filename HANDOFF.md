# Mandatory Core Remediation Handoff

**Status:** Merged to local `main`; production remains release-gated
**Date:** 2026-07-31
**Branch:** `main`
**Canonical repository:** `/Users/econti/Documents/emi/pluriswap`
**Merged source:** `fix/mandatory-core-remediation` at `01ffb62`
**Implementation plan:** `/Users/econti/.cursor/plans/Mandatory Core Remediation-b00fe0e2.plan.md`
**Identity plan:** `/Users/econti/.cursor/plans/Deployment Intent Evidence-67fe2be4.plan.md`

## Safety and repository state

- The candidate was fast-forward merged into local `main`; no remote push was performed.
- The original workspace remains on `feat/mandatory-core-foundry` with pre-existing
  uncommitted files; those files were not overwritten or merged into `main`.
- The source remediation worktree remains preserved at
  `/Users/econti/Documents/emi/pluriswap/.worktrees/mandatory-core-remediation`.
- Local CI-quality, independent-evidence, and Intent/Evidence gates are green.

## Completed and merged

1. **Spec:** `MANDATORY_CORE.md` §13 split into `CoreDeploymentIntentV1` /
   `CoreDeploymentEvidenceV1`; `deploymentIdentity = intentHash`. Mirrored in
   `PROTOCOL.md` and the architecture immutability design.
2. **Solidity:** `ManifestTypes.sol` + `ManifestHashing.sol`; opaque manifest identity
   replaced by canonical Intent/Evidence hashing.
3. **Binding:** `CoreDeployer` / `CoreEscrow` store and emit `intentHash`
   (`IntentComputed`); Escrow binds Intent only.
4. **Triad:** staged child creation, exact initcode/constructor validation, reverse-link
   checks, and a pure Coordinator terminal planner leave Ledger custody-only.
5. **Tooling/tests:** Intent + Evidence hash vectors, boundary/deadline/status/event tests,
   differential recovery tests, Q128 proof checks, contract-size checks, and pinned Slither
   triage are checked in.
6. **Deployment wrapper:** `deploy.sh` and `deploy.toml.example` now use the Intent-era
   creation-code and planned-method hash names expected by `DeployCore.s.sol`.

## Last fully verified checkpoint

- Commit: `01ffb62` (candidate), fast-forwarded into `main`.
- Foundry: **265 passed, 0 failed**.
- `git diff --check`, `forge fmt --check`, and production `--deny warnings` build pass.
- Hash-vector, FullMath-vector, Q128-boundary, and checker self-tests pass.
- Pinned Slither `0.11.6`: **60 accepted, 0 new, 0 stale** findings.
- Live artifact sizes: Coordinator **4,643 / 4,969**, CoreDeployer **3,987 / 5,925**,
  CoreEscrow **23,540 / 24,572**, CreditLedger **18,863 / 19,477** (runtime / initcode).

## Remaining work, in order

1. ~~CI-quality follow-up~~ **DONE**
2. ~~Production Q128 evidence expansion~~ **DONE** (external economic review still required)
3. ~~Independent evidence hardening~~ **DONE**
4. ~~Redesign deployment identity~~ **DONE** (nested-preimage CLI / release container deferred)
5. ~~Correct the core triad direction~~ **DONE FOR CURRENT CORE-ONLY CANDIDATE**
   - Terminal planning is pure Coordinator logic.
   - Ledger is custody-only for the implemented core path.
6. **Implement the remaining `0.3.0-rc1` surfaces**
7. **Qualification and external review**

## Known blockers and constraints

- Production remains **NO-GO**.
- Independent Q128 economic/security review remains external.
- Conservative deficit recovery remains release-gated pending ratified precision and
  fairness policy.
- Mandatory profile/attachment entrypoints remain unimplemented stubs.
- Full bottom-up nested Intent/Evidence preimage generator is not yet built.

## Resume commands

```bash
cd "/Users/econti/Documents/emi/pluriswap"
git worktree add .worktrees/main-check main
cd .worktrees/main-check
git status --short
git diff --check
python3 -I tools/test_check_contract_sizes.py
python3 -I tools/test_check_slither_baseline.py
python3 -I tools/check_slither_baseline.py --slither slither
python3 -I tools/generate_full_math_vectors.py --check
python3 -I tools/generate_hash_vectors.py --check
python3 -I tools/check_q128_boundary_bound.py --check
forge fmt --check
forge build --skip test --deny warnings
forge build --sizes | tee /tmp/forge-sizes.txt
python3 -I tools/check_contract_sizes.py /tmp/forge-sizes.txt
forge test
```

Remove the temporary `main-check` worktree after verification. Next: implement the remaining
attachment/profile surfaces and complete qualification; do not broadcast production or testnet
transactions without explicit authorization.
