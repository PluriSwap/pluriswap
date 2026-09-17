import { expect, it } from "vitest";
import { decodeKinds } from "./kinds.ts";
import { POST, Status, isTerminalStatus, postPendingChips } from "./types.ts";

it("decodes the kernel bitmap 1/2/4/8/16", () => {
  const flags = decodeKinds(1 | 2 | 4);
  expect(flags.filter((f) => f.on).map((f) => f.name)).toEqual(["PASSPORT", "REPUTATION", "BONDS"]);
  expect(decodeKinds(8).find((f) => f.name === "ZK")?.on).toBe(true);
  expect(decodeKinds(16).find((f) => f.name === "ARBITRATION")?.on).toBe(true);
  expect(decodeKinds(0).every((f) => !f.on)).toBe(true);
});

it("names postPending bits the way the LAB_UI chips do", () => {
  expect(postPendingChips(0)).toEqual([]);
  expect(postPendingChips(POST.NOTIFY_H | POST.NOTIFY_P | POST.BOND_A | POST.BOND_B)).toEqual([
    "notify-H",
    "notify-P",
    "bond-A",
    "bond-B",
  ]);
  expect(isTerminalStatus(Status.FUNDED)).toBe(false);
  expect(isTerminalStatus(Status.STALEMATE)).toBe(true);
});
