import { describe, expect, it } from "vitest";
import { ZERO_ADDRESS, ZERO_BYTES32, Status, PKG, type DealSnapshot } from "../deal/types.ts";
import { R } from "./errors.ts";
import { matrixForDeal } from "./matrix.ts";
import {
  evalClaim,
  evalMarkFiat,
  evalOpenCourt,
  evalOpenDisputed,
  evalRelease,
  evalTimeoutFiat,
  evalVerifyProof,
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
    postPending: 0,
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
    expect(evalVerifyProof(ctx).reason).toBe(R.NoProof);
    expect(evalVerifyProof({ ...ctx, proof: "0x1234" }).enabled).toBe(true);
    expect(evalOpenCourt(ctx).reason).toBe(R.PackageNotSelected);
  });

  // Parity with the kernel: `Escrow._requireNotZk` guards exactly four verbs (markFiat, claim,
  // openDisputed, openCourt). A ZK deal is proof-or-timeout (§3.12.1), so the console must not offer
  // any of them. If a fifth guard ever appears in the kernel, this is the test that should have
  // failed first -- the previous coverage only pinned markFiat.
  it("ZK closes every edge the kernel closes, and nothing else", () => {
    const zk = deal({ status: Status.FUNDED, kinds: PKG.ZK | PKG.ARB });
    const funded = { deal: zk, sender: controller, credit: null, ruling: null, dualSign: null };
    expect(evalMarkFiat({ ...funded, sender: provider }).reason).toBe(R.EdgeOff);
    expect(evalOpenCourt(funded).reason).toBe(R.EdgeOff);

    // claim and openDisputed live in FIAT_SENT, which a ZK deal can never reach -- but the console
    // evaluates them off a snapshot, so they have to answer EdgeOff rather than look reachable.
    const sent = deal({ status: Status.FIAT_SENT, kinds: PKG.ZK | PKG.ARB });
    const live = { deal: sent, sender: controller, credit: null, ruling: null, dualSign: null };
    expect(evalClaim(live).reason).toBe(R.EdgeOff);
    expect(evalOpenDisputed(live).reason).toBe(R.EdgeOff);

    // The exits a ZK deal does have stay open: proof, or the fiat clock.
    expect(evalTimeoutFiat(funded).reason).not.toBe(R.EdgeOff);
    expect(evalVerifyProof({ ...funded, proof: "0x1234" }).enabled).toBe(true);
  });

  it("ARB mock without court allowance is InexactPull, not ENABLED", () => {
    const d = deal({
      status: Status.FIAT_SENT,
      kinds: PKG.ARB,
      clocks: {
        activatedAt: 10n,
        fiatSentAt: 20n,
        disputedAt: 0n,
        arbitrationOpenedAt: 0n,
      },
      blockTimestamp: 30n,
    });
    const ctx = {
      deal: d,
      sender: controller,
      credit: null,
      ruling: null,
      dualSign: null,
      courtPref: {
        kind: "mock" as const,
        courtFee: 1n,
        allowance: 0n,
        cost: null,
        msgValue: 0n,
      },
    };
    expect(evalOpenCourt(ctx).reason).toBe(R.InexactPull);
  });

  it("official reputation without opener allowance is InexactPull on openDisputed", () => {
    const d = deal({
      status: Status.FIAT_SENT,
      kinds: PKG.REP,
      clocks: {
        activatedAt: 10n,
        fiatSentAt: 20n,
        disputedAt: 0n,
        arbitrationOpenedAt: 0n,
      },
      blockTimestamp: 30n,
    });
    const ctx = {
      deal: d,
      sender: controller,
      credit: null,
      ruling: null,
      dualSign: null,
      contestPref: { fee: 50_000n, allowance: 0n },
    };
    expect(evalOpenDisputed(ctx).reason).toBe(R.InexactPull);
    expect(evalOpenCourt({ ...ctx, courtPref: null }).reason).toBe(R.PackageNotSelected);
    const arb = deal({
      status: Status.FIAT_SENT,
      kinds: PKG.ARB | PKG.REP,
      clocks: d.clocks,
      blockTimestamp: 30n,
    });
    expect(
      evalOpenCourt({
        ...ctx,
        deal: arb,
        contestPref: { fee: 50_000n, allowance: 0n },
      }).reason,
    ).toBe(R.InexactPull);
    const fromDisputed = deal({
      status: Status.DISPUTED,
      kinds: PKG.ARB | PKG.REP,
      clocks: { ...d.clocks, disputedAt: 20n },
      blockTimestamp: 30n,
    });
    expect(
      evalOpenCourt({
        ...ctx,
        deal: fromDisputed,
        contestPref: { fee: 50_000n, allowance: 0n },
      }).enabled,
    ).toBe(true);
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
    expect(rows.length).toBeGreaterThanOrEqual(18);
    expect(rows.find((r) => r.verb === "markFiat")?.eval.reason).toBe(R.WrongStatus);
    expect(rows.find((r) => r.verb === "mutualCancel")?.eval.reason).toBe(R.DraftEmpty);
    expect(rows.find((r) => r.verb === "activate")?.eval.reason).toBe(R.DealExists);
    expect(rows.find((r) => r.verb === "retryPostTerminal")?.eval.reason).toBe(R.NothingPending);
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
      "forceDisputeTimeout",
      "mutualCancel",
      "coSignedRelease",
      "mutualSplit",
      "verifyProof",
      "openCourt",
      "readRuling",
      "forceArbitrationTimeout",
      "withdraw",
      "cancelNonce",
      "retryPostTerminal",
    ]) {
      expect(verbs).toContain(v);
    }
  });

  it("complete MutualCancel on FUNDED is ENABLED; other dual-sign rows stay draft-empty", () => {
    const d = deal({ status: Status.FUNDED });
    const draft = {
      type: "MutualCancel" as const,
      complete: true,
      dealIdA: d.dealId,
      dealIdB: d.dealId,
      deadlineA: 99n,
      deadlineB: 99n,
      now: 1n,
      usedP: false,
      usedC: false,
      provider,
      controller: holder,
      recoveredP: provider,
      recoveredC: holder,
    };
    const rows = matrixForDeal(d, holder, { dualSign: draft });
    expect(rows.find((r) => r.verb === "mutualCancel")?.eval.enabled).toBe(true);
    expect(rows.find((r) => r.verb === "coSignedRelease")?.eval.reason).toBe(R.DraftEmpty);
    expect(rows.find((r) => r.verb === "mutualSplit")?.eval.reason).toBe(R.DraftEmpty);
  });

  it("retryPostTerminal is ENABLED only on a terminal with leftover bits", () => {
    const live = deal({ status: Status.FUNDED });
    expect(matrixForDeal(live, holder).find((r) => r.verb === "retryPostTerminal")?.eval.reason).toBe(
      R.WrongStatus,
    );
    const clean = deal({ status: Status.RELEASED, postPending: 0 });
    expect(matrixForDeal(clean, holder).find((r) => r.verb === "retryPostTerminal")?.eval.reason).toBe(
      R.NothingPending,
    );
    const owed = deal({ status: Status.STALEMATE, postPending: 0x07 });
    const row = matrixForDeal(owed, holder).find((r) => r.verb === "retryPostTerminal");
    expect(row?.eval.enabled).toBe(true);
    expect(row?.class).toBe("anyone");
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
