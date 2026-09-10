import type { Hex } from "viem";
import { ZERO_BYTES32 } from "../deal/types.ts";
import type { DualSignDraft as MatrixDraft } from "../eligibility/predicates.ts";

export const DUAL_SIGN_TYPES = ["MutualCancel", "CoSignedRelease", "MutualSplit"] as const;
export type DualSignType = (typeof DUAL_SIGN_TYPES)[number];

export type DualSignForm = {
  type: DualSignType | "";
  dealId: string;
  deadline: string;
  nonceP: string;
  nonceC: string;
  providerBps: string;
  providerSig: Hex | null;
  controllerSig: Hex | null;
};

export function emptyDualSign(dealId = ""): DualSignForm {
  return {
    type: "",
    dealId,
    deadline: "",
    nonceP: "2",
    nonceC: "3",
    providerBps: "2500",
    providerSig: null,
    controllerSig: null,
  };
}

export function isDraftComplete(form: DualSignForm): boolean {
  if (!form.type) return false;
  if (!form.dealId || form.dealId.toLowerCase() === ZERO_BYTES32) return false;
  if (!form.deadline || form.deadline === "0") return false;
  if (form.nonceP === "" || form.nonceC === "") return false;
  if (!form.providerSig || !form.controllerSig) return false;
  if (form.type === "MutualSplit" && form.providerBps === "") return false;
  return true;
}

export function toMatrixDraft(
  form: DualSignForm,
  extras: {
    now: bigint;
    usedP: boolean;
    usedC: boolean;
    provider: string;
    controller: string;
    recoveredP: string | null;
    recoveredC: string | null;
  },
): MatrixDraft {
  const complete = isDraftComplete(form);
  const deadline = form.deadline && form.deadline !== "" ? BigInt(form.deadline) : 0n;
  const bps = form.providerBps === "" ? undefined : Number(form.providerBps);
  return {
    type: form.type || null,
    complete,
    dealIdA: form.dealId,
    dealIdB: form.dealId,
    deadlineA: deadline,
    deadlineB: deadline,
    providerBpsA: bps,
    providerBpsB: bps,
    now: extras.now,
    usedP: extras.usedP,
    usedC: extras.usedC,
    provider: extras.provider,
    controller: extras.controller,
    recoveredP: extras.recoveredP,
    recoveredC: extras.recoveredC,
  };
}
