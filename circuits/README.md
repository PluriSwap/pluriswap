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
    src/constants_p2.nr, constants_p3.nr   # GENERATED — circomlib round constants
    src/vectors.nr                          # GENERATED — the vectors as Noir constants
  js/
    lib/fields.ts, poseidon.ts, commitments.ts, merkle.ts   # the JS twin
    vectors.ts                    # generator: vectors.json + the GENERATED .nr files
```

## Commands

```sh
bun circuits:vectors    # regenerate test/fixtures/vectors.json + constants_p*.nr + vectors.nr
(cd circuits && nargo test)   # parity tests: zero gate (circomlib vector) + builders + tree
forge test --match-contract PrivacyCommitmentsTest   # the Solidity twin against the same fixture
```

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
