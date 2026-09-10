import { expect, it } from "vitest";
import { CORE_WRITE_VERBS, isCoreWrite } from "./coreWrites.ts";

it("does not treat dual-sign or activate as PR-5 core writes", () => {
  expect(CORE_WRITE_VERBS).toHaveLength(9);
  expect(isCoreWrite("markFiat")).toBe(true);
  expect(isCoreWrite("cancelNonce")).toBe(true);
  expect(isCoreWrite("activate")).toBe(false);
  expect(isCoreWrite("mutualCancel")).toBe(false);
  expect(isCoreWrite("verifyProof")).toBe(false);
});
