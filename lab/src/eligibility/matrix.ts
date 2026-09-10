import type { DealSnapshot } from "../deal/types.ts";
import { R, type Eval, type VerbClass } from "./errors.ts";
import {
  evalActivate,
  evalCancelByProvider,
  evalCancelNonce,
  evalClaim,
  evalCoSignedRelease,
  evalForceArbitrationTimeout,
  evalForceStalemate,
  evalMarkFiat,
  evalMutualCancel,
  evalMutualSplit,
  evalOpenCourt,
  evalOpenDisputed,
  evalReadRuling,
  evalRelease,
  evalTimeoutFiat,
  evalVerifyProof,
  evalWithdraw,
  type DualSignDraft,
  type MatrixInput,
} from "./predicates.ts";

export type MatrixRow = {
  verb: string;
  class: VerbClass;
  requiredStatus: string;
  kinds: string;
  clock: string;
  senderSeat: string;
  eval: Eval;
};

export function buildMatrix(input: MatrixInput): MatrixRow[] {
  const rows: Omit<MatrixRow, "eval">[] = [
    {
      verb: "activate",
      class: "anyone",
      requiredStatus: "NONE",
      kinds: "n/a",
      clock: "n/a",
      senderSeat: "Relayer",
    },
    {
      verb: "markFiat",
      class: "rol",
      requiredStatus: "FUNDED",
      kinds: "¬ZK",
      clock: "n/a",
      senderSeat: "Provider",
    },
    {
      verb: "cancelByProvider",
      class: "rol",
      requiredStatus: "FUNDED",
      kinds: "n/a",
      clock: "n/a",
      senderSeat: "Provider",
    },
    {
      verb: "timeoutFiat",
      class: "anyone",
      requiredStatus: "FUNDED",
      kinds: "incl. ZK",
      clock: "due fiatDeadline",
      senderSeat: "anyone",
    },
    {
      verb: "release",
      class: "rol",
      requiredStatus: "FIAT_SENT",
      kinds: "n/a",
      clock: "n/a",
      senderSeat: "Controller",
    },
    {
      verb: "claim",
      class: "anyone",
      requiredStatus: "FIAT_SENT",
      kinds: "¬ZK",
      clock: "due releaseDeadline",
      senderSeat: "anyone",
    },
    {
      verb: "openDisputed",
      class: "rol",
      requiredStatus: "FIAT_SENT",
      kinds: "¬ZK",
      clock: "strictly-before releaseDeadline",
      senderSeat: "Controller",
    },
    {
      verb: "forceStalemate",
      class: "anyone",
      requiredStatus: "DISPUTED",
      kinds: "n/a",
      clock: "due disputeDeadline",
      senderSeat: "anyone",
    },
    {
      verb: "mutualCancel",
      class: "dual-sign",
      requiredStatus: "FUNDED|FIAT_SENT|DISPUTED|ARBITRATION_ACTIVE",
      kinds: "n/a",
      clock: "draft deadline",
      senderSeat: "Relayer",
    },
    {
      verb: "coSignedRelease",
      class: "dual-sign",
      requiredStatus: "FIAT_SENT|DISPUTED|ARBITRATION_ACTIVE",
      kinds: "n/a",
      clock: "draft deadline",
      senderSeat: "Relayer",
    },
    {
      verb: "mutualSplit",
      class: "dual-sign",
      requiredStatus: "FIAT_SENT|DISPUTED|ARBITRATION_ACTIVE",
      kinds: "n/a",
      clock: "draft deadline",
      senderSeat: "Relayer",
    },
    {
      verb: "verifyProof",
      class: "anyone",
      requiredStatus: "FUNDED",
      kinds: "ZK",
      clock: "n/a",
      senderSeat: "anyone",
    },
    {
      verb: "openCourt",
      class: "rol",
      requiredStatus: "FIAT_SENT|DISPUTED",
      kinds: "ARB ¬ZK",
      clock: "strictly-before",
      senderSeat: "Controller",
    },
    {
      verb: "readRuling",
      class: "anyone",
      requiredStatus: "ARBITRATION_ACTIVE",
      kinds: "ARB",
      clock: "n/a",
      senderSeat: "anyone",
    },
    {
      verb: "forceArbitrationTimeout",
      class: "anyone",
      requiredStatus: "ARBITRATION_ACTIVE",
      kinds: "ARB",
      clock: "due arbitrationDeadline",
      senderSeat: "anyone",
    },
    {
      verb: "withdraw",
      class: "rol",
      requiredStatus: "n/a",
      kinds: "n/a",
      clock: "n/a",
      senderSeat: "beneficiario",
    },
    {
      verb: "cancelNonce",
      class: "anyone",
      requiredStatus: "n/a",
      kinds: "n/a",
      clock: "n/a",
      senderSeat: "msg.sender",
    },
  ];

  const evals: Record<string, (i: MatrixInput) => Eval> = {
    activate: (i) => evalActivate(i.deal),
    markFiat: evalMarkFiat,
    cancelByProvider: evalCancelByProvider,
    timeoutFiat: evalTimeoutFiat,
    release: evalRelease,
    claim: evalClaim,
    openDisputed: evalOpenDisputed,
    forceStalemate: evalForceStalemate,
    mutualCancel: evalMutualCancel,
    coSignedRelease: evalCoSignedRelease,
    mutualSplit: evalMutualSplit,
    verifyProof: evalVerifyProof,
    openCourt: evalOpenCourt,
    readRuling: evalReadRuling,
    forceArbitrationTimeout: evalForceArbitrationTimeout,
    withdraw: evalWithdraw,
    cancelNonce: evalCancelNonce,
  };

  return rows.map((row) => ({ ...row, eval: evals[row.verb]!(input) }));
}

export function matrixForDeal(
  deal: DealSnapshot,
  sender: string | null,
  extras: { credit?: bigint | null; ruling?: number | null; dualSign?: DualSignDraft | null } = {},
): MatrixRow[] {
  return buildMatrix({
    deal,
    sender,
    credit: extras.credit ?? null,
    ruling: extras.ruling ?? null,
    dualSign: extras.dualSign ?? null,
  });
}

export { R };
