import { addDuration, isDue, isStrictlyBefore } from "../deal/clocks.ts";
import { PKG, Status, type DealSnapshot } from "../deal/types.ts";
import { R, disabled, enabled, type Eval } from "./errors.ts";

export type DualSignDraft = {
  type: "MutualCancel" | "CoSignedRelease" | "MutualSplit" | null;
  complete: boolean;
  dealIdA?: string;
  dealIdB?: string;
  deadlineA?: bigint;
  deadlineB?: bigint;
  providerBpsA?: number;
  providerBpsB?: number;
  now?: bigint;
  usedP?: boolean;
  usedC?: boolean;
  provider?: string;
  controller?: string;
  recoveredP?: string | null;
  recoveredC?: string | null;
};

export type MatrixInput = {
  deal: DealSnapshot;
  sender: string | null;
  credit: bigint | null;
  ruling: number | null;
  dualSign: DualSignDraft | null;
};

function isZk(deal: DealSnapshot): boolean {
  return (deal.kinds & PKG.ZK) !== 0;
}

function isArb(deal: DealSnapshot): boolean {
  return (deal.kinds & PKG.ARB) !== 0;
}

function eq(a: string, b: string): boolean {
  return a.toLowerCase() === b.toLowerCase();
}

function requireSender(sender: string | null): Eval | null {
  if (!sender) return disabled(R.NoSender, "ui-policy");
  return null;
}

function clockDue(origin: bigint, duration: bigint, now: bigint): Eval | null {
  const { deadline, overflow } = addDuration(origin, duration);
  if (overflow) return disabled(R.Overflow);
  if (isDue(now, deadline, overflow) === false) return disabled(R.TooEarly);
  return null;
}

function clockStrictlyBefore(origin: bigint, duration: bigint, now: bigint): Eval | null {
  const { deadline, overflow } = addDuration(origin, duration);
  if (overflow) return disabled(R.Overflow);
  if (isStrictlyBefore(now, deadline, overflow) === false) return disabled(R.TooLate);
  return null;
}

export function evalActivate(deal: DealSnapshot): Eval {
  if (deal.status !== Status.NONE) return disabled(R.DealExists);
  return enabled();
}

export function evalMarkFiat(input: MatrixInput): Eval {
  const { deal, sender } = input;
  if (deal.status !== Status.FUNDED) return disabled(R.WrongStatus);
  if (isZk(deal)) return disabled(R.EdgeOff);
  const missing = requireSender(sender);
  if (missing) return missing;
  if (!eq(sender!, deal.terms.provider)) return disabled(R.Unauthorized);
  return enabled();
}

export function evalCancelByProvider(input: MatrixInput): Eval {
  const { deal, sender } = input;
  if (deal.status !== Status.FUNDED) return disabled(R.WrongStatus);
  const missing = requireSender(sender);
  if (missing) return missing;
  if (!eq(sender!, deal.terms.provider)) return disabled(R.Unauthorized);
  return enabled();
}

export function evalTimeoutFiat(input: MatrixInput): Eval {
  const { deal } = input;
  if (deal.status !== Status.FUNDED) return disabled(R.WrongStatus);
  return clockDue(deal.clocks.activatedAt, deal.terms.fiatDuration, deal.blockTimestamp) ?? enabled();
}

export function evalRelease(input: MatrixInput): Eval {
  const { deal, sender } = input;
  if (deal.status !== Status.FIAT_SENT) return disabled(R.WrongStatus);
  const missing = requireSender(sender);
  if (missing) return missing;
  if (!eq(sender!, deal.terms.controller)) return disabled(R.Unauthorized);
  return enabled();
}

export function evalClaim(input: MatrixInput): Eval {
  const { deal } = input;
  if (deal.status !== Status.FIAT_SENT) return disabled(R.WrongStatus);
  if (isZk(deal)) return disabled(R.EdgeOff);
  return clockDue(deal.clocks.fiatSentAt, deal.terms.releaseDuration, deal.blockTimestamp) ?? enabled();
}

export function evalOpenDisputed(input: MatrixInput): Eval {
  const { deal, sender } = input;
  if (deal.status !== Status.FIAT_SENT) return disabled(R.WrongStatus);
  if (isZk(deal)) return disabled(R.EdgeOff);
  const missing = requireSender(sender);
  if (missing) return missing;
  if (!eq(sender!, deal.terms.controller)) return disabled(R.Unauthorized);
  return (
    clockStrictlyBefore(deal.clocks.fiatSentAt, deal.terms.releaseDuration, deal.blockTimestamp) ??
    enabled()
  );
}

export function evalForceStalemate(input: MatrixInput): Eval {
  const { deal } = input;
  if (deal.status !== Status.DISPUTED) return disabled(R.WrongStatus);
  return clockDue(deal.clocks.disputedAt, deal.terms.disputeDuration, deal.blockTimestamp) ?? enabled();
}

