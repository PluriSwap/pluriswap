# circuits

The ZK layer of the private privacy package (PLURISWAP.md §3.15): the Noir workspace whose
circuits prove the commitments of §3.15.3, and the JS twin that generates witnesses and
vectors. Three languages hash identically — Noir (in-circuit), JS (prover-side), Solidity
(`src/packages/libraries/PrivacyCommitments.sol`, on-chain) — pinned byte for byte by
`test/fixtures/vectors.json`.

## Pinned toolchain

The proofs are committed as fixtures, so CI never needs these binaries — only a developer
(re)generating proofs or vectors does.

| Tool | Version | sha256 |
| --- | --- | --- |
| nargo | v1.0.0-rc.2 (noirc `0ecc97a242ed37c0d1567e25747ed8d4c59cae49`) | `0ec71f00913a98b4278f107ff736605f3c86ac4c63ca5a46206a083f3536fe28` |
| bb | v6.0.0-nightly.20260916 (ultra_honk) | `5bf4dbe0d8fd6d95e1f0bb238b18f70fb3e5df95ab71dcf5240c26b6ef8084a5` |

Both live at `~/.pluri-zk/bin`. The scheme is **ultra_honk**: `bb prove` then
`bb write_solidity_verifier --optimized` emits the verifier contract the adapters verify
against (~14KB runtime, inside EIP-170).

## Layout

```
circuits/
  Nargo.toml                      # workspace
  crates/pluri_commitments/       # the canonical commitments library (V0)
    src/poseidon2.nr, poseidon3.nr  # vendored circomlib Poseidon (BN254, x^5, 8F+56/57P)
    src/commitments.nr             # every builder of §3.15.3 + parity tests
    src/merkle.nr                  # membership witness folding + parity tests
    src/tiers.nr                   # §3.14.7 in-circuit: score + cap_raw (T5 sentinel)
    src/constants_p2.nr, constants_p3.nr   # GENERATED — circomlib round constants
    src/vectors.nr                          # GENERATED — the vectors as Noir constants
  crates/register_humanity/       # V1: hn binding + enrollment membership (3 pubs)
  crates/register_account/        # V1: leaf0 = leafRep(S=Poseidon(hsk), genesis) (3 pubs)
  crates/prepare_passport/        # V2: dealSubject + account membership (2 pubs)
  crates/prepare_admit/          # V2: the §3.14.7 tier in-circuit + the transition (8 pubs)
  crates/deposit/                 # V3: the value gate — note pinned to the amount (3 pubs)
  crates/prepare_bond/            # V3: the note split — conservation in-circuit (8 pubs)
  crates/claim/                   # V3: the §3.15.5 terminal delta as arithmetic (8 pubs)
  crates/reabsorb/                # V3: the released lock merges back (7 pubs, no root)
  crates/withdraw/                # V3: the exit — conservation + whole-consumption mask (6 pubs)
  crates/attest_base/             # F4: the listing attestation — tier/count as LOWER bounds (7 pubs, off-chain)
  crates/reveal_advanced/         # F4: the profile reveal — chosen fields as mask arithmetic (7 pubs, off-chain)
  js/
    lib/fields.ts, poseidon.ts, commitments.ts, merkle.ts, tiers.ts   # the JS twin
    lib/verify.ts, chain.ts       # F4: the consumer side — bb verify + semantic checks + chain consistency
    lib/verify.test.ts, chain.test.ts   # the F4 suite: semantics on stubs; the real-bb path skips itself without the toolchain
    vectors.ts                    # generator: vectors.json + the GENERATED .nr files
    prove.ts                      # prover: witness TOMLs + proofs + verifiers + initcode (+ VK fixtures for F4)
```

## Commands

```sh
bun circuits:vectors    # regenerate test/fixtures/vectors.json + constants_p*.nr + vectors.nr
(cd circuits && nargo test)   # parity tests: zero gate (circomlib vector) + builders + tree
bun circuits:test       # the F4 consumer side: verify/chain semantics (stubs; the real-bb
                        # fixture path skips itself where the toolchain is absent)
forge test --match-contract PrivacyCommitmentsTest   # the Solidity twin against the same fixture
```

## The off-chain circuits (F4)

