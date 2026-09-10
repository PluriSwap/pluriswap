import { getAddress, keccak256, toHex } from "viem";
import { describe, expect, it } from "vitest";
import {
  KIND,
  arbitrationId,
  bondsId,
  klerosId,
  passportId,
  reputationId,
  sortUniqueIds,
  zkId,
} from "./hash.ts";

const a = getAddress("0xCAD1300DbF23D65B97DD556e8bffC0873D15387a");
const b = getAddress("0xd103a26151ed3B739cCA67c1d2b4B9b6fae34fF0");
const c = getAddress("0x0000000000000000000000000000000000000FEE");

describe("PackageId kinds", () => {
  it("hashes the same kind strings as PackageId.sol", () => {
    expect(KIND.PASSPORT).toBe(keccak256(toHex("PluriSwap.Package.PASSPORT")));
    expect(KIND.REPUTATION).toBe(keccak256(toHex("PluriSwap.Package.REPUTATION")));
    expect(KIND.BONDS).toBe(keccak256(toHex("PluriSwap.Package.BONDS")));
    expect(KIND.ZK).toBe(keccak256(toHex("PluriSwap.Package.ZK")));
    expect(KIND.ARBITRATION).toBe(keccak256(toHex("PluriSwap.Package.ARBITRATION")));
  });

  it("passport id changes with the adapter", () => {
    expect(passportId(a)).not.toBe(passportId(b));
    expect(passportId(a)).toMatch(/^0x[0-9a-f]{64}$/);
  });

  it("reputation id binds fee schedule", () => {
    const x = reputationId(b, c, 1n, 2n);
    expect(reputationId(b, c, 1n, 3n)).not.toBe(x);
    expect(reputationId(b, a, 1n, 2n)).not.toBe(x);
  });

  it("bonds id includes BOND_LOCK_BPS = 1000", () => {
    expect(bondsId(a, c)).not.toBe(bondsId(b, c));
  });

  it("kleros is arbitration with keccak(extraData) as the third word", () => {
    const extra = "0x1234" as const;
    expect(klerosId(a, b, extra)).toBe(arbitrationId(a, b, BigInt(keccak256(extra))));
  });

  it("zk id binds verifier and fee", () => {
    expect(zkId(a, b, c, 5n)).not.toBe(zkId(a, b, c, 6n));
  });

  it("sortUniqueIds is ascending unique", () => {
    const x = passportId(a);
    const y = passportId(b);
    const [lo, hi] = x.toLowerCase() < y.toLowerCase() ? [x, y] : [y, x];
    expect(sortUniqueIds([hi, lo, hi])).toEqual([lo, hi]);
  });
});
