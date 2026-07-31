# Mandatory Core Remediation Handoff

**Status:** Deployment-identity redesign closed; next is triad architecture correction
**Date:** 2026-07-31
**Branch:** `fix/mandatory-core-remediation`
**Worktree:** `/Users/econti/Documents/emi/pluriswap/.worktrees/mandatory-core-remediation`
**Implementation plan:** `/Users/econti/.cursor/plans/Mandatory Core Remediation-b00fe0e2.plan.md`
**Identity plan:** `/Users/econti/.cursor/plans/Deployment Intent Evidence-67fe2be4.plan.md`

## Safety and repository state

- Work is isolated in the worktree above.
- The original workspace at `/Users/econti/Documents/emi/pluriswap` and its pre-existing uncommitted files were not modified by this branch.
- Nothing has been staged, committed, or pushed.
- Local CI-quality, independent-evidence, and Intent/Evidence gates are green.

## Completed this session (deployment identity)

1. **Spec:** `MANDATORY_CORE.md` §13 split into `CoreDeploymentIntentV1` / `CoreDeploymentEvidenceV1`; `deploymentIdentity = intentHash`. Mirrored in `PROTOCOL.md` (DISC-001/010) and architecture immutability design.
2. **Solidity:** `src/libraries/ManifestTypes.sol` + `ManifestHashing.sol`; removed opaque `CoreManifestOffchain` / `hashCoreManifest`.
3. **Binding:** `CoreDeployer` / `CoreEscrow` store and emit `intentHash` (`IntentComputed`); Escrow constructor binds Intent only.
4. **Tooling/tests:** `DeployCore.s.sol`, hash-vector generator (Intent + Evidence), all triad tests updated; creation-code constants refreshed.
5. Explicitly still deferred: full nested-preimage CLI, release-container artifact regeneration, `deploy.sh`/`deploy.toml` overhaul.

## Last fully verified checkpoint

- Foundry: **264 passed, 0 failed**.
- Hash-vector drift check passes.
- Production `--deny warnings` build passes; size gate unchanged (`CoreEscrow` 21,654 / `CreditLedger` 21,929 / `CoreDeployer` 3,987 / `Coordinator` 1,322).

## Remaining work, in order

1. ~~CI-quality follow-up~~ **DONE**
2. ~~Production Q128 evidence expansion~~ **DONE** (external economic review still required)
3. ~~Independent evidence hardening~~ **DONE**
4. ~~Redesign deployment identity~~ **DONE** (nested-preimage CLI / release container deferred)
5. **Correct the triad architecture before attachments**
   - Move settlement planning/terminal construction out of Ledger.
   - Fix `planSettlement` callback direction so Ledger does not own business planning.
6. **Implement full `0.3.0-rc1` surfaces**
7. **Qualification**

## Known blockers and constraints

- Production remains **NO-GO**.
- Independent Q128 economic/security review remains external.
- `CreditLedger.planSettlement` still owns business planning and calls back into Core.
- Mandatory profile/attachment entrypoints remain unimplemented stubs.
- Full bottom-up nested Intent/Evidence preimage generator is not yet built.

## Resume commands

```bash
cd "/Users/econti/Documents/emi/pluriswap/.worktrees/mandatory-core-remediation"
git status --short
git diff --check
python3 -I tools/test_check_contract_sizes.py
python3 -I tools/test_check_slither_baseline.py
python3 -I tools/generate_full_math_vectors.py --check
python3 -I tools/generate_hash_vectors.py --check
python3 -I tools/check_q128_boundary_bound.py --check
forge fmt --check
forge build --skip test --deny warnings
forge build --sizes | tee /tmp/forge-sizes.txt
python3 -I tools/check_contract_sizes.py /tmp/forge-sizes.txt
forge test
```

Next: correct triad architecture (`planSettlement` / terminal construction ownership) before attachment surfaces.
