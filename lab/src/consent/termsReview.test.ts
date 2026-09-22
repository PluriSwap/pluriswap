import { describe, expect, it } from "vitest";
import type { DealTerms } from "../deal/types.ts";
import { CEILING, FLOORS, hasDanger, human, reviewClocks } from "./termsReview.ts";

const CORE = { zk: false, arbitration: false };

// The lab's own catalog paths: short on purpose, so a human can walk a path in one sitting.
const LAB: DealTerms = {
  holder: "0x0000000000000000000000000000000000000001",
  controller: "0x0000000000000000000000000000000000000001",
  provider: "0x0000000000000000000000000000000000000002",
  token: "0x0000000000000000000000000000000000000003",
  principal: 1_000_000n,
  fiatDuration: 3600n,
  releaseDuration: 1800n,
  disputeDuration: 7200n,
  arbitrationDuration: 0n,
  packageIds: [],
};

const SANE: DealTerms = {
  ...LAB,
  fiatDuration: 2n * 3600n,
  releaseDuration: 6n * 3600n,
  disputeDuration: 3n * 86_400n,
  arbitrationDuration: 14n * 86_400n,
};

const at = (t: DealTerms, clock: keyof typeof FLOORS, value: bigint): DealTerms => ({ ...t, [clock]: value });

describe("reviewClocks — the four free wins", () => {
  // Each of these mirrors a Solidity test: the effect is what the kernel actually does, not a reading
  // of the spec.
  it("fiatDuration = 0 lets anyone cancel in the activation block", () => {
    const f = reviewClocks(at(SANE, "fiatDuration", 0n), CORE);
    expect(f).toContainEqual(expect.objectContaining({ clock: "fiatDuration", severity: "danger" }));
  });

  it("releaseDuration = 0 lets the Provider claim without proving anything", () => {
    const f = reviewClocks(at(SANE, "releaseDuration", 0n), CORE);
    const d = f.find((x) => x.clock === "releaseDuration");
    expect(d?.severity).toBe("danger");
    // The second half matters as much as the first: the freeze is gone too.
    expect(d?.detail).toContain("openDisputed");
  });

  it("disputeDuration = 0 makes the Holder's only defence an instant 50/50", () => {
    const f = reviewClocks(at(SANE, "disputeDuration", 0n), CORE);
    expect(f).toContainEqual(expect.objectContaining({ clock: "disputeDuration", severity: "danger" }));
  });

  it("arbitrationDuration = 0 is a danger only once ARBITRATION is selected", () => {
    const terms = at(SANE, "arbitrationDuration", 0n);
    expect(reviewClocks(terms, CORE).some((x) => x.clock === "arbitrationDuration")).toBe(false);
    const f = reviewClocks(terms, { zk: false, arbitration: true });
    expect(f).toContainEqual(expect.objectContaining({ clock: "arbitrationDuration", severity: "danger" }));
  });

  it("flags every zero at once rather than stopping at the first", () => {
    const allZero: DealTerms = { ...SANE, fiatDuration: 0n, releaseDuration: 0n, disputeDuration: 0n };
    expect(reviewClocks(allZero, CORE).filter((x) => x.severity === "danger")).toHaveLength(3);
  });
});

describe("reviewClocks — production floors are a judgement, not the protocol", () => {
  it("leaves sane terms clean", () => {
    expect(reviewClocks(SANE, { zk: false, arbitration: true })).toEqual([]);
  });

  it("warns on the lab's own catalog clocks without calling them dangerous", () => {
    const f = reviewClocks(LAB, CORE);
    expect(f.length).toBeGreaterThan(0);
    expect(hasDanger(f)).toBe(false);
    expect(f.every((x) => x.severity === "warning")).toBe(true);
  });

  it("does not warn exactly at a floor", () => {
    const edge = at(SANE, "releaseDuration", FLOORS.releaseDuration);
    expect(reviewClocks(edge, CORE).some((x) => x.clock === "releaseDuration")).toBe(false);
  });

  it("warns above a year, where the principal outlives the plan", () => {
    const f = reviewClocks(at(SANE, "disputeDuration", CEILING + 1n), CORE);
    expect(f).toContainEqual(
      expect.objectContaining({ clock: "disputeDuration", severity: "warning", effect: expect.stringContaining("año") }),
    );
  });
});

describe("reviewClocks — PAYMENT_PROOF turns most clocks off", () => {
  it("says so once and stops reviewing the inert ones", () => {
    const zeros: DealTerms = { ...SANE, releaseDuration: 0n, disputeDuration: 0n };
    const f = reviewClocks(zeros, { zk: true, arbitration: false });
    expect(hasDanger(f)).toBe(false);
    expect(f).toContainEqual(expect.objectContaining({ severity: "note" }));
  });

  it("still reviews fiatDuration, the one clock a ZK deal runs on", () => {
    const f = reviewClocks(at(SANE, "fiatDuration", 0n), { zk: true, arbitration: false });
    expect(f).toContainEqual(expect.objectContaining({ clock: "fiatDuration", severity: "danger" }));
  });
});

describe("human", () => {
  it("reads as a person would say it", () => {
    expect(human(0n)).toBe("0");
    expect(human(30n)).toBe("30s");
    expect(human(1800n)).toBe("30min");
    expect(human(7200n)).toBe("2h");
    expect(human(86_400n)).toBe("1d");
    expect(human(90_000n)).toBe("1d+");
  });
});
