import { expect, it } from "vitest";
import { decodeKinds } from "./kinds.ts";

it("decodes the kernel bitmap 1/2/4/8/16", () => {
  const flags = decodeKinds(1 | 2 | 4);
  expect(flags.filter((f) => f.on).map((f) => f.name)).toEqual(["PASSPORT", "REPUTATION", "BONDS"]);
  expect(decodeKinds(8).find((f) => f.name === "ZK")?.on).toBe(true);
  expect(decodeKinds(16).find((f) => f.name === "ARBITRATION")?.on).toBe(true);
  expect(decodeKinds(0).every((f) => !f.on)).toBe(true);
});
