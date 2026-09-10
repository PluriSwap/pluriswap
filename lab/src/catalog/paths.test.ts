import { describe, expect, it } from "vitest";
import { PATHS, pathById } from "./paths.ts";

describe("path catalog durations", () => {
  it("CASE-CORE-11 never clones zeros into releaseDuration", () => {
    const p = pathById("CASE-CORE-11");
    expect(p?.releaseDuration).toBe("100");
    expect(p?.fiatDuration).toBe("3600");
    expect(p?.disputeDuration).toBe("7200");
  });

  it("CASE-CORE-07 uses releaseDuration 0 so claim is due and openDisputed is TooLate", () => {
    const p = pathById("CASE-CORE-07");
    expect(p?.releaseDuration).toBe("0");
    expect(p?.fiatDuration).toBe("3600");
  });

  it("CASE-CORE-04 uses fiatDuration 0; PATH-ARB-MOCK does not put 1 days in disputeDuration", () => {
    expect(pathById("CASE-CORE-04")?.fiatDuration).toBe("0");
    const arb = pathById("PATH-ARB-MOCK");
    expect(arb?.disputeDuration).toBe("7200");
    expect(arb?.arbitrationDuration).toBe(String(86_400));
  });

  it("lists CASE-CORE-01 through 17 plus packaged paths", () => {
    const ids = PATHS.map((p) => p.id);
    expect(ids).toContain("CASE-CORE-01-P2P");
    expect(ids).toContain("CASE-CORE-17");
    expect(ids).toContain("PATH-TRIO");
    expect(ids).toContain("PATH-POOL-HOLDER");
    expect(ids).toContain("PATH-RAMP-TAXI");
  });
});
