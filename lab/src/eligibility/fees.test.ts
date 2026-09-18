import { describe, expect, it } from "vitest";
import { ZERO_ADDRESS } from "../deal/types.ts";
import { emptyPolicy, type LivePolicy } from "../slots/types.ts";
import { projectFees } from "./fees.ts";

const mod = "0x00000000000000000000000000000000000000a1";
const feeRecipient = "0x0000000000000000000000000000000000000FEE";

/// Only the fee fields matter to `projectFees`; the rest of the policy is inert here.
function policy(completionFee: bigint | null, verifyFee: bigint | null, activationFee = 0n): LivePolicy {
  const p = emptyPolicy();
  if (completionFee !== null || activationFee !== 0n) {
    p.reputation = {
      address: mod,
      passport: ZERO_ADDRESS,
      feeRecipient,
      activationFee,
      completionFee: completionFee ?? 0n,
      contestBps: 0n,
      contestFloor: 0n,
      operator: ZERO_ADDRESS,
    };
  }
  if (verifyFee !== null) {
    p.zk = { address: mod, verifier: mod, feeRecipient, verifyFee, operator: ZERO_ADDRESS };
  }
  return p;
}

describe("projectFees", () => {
  it("projects nothing when no fee-bearing package is bound", () => {
    expect(projectFees(1_000n, null)).toEqual({
      stop: null,
      netToProvider: null,
      activationFee: 0n,
      contestFee: 0n,
    });
    expect(projectFees(1_000n, emptyPolicy())).toEqual({
      stop: null,
      netToProvider: null,
      activationFee: 0n,
      contestFee: 0n,
    });
    expect(projectFees(1_000n, policy(null, null))).toEqual({
      stop: null,
      netToProvider: null,
      activationFee: 0n,
      contestFee: 0n,
    });
  });

  it("a zero completion fee leaves the whole principal", () => {
    expect(projectFees(1_000n, policy(0n, null)).netToProvider).toBe(1_000n);
  });

  it("subtracts a completion fee that fits", () => {
    expect(projectFees(1_000n, policy(1n, null)).netToProvider).toBe(999n);
    expect(projectFees(1_000n, policy(250n, null)).netToProvider).toBe(750n);
  });

  /// The boundary that the invariant suite used to misread: one unit below the principal the fee still fits,
  /// so it is collected and the winner nets a single unit.
  it("a fee one below the principal leaves the winner one unit", () => {
    expect(projectFees(1_000n, policy(999n, null)).netToProvider).toBe(1n);
  });

  /// `_invoice` skips at `fee >= left`, so a fee equal to the principal collects nothing at all. The client
  /// stops instead of signing a packageId whose declared fee can never be charged.
  it("stops when the completion fee equals the principal", () => {
    const { stop, netToProvider } = projectFees(1_000n, policy(1_000n, null));
    expect(netToProvider).toBeNull();
    expect(stop?.step).toBe("completionFee < principal");
    expect(stop?.eval.enabled).toBe(false);
    expect(stop?.eval.reasonKind).toBe("ui-policy");
  });

  it("stops when the completion fee exceeds the principal", () => {
    expect(projectFees(1_000n, policy(1_001n, null)).stop?.step).toBe("completionFee < principal");
    expect(projectFees(1_000n, policy(1n << 128n, null)).stop?.step).toBe("completionFee < principal");
  });

  it("stops when the ZK verify fee reaches the principal", () => {
    expect(projectFees(1_000n, policy(null, 1_000n)).stop?.step).toBe("verifyFee < principal");
    expect(projectFees(1_000n, policy(null, 1_001n)).stop?.step).toBe("verifyFee < principal");
  });

  it("reports the completion fee first when both are degenerate", () => {
    expect(projectFees(1_000n, policy(1_000n, 5_000n)).stop?.step).toBe("completionFee < principal");
  });

  it("stacks verify then completion, in the order the kernel invoices them", () => {
    expect(projectFees(1_000n, policy(50n, 100n)).netToProvider).toBe(850n);
  });

  /// The completion fee is measured against the leftover after the verify fee, not against the principal.
  it("measures the completion fee against the leftover", () => {
    // verify 100 -> leftover 900; completion 900 does not fit, so it is skipped and the winner keeps 900.
    expect(projectFees(1_000n, policy(900n, 100n)).netToProvider).toBe(900n);
    // completion 899 does fit, leaving one unit.
    expect(projectFees(1_000n, policy(899n, 100n)).netToProvider).toBe(1n);
  });

  it("still stops when the completion fee alone is under the principal but the verify fee is not", () => {
    expect(projectFees(1_000n, policy(10n, 1_000n)).stop?.step).toBe("verifyFee < principal");
  });

  /// The activation fee is the Holder's extra outlay, pulled by `Packages.engage` *before* the principal
  /// pull, so it belongs in the allowance check rather than in the Provider's net. It is reported even when
  /// the projection stops, and even with no completion fee at all.
  describe("activationFee", () => {
    it("is zero without a reputation package", () => {
      expect(projectFees(1_000n, null).activationFee).toBe(0n);
      expect(projectFees(1_000n, policy(null, 10n)).activationFee).toBe(0n);
    });

    it("is reported alongside the Provider net", () => {
      const f = projectFees(1_000n, policy(50n, null, 100n));
      expect(f.activationFee).toBe(100n);
      expect(f.netToProvider).toBe(950n);
    });

    it("is reported even when the projection stops on a degenerate completion fee", () => {
      const f = projectFees(1_000n, policy(1_000n, null, 100n));
      expect(f.stop).not.toBeNull();
      expect(f.activationFee).toBe(100n);
    });

    it("is not capped by the principal: the Holder funds it on top", () => {
      expect(projectFees(1_000n, policy(0n, null, 5_000n)).activationFee).toBe(5_000n);
    });
  });

  describe("contestFee", () => {
    it("is zero without a reputation package", () => {
      expect(projectFees(1_000n, null).contestFee).toBe(0n);
      expect(projectFees(1_000n, policy(null, 10n)).contestFee).toBe(0n);
    });

    it("does not change the Provider net: the opener pays it", () => {
      const p = emptyPolicy();
      p.reputation = {
        address: mod,
        passport: ZERO_ADDRESS,
        feeRecipient,
        activationFee: 0n,
        completionFee: 50n,
        contestBps: 0n,
        contestFloor: 100n,
        operator: ZERO_ADDRESS,
      };
      const f = projectFees(1_000n, p);
      expect(f.contestFee).toBe(100n);
      expect(f.netToProvider).toBe(950n);
    });

    it("is max(principal * bps / 10000, floor)", () => {
      const p = emptyPolicy();
      p.reputation = {
        address: mod,
        passport: ZERO_ADDRESS,
        feeRecipient,
        activationFee: 0n,
        completionFee: 0n,
        contestBps: 100n,
        contestFloor: 10n,
        operator: ZERO_ADDRESS,
      };
      expect(projectFees(500n, p).contestFee).toBe(10n);
      expect(projectFees(2_000n, p).contestFee).toBe(20n);
    });
  });
});
