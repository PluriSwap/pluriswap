import { describe, expect, it } from "vitest";
import { ZERO_ADDRESS, ZERO_BYTES32, Status, PKG, type DealSnapshot } from "../deal/types.ts";
import { R } from "./errors.ts";
import { matrixForDeal } from "./matrix.ts";
import {
  evalClaim,
  evalMarkFiat,
  evalOpenDisputed,
  evalRelease,
  evalTimeoutFiat,
} from "./predicates.ts";
import { firstResolveRevert } from "./resolve.ts";
import { firstTermsRevert } from "./terms.ts";

const provider = "0x00000000000000000000000000000000000000b0";
const holder = "0x00000000000000000000000000000000000000a1";
const controller = holder;

function deal(over: Partial<DealSnapshot> & { status: number }): DealSnapshot {
  return {
    dealId: ZERO_BYTES32,
    terms: {
      holder,
      controller,
      provider,
      token: ZERO_ADDRESS,
      principal: 1_000_000n,
      fiatDuration: 3600n,
      releaseDuration: 1800n,
      disputeDuration: 7200n,
      arbitrationDuration: 0n,
      packageIds: [],
    },
    clocks: {
      activatedAt: 100n,
      fiatSentAt: 0n,
      disputedAt: 0n,
      arbitrationOpenedAt: 0n,
    },
    subjects: { holderSubject: ZERO_BYTES32, providerSubject: ZERO_BYTES32 },
    modules: {
      passport: ZERO_ADDRESS,
      reputation: ZERO_ADDRESS,
      bonds: ZERO_ADDRESS,
      zk: ZERO_ADDRESS,
      court: ZERO_ADDRESS,
    },
    kinds: 0,
    settlement: { status: over.status, holderAmt: 0n, providerAmt: 0n },
    blockTimestamp: 100n,
    blockNumber: 1n,
    ...over,
  };
}

describe("terms first revert", () => {
  it("HolderEqualsProvider before ZeroPrincipal and UnsortedPackageIds", () => {
    const t = deal({ status: Status.NONE }).terms;
    t.provider = holder;
    t.principal = 0n;
    t.packageIds = [ZERO_BYTES32, ZERO_BYTES32];
    expect(firstTermsRevert(t).reason).toBe(R.HolderEqualsProvider);
  });

  it("UnsortedPackageIds before any TermsMismatch would run", () => {
    const t = deal({ status: Status.NONE }).terms;
    t.packageIds = [
      "0x0000000000000000000000000000000000000000000000000000000000000002",
      "0x0000000000000000000000000000000000000000000000000000000000000001",
    ];
    expect(firstTermsRevert(t).reason).toBe(R.UnsortedPackageIds);
  });
});

describe("_resolve order", () => {
  it("UnknownPackage before IncompatiblePackages when a slot id is missing", () => {
    const eval_ = firstResolveRevert(["0x01"], [
      { kind: "zk", bit: PKG.ZK, address: "0xzk", id: "0x01", peerOk: true },
      { kind: "court", bit: PKG.ARB, address: "0xcourt", id: "0x02", peerOk: true },
    ]);
    expect(eval_.reason).toBe(R.UnknownPackage);
  });

  it("IncompatiblePackages when both ZK and ARB ids are claimed", () => {
    const eval_ = firstResolveRevert(["0x01", "0x02"], [
      { kind: "zk", bit: PKG.ZK, address: "0xzk", id: "0x01", peerOk: true },
      { kind: "court", bit: PKG.ARB, address: "0xcourt", id: "0x02", peerOk: true },
    ]);
    expect(eval_.reason).toBe(R.IncompatiblePackages);
  });

  it("PeerMismatch before UnknownPackage on reputation", () => {
    const eval_ = firstResolveRevert(["0xaa", "0x99"], [
      { kind: "passport", bit: PKG.PASSPORT, address: "0xp", id: "0xaa", peerOk: true },
      { kind: "reputation", bit: PKG.REP, address: "0xr", id: "0x99", peerOk: false },
    ]);
    expect(eval_.reason).toBe(R.PeerMismatch);
  });
});

