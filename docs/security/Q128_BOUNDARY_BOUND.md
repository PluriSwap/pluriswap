# Q128 Initial Boundary and Active-Source Replacement Bounds

## Scope

For one custody boundary
`(chainId, protocolVersion, CreditLedger, token)`, let:

- `S = 2^128`, the Q128.128 scale;
- `N` be the boundary's nominal exposure immediately before its first deficit checkpoint;
- `L` be the exact asset loss, where `0 <= L <= N`; and
- `A = N - L` be assets remaining after the loss.

Mandatory Core limits every boundary to:

```text
N <= MAX_BOUNDARY_NOMINAL = 2^128 - 1 = S - 1
```

Token amounts and position nominals remain `uint256`. The limit applies to the aggregate
boundary exposure, not to the width of an individual ABI or storage field.

This note proves two scoped properties:

1. the initial Q128 coefficient's materialized error for one position at the first deficit
   checkpoint; and
2. the `childCount - 1` replacement-dust bound for reachable nonclaimable active sources, which
   have zero paid assets and zero position-local claim history.

It does **not** complete the proof for repeated loss/recovery checkpoints, claims,
history/generation saturation, dust exhaustion, or fairness. Those remain separate release gates.

## Initial checkpoint

The exact initial unfunded gap is `L`. Production stores the upward-rounded coefficient:

```text
a = ceil(L * S / N)
```

and materializes the single-position gap conservatively:

```text
G = min(N, ceil(a * N / S))
```

By the definition of ceiling:

```text
L * S / N <= a < L * S / N + 1
```

Multiplying by the positive value `N / S` gives:

```text
L <= a * N / S < L + N / S
```

The boundary limit gives `N / S < 1`, therefore:

```text
L <= a * N / S < L + 1
```

Since `L` is an integer:

```text
L <= ceil(a * N / S) <= L + 1
```

Clamping the result to `N` cannot move it below `L` because `L <= N`, and cannot increase
the error. Thus:

```text
0 <= G - L <= 1 smallest token unit
```

The bound is tight. At `N = S - 1` and `L = 1`:

```text
a = 2
G = 2
G - L = 1
```

The materialized funded entitlement `F = N - G` is therefore at most one smallest unit below
`A = N - L` for this initial single-position case, and it is never above the exact entitlement.
The observable boundary reserve is:

```text
deficitRoundingDust = A - F = G - L
```

so it is also in `0..1`. At `N = S - 1`, `L = 1`, assets are `S - 2`, funded entitlement is
`S - 3`, and dust is exactly one. Production must store that dust before deriving the first
checkpoint identity or emitting its status-`4` records.

## Wide-boundary regression excluded by the cap

Without the boundary limit, `N = 2^256 - 1` and `L = 1` produce:

```text
a = 1
G = 2^128
G - L = 2^128 - 1
```

That is the prior wide-boundary precision collapse. At the admitted maximum, the same
one-unit loss materializes as two gap units, so the error is one unit rather than
`2^128 - 1`.

## Reachable active-source replacement

An active `DEAL` or `RESERVATION` cannot claim. Production enforces that it reaches terminal
replacement with zero paid assets and zero position-local history. Its children therefore use
only the current global gap coefficient; no parent-history scaling or saturation path exists.

Let a source have nominal `N`, coefficient `0 <= a <= S`, and a partition into `m` positive
children:

```text
N = n_1 + ... + n_m
1 <= m <= 3
```

Production materializes:

```text
G_parent   = ceil(a * N / S)
G_children = sum(ceil(a * n_j / S))
D_replace  = G_children - G_parent
```

For real values `x_j = a*n_j/S`, the standard ceiling-partition inequality is:

```text
ceil(sum(x_j)) <= sum(ceil(x_j)) <= ceil(sum(x_j)) + m - 1
```

Since `sum(x_j) = a*N/S`:

```text
0 <= D_replace <= m - 1
```

The lower inequality proves conservative direction; production retains an explicit lower-side
guard and rejects if it is ever violated. Because `a <= S`, every child gap is at most its child
nominal, so `G_children <= N`; the sum cannot overflow within the boundary cap. Allocation checks
give exact nominal conservation, and zero paid assets on both source and children gives exact paid
conservation. With at most three final children, replacement dust is at most two smallest token
units.

The consumed source stores the exact child-sum gap and `D_replace`. Thus:

```text
preSplitFunded = frozenFunded + D_replace
preSplitGap    = frozenGap - D_replace
```

No child can claim the shift; it remains gap unless a later exact attributable recovery funds it.

## Admission rule

Before funding execution, Ledger validates every applicable request and authorization, then
computes `addedUnits` from all `WALLET_PULL` legs in the atomic operation:

```text
addedUnits =
  principal amount       if principal source is WALLET_PULL, else 0
+ activation-fee amount  if fee source is WALLET_PULL, else 0
```

`LEDGER_POSITION` legs reassign existing nominal units in the same Ledger and add zero.
The addition is checked; an overflowing sum is represented as `uint256.max` for the typed
rejection data. Funding proceeds only when:

```text
nominalOutstanding <= MAX_BOUNDARY_NOMINAL
addedUnits <= MAX_BOUNDARY_NOMINAL - nominalOutstanding
```

The check is per token boundary. Reallocation at the cap is valid when `addedUnits == 0`,
and separate token boundaries have independent limits.

## Executable check

Run:

```sh
python3 -I tools/check_q128_boundary_bound.py --check
```

The dependency-free checker verifies production-scale initial and replacement edge cases, the
removed `uint256.max` regression, checked/saturating admission arithmetic, and exhaustively checks
both every `0 <= L <= N <= S - 1` and every one-to-three-child positive partition/coefficient for
reduced scales `2 <= S <= 32`.

Passing this check closes only the scoped initial precision-collapse and reachable replacement
bound blockers. It does not make the complete Q128 recovery model production-approved.