`attest_base` and `reveal_advanced` are verified OFF-CHAIN (§3.15.9): no adapter, no
Solidity verifier, no initcode. What prove.ts commits for them is the proof (the same
`test/fixtures/proofs/<name>.json` blob format) plus the **verification key**
(`test/fixtures/vks/<name>.json`, bare hex) — the consumer pins the VK exactly like the
adapters pin initcode; nothing deploys it. The consumer surface is `circuits/js/lib/verify.ts`:
`bb verify` (the same pinned binary, or a future bb.js/WASM verifier via
`opts.verifyProof`) + the semantic checks the circuit cannot make — `expiry` against the
consumer's clock, `decimals` against the served ERC-20, `repRoot` against the tree's
live roots. The public-input binding is part of the Honk statement (the same wire that
pins withdraw's `dest`), and the tamper tests of `verify.test.ts` pin that empirically:
an edited pub — an overstated tier, a re-targeted requester — breaks `bb verify`.

The zero gate is `poseidonT3(1, 2) == 7853200120776062878684798364095072458815029376092732009249414926327459813530`
(circomlib `poseidonperm_x5_254_3([1,2])`, the same vector `test/PoseidonTree.t.sol` pins) —
if it holds in JS and in Noir, the parameters are circomlib's and everything built on them
agrees with poseidon-solidity on-chain.

## Field rules (§3.15.3, as amended)

- Every `bytes32` input is interpreted **mod p** (BN254 scalar). Raw keccak-derived IDs
  (≥ p) need no pre-reduction: all three twins reduce identically.
- Multi-field commitments chain PoseidonT3 in the pinned left fold
  `h0 = f0, hi = PoseidonT3(h(i-1), fi)`.
- Nullifier tags: `"rep" | "bond" | "handle"` = field constants `1 | 2 | 3`.
- Noir's `std::hash::poseidon` is deliberately NOT used — the protocol's parameters are
  circomlib's, so Poseidon is vendored here with those exact constants.

## The verifier compile profile (read before touching foundry.toml)

Generated Honk verifiers do not compile under `via_ir = true`: solc's stack layout pass
diverges on their flat ultra-wide dispatchers ("could not create stack layout after 1000
iterations", reproduced on every solc 0.8.28–0.8.35). They are generated to run
optimizer-only. Therefore:

- `[profile.default]` skips `src/packages/verifiers/*` entirely;
- `[profile.verifiers]` recompiles the tree with `via_ir = false` when the verifiers'
  artifacts are needed (their **initcode is committed as fixtures** and the adapters
  deploy from it, so the default profile never links them).

## Noir grammar notes for this pinned nargo

- Module-level constants are `pub global` (`const` is function-local; `pub const` does not parse).
- Numeric generics: `<let N: u32>`; turbofish wants literals (`compute_root::<8>(...)`).
- No `&&`/`||` — use `&`/`|` on bools; `use` is module-level only.
- No relational or bitwise operators on `Field` — compare through a cast round-trip:
  `assert((x as u128) as Field == x)` proves "x < 2^128" while `x as u128 > y` does the
  ordered comparison in the integer domain.
- `&` binds tighter than `==` — parenthesize every `(a == b) & (c == d)` conjunction.

## The negated-guard codegen bug (read before writing any circuit with a conditional check)

A **statement-if whose guard is negated** (`if !cond { ... }`) around a large constrained
body makes `bb write_solidity_verifier --optimized` emit an EVM verifier that **rejects its
own valid proofs**: `bb verify` passes natively, the deployed Honk contract returns false.
Bisected on prepare_admit with the identical pinned pipeline: excising the body passes,
making the body unconditional passes, and only the negated guard around it fails. LOG_N,
the public-input count and array witnesses are all exonerated.

The protocol's circuits therefore never wrap a bound check in a negated guard. Where §3.14.7
needs "unbounded" (T5), `tiers.nr` encodes it as the sentinel `T5_SENTINEL = 2^128 - 1` and
`prepare_admit` runs the cap comparison **unconditionally** — `cap_raw()` returns the
sentinel for T5, so `newLeaf's principal <= cap` holds for every tier in one flat check.
Keep that shape: conditional logic belongs in the sentinel arithmetic, not in the control flow.
The same rule produced the claim circuit's delta (`§3.15.5`'s five Close kinds as field
selectors `count + (kind == 0)`, never an if-ladder) and the withdraw's whole-consumption
mask (`changeNote == (1 - whole) * noteBond(...)`) — zero exactly when the note is spent whole.