function evalDualSignEnvelope(
  draft: DualSignDraft | null,
  expected: DualSignDraft["type"],
  live: boolean,
  split: boolean,
): Eval {
  if (!draft || draft.type !== expected || !draft.complete) {
    return disabled(R.DraftEmpty, "ui-policy");
  }
  if (draft.dealIdA !== draft.dealIdB) return disabled(R.DealIdMismatch);
  if (draft.deadlineA !== draft.deadlineB) return disabled(R.DeadlineMismatch);
  if (draft.now !== undefined && draft.deadlineA !== undefined && draft.now > draft.deadlineA) {
    return disabled(R.DeadlinePassed);
  }
  if (split) {
    if (draft.providerBpsA !== draft.providerBpsB) return disabled(R.BpsMismatch);
    if ((draft.providerBpsA ?? 0) > 10_000) return disabled(R.BpsMismatch);
  }
  if (!live) return disabled(R.WrongStatus);
  if (draft.recoveredP && draft.provider && draft.recoveredP.toLowerCase() !== draft.provider.toLowerCase()) {
    return disabled("Escrow.InvalidProviderSignature");
  }
  if (
    draft.recoveredC &&
    draft.controller &&
    draft.recoveredC.toLowerCase() !== draft.controller.toLowerCase()
  ) {
    return disabled("Escrow.InvalidControllerSignature");
  }
  if (draft.usedP || draft.usedC) return disabled("Escrow.NonceUsed");
  return enabled();
}

export function evalMutualCancel(input: MatrixInput): Eval {
  const s = input.deal.status;
  const live =
    s === Status.FUNDED ||
    s === Status.FIAT_SENT ||
    s === Status.DISPUTED ||
    s === Status.ARBITRATION_ACTIVE;
  return evalDualSignEnvelope(input.dualSign, "MutualCancel", live, false);
}

export function evalCoSignedRelease(input: MatrixInput): Eval {
  const s = input.deal.status;
  const live = s === Status.FIAT_SENT || s === Status.DISPUTED || s === Status.ARBITRATION_ACTIVE;
  return evalDualSignEnvelope(input.dualSign, "CoSignedRelease", live, false);
}

export function evalMutualSplit(input: MatrixInput): Eval {
  const s = input.deal.status;
  const live = s === Status.FIAT_SENT || s === Status.DISPUTED || s === Status.ARBITRATION_ACTIVE;
  return evalDualSignEnvelope(input.dualSign, "MutualSplit", live, true);
}

export function evalVerifyProof(input: MatrixInput): Eval {
  const { deal } = input;
  if (deal.status !== Status.FUNDED) return disabled(R.WrongStatus);
  if (!isZk(deal)) return disabled(R.PackageNotSelected);
  return enabled();
}

export function evalOpenCourt(input: MatrixInput): Eval {
  const { deal, sender } = input;
  if (!isArb(deal)) return disabled(R.PackageNotSelected);
  if (isZk(deal)) return disabled(R.EdgeOff);
  if (deal.status !== Status.FIAT_SENT && deal.status !== Status.DISPUTED) {
    return disabled(R.WrongStatus);
  }
  const missing = requireSender(sender);
  if (missing) return missing;
  if (!eq(sender!, deal.terms.controller)) return disabled(R.Unauthorized);
  if (deal.status === Status.FIAT_SENT) {
    return (
      clockStrictlyBefore(deal.clocks.fiatSentAt, deal.terms.releaseDuration, deal.blockTimestamp) ??
      enabled()
    );
  }
  return (
    clockStrictlyBefore(deal.clocks.disputedAt, deal.terms.disputeDuration, deal.blockTimestamp) ??
    enabled()
  );
}

export function evalReadRuling(input: MatrixInput): Eval {
  const { deal, ruling } = input;
  if (deal.status !== Status.ARBITRATION_ACTIVE) return disabled(R.WrongStatus);
  if (ruling === 0) return disabled(R.NotRuled);
  return enabled();
}

export function evalForceArbitrationTimeout(input: MatrixInput): Eval {
  const { deal } = input;
  if (deal.status !== Status.ARBITRATION_ACTIVE) return disabled(R.WrongStatus);
  return (
    clockDue(deal.clocks.arbitrationOpenedAt, deal.terms.arbitrationDuration, deal.blockTimestamp) ??
    enabled()
  );
}

export function evalWithdraw(input: MatrixInput): Eval {
  const missing = requireSender(input.sender);
  if (missing) return missing;
  if (input.credit === 0n) return disabled(R.NoOp, "ui-policy");
  return enabled();
}

export function evalCancelNonce(input: MatrixInput): Eval {
  const missing = requireSender(input.sender);
  if (missing) return missing;
  return enabled();
}
