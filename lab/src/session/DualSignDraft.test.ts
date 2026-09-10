import { describe, expect, it } from "vitest";
import { ZERO_BYTES32 } from "../deal/types.ts";
import { emptyDualSign, isDraftComplete } from "./DualSignDraft.ts";

describe("isDraftComplete", () => {
  it("is incomplete when deadline is 0 even if sigs exist", () => {
    const form = emptyDualSign("0x1111111111111111111111111111111111111111111111111111111111111111");
    form.type = "MutualCancel";
    form.deadline = "0";
    form.providerSig = "0xab";
    form.controllerSig = "0xcd";
    expect(isDraftComplete(form)).toBe(false);
  });

  it("treats nonce 0 as set", () => {
    const form = emptyDualSign("0x1111111111111111111111111111111111111111111111111111111111111111");
    form.type = "MutualCancel";
    form.deadline = "99";
    form.nonceP = "0";
    form.nonceC = "0";
    form.providerSig = "0xab";
    form.controllerSig = "0xcd";
    expect(isDraftComplete(form)).toBe(true);
  });

  it("does not treat providerBps=10000 as CoSignedRelease", () => {
    const form = emptyDualSign("0x1111111111111111111111111111111111111111111111111111111111111111");
    form.type = "MutualSplit";
    form.deadline = "99";
    form.providerBps = "10000";
    form.providerSig = "0xab";
    form.controllerSig = "0xcd";
    expect(form.type).toBe("MutualSplit");
    expect(isDraftComplete(form)).toBe(true);
  });

  it("zero dealId is incomplete", () => {
    const form = emptyDualSign(ZERO_BYTES32);
    form.type = "MutualCancel";
    form.deadline = "99";
    form.providerSig = "0xab";
    form.controllerSig = "0xcd";
    expect(isDraftComplete(form)).toBe(false);
  });
});
