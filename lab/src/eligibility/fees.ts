import type { LivePolicy } from "../slots/types.ts";
import { disabled, type Eval } from "./errors.ts";

export type FeeStop = { step: string; eval: Eval };

export type FeeProjection = {
  /// Set when a declared fee is degenerate. `_invoice` skips a fee that does not fit (`fee >= left`), so a fee
  /// at or above the principal never collects: the packageId being signed does not do what it appears to do.
  stop: FeeStop | null;
  /// What the Provider receives on a Provider-positive terminal, or null when no fee-bearing package is bound.
  netToProvider: bigint | null;
  /// What the Holder must have approved *on top of* the principal. `Packages.engage` pulls it before the
  /// principal pull, so an allowance sized to the principal alone reverts inside the token -- not with
  /// `Settlement.InexactPull`, which only fires when a transfer succeeds and the delta comes up short.
  activationFee: bigint;
  /// What the opener must have approved when entering a fight. Pulled from `msg.sender` at
  /// `openDisputed` / `openCourt` from `FIAT_SENT`, not from the principal. Core-only is 0.
  contestFee: bigint;
};

/// Mirrors `Escrow._invoice`. A fee is collected only while it is strictly below what is left to split, so a
/// fee equal to the remaining pot is skipped and the winner keeps it all. The ZK verify fee is invoiced on the
/// principal at `verifyProof`; the completion fee is invoiced on that leftover at the terminal.
///
/// Both fees are immutable and bound into the signed `packageId`, which is why this has to run before the
/// signature: nothing on-chain will stop a Provider from signing a deal whose fee eats the whole trade.
export function projectFees(principal: bigint, policy: LivePolicy | null): FeeProjection {
  const completionFee = policy?.reputation?.completionFee ?? null;
  const activationFee = policy?.reputation?.activationFee ?? 0n;
  const contestFee = policy?.reputation?.contestFee ?? 0n;
  const verifyFee = policy?.zk?.verifyFee ?? null;

  if (completionFee !== null && completionFee >= principal) {
    return {
      stop: {
        step: "completionFee < principal",
        eval: disabled("completionFee >= principal: el fee nunca se cobra", "ui-policy"),
      },
      netToProvider: null,
      activationFee,
      contestFee,
    };
  }
  if (verifyFee !== null && verifyFee >= principal) {
    return {
      stop: {
        step: "verifyFee < principal",
        eval: disabled("verifyFee >= principal: el fee nunca se cobra", "ui-policy"),
      },
      netToProvider: null,
      activationFee,
      contestFee,
    };
  }
  if (completionFee === null && verifyFee === null) {
    return { stop: null, netToProvider: null, activationFee, contestFee };
  }

  let net = principal;
  if (verifyFee !== null && verifyFee > 0n) net -= verifyFee;
  if (completionFee !== null && completionFee > 0n && completionFee < net) net -= completionFee;
  return { stop: null, netToProvider: net, activationFee, contestFee };
}
