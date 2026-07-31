# Slither triage

Mandatory Core pins `slither-analyzer==0.11.6` in `requirements-slither.txt`. CI installs that
version and runs:

```text
python3 -I tools/check_slither_baseline.py
```

The wrapper verifies the executable version, requires successful Slither JSON output, and compares
every current detector fingerprint with `slither-baseline.json`. It fails on:

- a Slither/compiler/tool error;
- any new finding at any severity (including every new high or medium finding);
- duplicate or metadata-drifted fingerprints;
- an accepted entry without a reason; or
- a stale baseline entry whose finding disappeared.

`slither.config.json` excludes only `naming-convention`. That detector is informational style output,
and the production-only Foundry lint/build gate already reports source naming diagnostics. Existing
wire names and public getter names are intentionally stable. Security, arithmetic, external-call,
assembly, complexity, and optimization detectors remain enabled.

## Accepted detector classes

Each current finding has its own fingerprint, location, impact, confidence, and short reason in the
baseline. Repeated reasons below describe the reviewed implementation pattern; they are not wildcard
suppression rules.

- **FullMath XOR and divide-before-multiply.** `FullMath.mulDiv` is the reviewed Remco
  Bloemen/Uniswap full-precision algorithm. `(3 * denominator) ^ 2` intentionally uses bitwise XOR
  to seed a modular inverse; it is not exponentiation. The reported divisions remove exact powers
  of two before Newton-Raphson inverse multiplication. FullMath vectors and arithmetic tests cover
  these paths.
- **Exact-transfer low-level calls.** `ExactERC20` deliberately uses bounded `call`/`staticcall` so
  it can validate optional ERC-20 return data and exact before/after balances. A high-level IERC20
  call cannot enforce this boundary. `SignatureValidation` uses bounded `staticcall` for ERC-1271
  and checks the magic value.
- **Guarded reentrancy ordering.** Every reported state-changing entrypoint is protected by its
  contract's `nonReentrant` guard. Calls cross only the immutable Escrow/Ledger links or the
  exact-token boundary. State and nonces commit after the external operation so any downstream
  failure atomically rolls the transaction back. Read-only getters may observe pre-commit state
  during a malicious token callback, but no guarded transition can reenter.
- **Default-zero locals.** Accumulators are now explicitly initialized. The remaining finding is a
  fixed-size memory allocation array whose Solidity-defined zero initialization is required by the
  bounded append/coalescing routine; its separate count prevents unread entries from escaping.
- **Unsupported Ether.** Core token custody is ERC-20-only. The payable arbitration stub always
  reverts in this Core-only candidate; ordinary native-ETH sends are unsupported. Ether forcibly
  delivered by protocol-independent mechanisms is intentionally unrecoverable: adding an
  authority-bearing sweep would violate the custody model. No protocol accounting or outcome may
  depend on such a balance.
- **Exact equality and timestamps.** Equality findings are closed enum/status, zero-boundary, or
  exact-accounting branches. Timestamp comparisons implement signed expiry and deadline rules, not
  randomness; the `uint64` horizon and no-mutation failures are normative and tested.
- **Bounded loops and complexity.** The reported external call in a loop is Escrow-only over the
  protocol-bounded sorted token set. Complexity findings correspond to closed validation and state
  case tables where preserving check order is clearer than adding indirection.
- **Assembly.** The accepted memory-safe blocks implement CREATE, 512-bit arithmetic, exact ABI-word
  decoding, or canonical signature decoding. Their individual fingerprints remain visible.

## Updating the baseline

Do not update the baseline merely to make CI green. After investigating and fixing actionable
findings, capture a successful report with the pinned version and reviewed config. Then run:

```text
python3 -I tools/generate_slither_baseline.py report.json candidate-baseline.json
python3 -I tools/check_slither_baseline.py \
  --report report.json \
  --baseline candidate-baseline.json
```

Review every candidate entry and reason before replacing `slither-baseline.json`. The generator
refuses detector classes without an explicit reviewed reason.