describe("Deal matrix (CASE-CORE)", () => {
  it("FUNDED + Provider → markFiat ENABLED; Holder → Unauthorized", () => {
    const d = deal({ status: Status.FUNDED });
    expect(evalMarkFiat({ deal: d, sender: provider, credit: null, ruling: null, dualSign: null }).enabled).toBe(
      true,
    );
    expect(evalMarkFiat({ deal: d, sender: holder, credit: null, ruling: null, dualSign: null }).reason).toBe(
      R.Unauthorized,
    );
  });

  it("FUNDED ZK → markFiat EdgeOff, timeoutFiat still on", () => {
    const d = deal({
      status: Status.FUNDED,
      kinds: PKG.ZK,
      terms: { ...deal({ status: Status.FUNDED }).terms, fiatDuration: 0n },
    });
    const ctx = { deal: d, sender: provider, credit: null, ruling: null, dualSign: null };
    expect(evalMarkFiat(ctx).reason).toBe(R.EdgeOff);
    expect(evalTimeoutFiat(ctx).enabled).toBe(true);
  });

  it("FIAT_SENT releaseDuration=0 → openDisputed TooLate, claim due", () => {
    const d = deal({
      status: Status.FIAT_SENT,
      terms: {
        ...deal({ status: Status.FIAT_SENT }).terms,
        releaseDuration: 0n,
      },
      clocks: {
        activatedAt: 10n,
        fiatSentAt: 50n,
        disputedAt: 0n,
        arbitrationOpenedAt: 0n,
      },
      blockTimestamp: 50n,
    });
    const ctx = { deal: d, sender: controller, credit: null, ruling: null, dualSign: null };
    expect(evalOpenDisputed(ctx).reason).toBe(R.TooLate);
    expect(evalClaim(ctx).enabled).toBe(true);
  });

  it("CASE-CORE-16: release and claim from DISPUTED are WrongStatus and stay visible", () => {
    const d = deal({ status: Status.DISPUTED });
    const rows = matrixForDeal(d, controller);
    const verbs = rows.map((r) => r.verb);
    expect(verbs).toContain("release");
    expect(verbs).toContain("claim");
    expect(rows.find((r) => r.verb === "release")?.eval.reason).toBe(R.WrongStatus);
    expect(rows.find((r) => r.verb === "claim")?.eval.reason).toBe(R.WrongStatus);
  });

  it("CASE-CORE-17: terminal lists every kernel row as WrongStatus where applicable", () => {
    const d = deal({ status: Status.RELEASED });
    const rows = matrixForDeal(d, provider);
    expect(rows.length).toBeGreaterThanOrEqual(17);
    expect(rows.find((r) => r.verb === "markFiat")?.eval.reason).toBe(R.WrongStatus);
    expect(rows.find((r) => r.verb === "mutualCancel")?.eval.reason).toBe(R.DraftEmpty);
    expect(rows.find((r) => r.verb === "activate")?.eval.reason).toBe(R.DealExists);
  });

  it("does not hide illegal kernel rows", () => {
    const rows = matrixForDeal(deal({ status: Status.FUNDED }), holder);
    const verbs = rows.map((r) => r.verb);
    for (const v of [
      "activate",
      "markFiat",
      "cancelByProvider",
      "timeoutFiat",
      "release",
      "claim",
      "openDisputed",
      "forceStalemate",
      "mutualCancel",
      "coSignedRelease",
      "mutualSplit",
      "verifyProof",
      "openCourt",
      "readRuling",
      "forceArbitrationTimeout",
      "withdraw",
      "cancelNonce",
    ]) {
      expect(verbs).toContain(v);
    }
  });

  it("release from FIAT_SENT only for Controller", () => {
    const d = deal({
      status: Status.FIAT_SENT,
      clocks: { activatedAt: 1n, fiatSentAt: 2n, disputedAt: 0n, arbitrationOpenedAt: 0n },
    });
    expect(evalRelease({ deal: d, sender: controller, credit: null, ruling: null, dualSign: null }).enabled).toBe(
      true,
    );
    expect(evalRelease({ deal: d, sender: provider, credit: null, ruling: null, dualSign: null }).reason).toBe(
      R.Unauthorized,
    );
  });
});
