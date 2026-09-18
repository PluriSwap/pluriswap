import { getAddress } from "viem";
import { describe, expect, it } from "vitest";
import { ZERO_ADDRESS, type PackageMods } from "../deal/types.ts";
import { R } from "../eligibility/errors.ts";
import { arbitrationId, bondsId, passportId, zkId } from "../packageid/hash.ts";
import { firstResolveRevert } from "./resolve.ts";
import { ZERO_MODS, type LivePolicy } from "./types.ts";

const pass = getAddress("0x00000000000000000000000000000000000000a1");
const zkMod = getAddress("0x00000000000000000000000000000000000000a2");
const ver = getAddress("0x00000000000000000000000000000000000000a3");
const fee = getAddress("0x0000000000000000000000000000000000000FEE");
const court = getAddress("0x00000000000000000000000000000000000000a4");
const trib = getAddress("0x00000000000000000000000000000000000000a5");

const pid = passportId(pass);
const zid = zkId(zkMod, ver, fee, 1n);
const aid = arbitrationId(court, trib, 9n);

function policy(over: Partial<LivePolicy> = {}): LivePolicy {
  return {
    passport: { address: pass },
    reputation: null,
    bonds: null,
    zk: { address: zkMod, verifier: ver, feeRecipient: fee, verifyFee: 1n, operator: ZERO_ADDRESS },
    court: { address: court, partner: trib, key: 9n, operator: ZERO_ADDRESS, kernel: null, extraData: null },
    identifyHolder: null,
    identifyProvider: null,
    identifyError: null,
    ...over,
  };
}

function mods(over: Partial<PackageMods> = {}): PackageMods {
  return { ...ZERO_MODS, ...over };
}

describe("firstResolveRevert", () => {
  it("Core-only empty ids and empty mods is ok", () => {
    expect(firstResolveRevert([], ZERO_MODS, policy()).enabled).toBe(true);
  });

  it("UnknownPackage before IncompatiblePackages when a slot id is missing", () => {
    const ev = firstResolveRevert([zid], mods({ zk: zkMod, court }), policy());
    expect(ev.reason).toBe(R.UnknownPackage);
  });

  it("IncompatiblePackages when both ZK and ARB ids are signed", () => {
    const ids = zid.toLowerCase() < aid.toLowerCase() ? [zid, aid] : [aid, zid];
    const ev = firstResolveRevert(ids, mods({ zk: zkMod, court }), policy());
    expect(ev.reason).toBe(R.IncompatiblePackages);
  });

  it("PackageRequired when bonds has no passport+rep", () => {
    const vault = pass;
    const sink = fee;
    const bid = bondsId(vault, sink);
    const ev = firstResolveRevert(
      [bid],
      mods({ bonds: vault }),
      policy({
        bonds: { address: vault, passport: ZERO_ADDRESS, sink, operator: ZERO_ADDRESS },
      }),
    );
    expect(ev.reason).toBe(R.PackageRequired);
  });

  it("PeerMismatch before asking the id", () => {
    const other = getAddress("0x00000000000000000000000000000000000000bb");
    const ev = firstResolveRevert([pid], mods({ passport: pass, reputation: pass }), policy({
      reputation: {
        address: pass,
        passport: other,
        feeRecipient: fee,
        activationFee: 0n,
        completionFee: 0n,
        contestBps: 0n,
        contestFloor: 0n,
        operator: ZERO_ADDRESS,
      },
    }));
    expect(ev.reason).toBe(R.PeerMismatch);
  });
});
