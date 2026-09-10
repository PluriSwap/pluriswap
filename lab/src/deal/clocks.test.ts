import { describe, expect, it } from "vitest";
import { addDuration, deriveClocks, isDue, isStrictlyBefore } from "./clocks.ts";
import { ZERO_ADDRESS, type DealClocks, type DealTerms } from "./types.ts";

const emptyTerms = (dur: Partial<DealTerms> = {}): DealTerms => ({
  holder: ZERO_ADDRESS,
  controller: ZERO_ADDRESS,
  provider: ZERO_ADDRESS,
  token: ZERO_ADDRESS,
  principal: 1n,
  fiatDuration: 0n,
  releaseDuration: 0n,
  disputeDuration: 0n,
  arbitrationDuration: 0n,
  packageIds: [],
  ...dur,
});

describe("addDuration", () => {
  it("does not invent a deadline when origin is 0", () => {
    expect(addDuration(0n, 100n)).toEqual({ deadline: null, overflow: false });
  });

  it("flags uint256 overflow instead of wrapping", () => {
    const max = (1n << 256n) - 1n;
    expect(addDuration(max, 1n)).toEqual({ deadline: null, overflow: true });
  });
});

describe("duration = 0", () => {
  it("requireDue is enabled at origin; requireStrictlyBefore is already TooLate", () => {
    const origin = 1_700_000_000n;
    const { deadline, overflow } = addDuration(origin, 0n);
    expect(deadline).toBe(origin);
    expect(isDue(origin, deadline, overflow)).toBe(true);
    expect(isStrictlyBefore(origin, deadline, overflow)).toBe(false);
    expect(isStrictlyBefore(origin + 1n, deadline, overflow)).toBe(false);
  });

  it("positive duration keeps strictly-before open until the deadline", () => {
    const origin = 100n;
    const { deadline, overflow } = addDuration(origin, 100n);
    expect(isDue(origin, deadline, overflow)).toBe(false);
    expect(isStrictlyBefore(origin, deadline, overflow)).toBe(true);
    expect(isDue(200n, deadline, overflow)).toBe(true);
    expect(isStrictlyBefore(200n, deadline, overflow)).toBe(false);
  });
});

describe("deriveClocks", () => {
  it("marks openDisputed TooLate when releaseDuration is 0 after markFiat", () => {
    const clocks: DealClocks = {
      activatedAt: 10n,
      fiatSentAt: 50n,
      disputedAt: 0n,
      arbitrationOpenedAt: 0n,
    };
    const rows = deriveClocks(clocks, emptyTerms({ releaseDuration: 0n, fiatDuration: 3600n }), 50n);
    const release = rows.find((r) => r.name === "releaseDeadline");
    expect(release?.due).toBe(true);
    expect(release?.strictlyBefore).toBe(false);
    expect(release?.strictlyBeforeVerb).toContain("openDisputed");
    const fiat = rows.find((r) => r.name === "fiatDeadline");
    expect(fiat?.deadline).toBe(3610n);
    const dispute = rows.find((r) => r.name === "disputeDeadline");
    expect(dispute?.deadline).toBeNull();
  });
});
