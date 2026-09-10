import { privateKeyToAccount } from "viem/accounts";
import { describe, expect, it } from "vitest";
import { ZERO_ADDRESS, type DealTerms } from "../deal/types.ts";
import { R } from "../eligibility/errors.ts";
import { eip712Types } from "./eip712.ts";
import { preflightActivateCore } from "./preflight.ts";

const holderPk = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
const holder = privateKeyToAccount(holderPk);
const provider = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";
const escrow = "0x0165878A594ca255338adfa4d48449f69242Eb8F";

function terms(over: Partial<DealTerms> = {}): DealTerms {
  return {
    holder: holder.address,
    controller: holder.address,
    provider,
    token: "0x5FC8d32690cc91D4c39d9d3abcBD16989F875707",
    principal: 1_000_000n,
    fiatDuration: 3600n,
    releaseDuration: 1800n,
    disputeDuration: 7200n,
    arbitrationDuration: 0n,
    packageIds: [],
    ...over,
  };
}

describe("preflightActivateCore", () => {
  it("stops at HolderEqualsProvider before later checks", async () => {
    const t = terms({ provider: holder.address });
    const env = { terms: t, nonce: 1n, deadline: 9_999_999_999n };
    const steps = await preflightActivateCore({
      terms: t,
      ha: env,
      pa: env,
      holderSig: null,
      providerSig: null,
      chainId: 31337,
      escrow,
      now: 1n,
      usedHolder: false,
      usedProvider: false,
      allowance: 1_000_000n,
      dealStatus: 0,
      coreActivate: true,
    });
    expect(steps[0]?.eval.reason).toBe(R.HolderEqualsProvider);
  });

  it("rejects distinct controller in PR-4", async () => {
    const t = terms({ controller: ZERO_ADDRESS });
    const env = { terms: t, nonce: 1n, deadline: 9n };
    const steps = await preflightActivateCore({
      terms: t,
      ha: env,
      pa: env,
      holderSig: null,
      providerSig: null,
      chainId: 31337,
      escrow,
      now: 1n,
      usedHolder: false,
      usedProvider: false,
      allowance: 1n,
      dealStatus: 0,
      coreActivate: true,
    });
    expect(steps[0]?.eval.reason).toBe("PR-7 ControllerAcceptance");
  });

  it("rejects packageIds in PR-4", async () => {
    const t = terms({
      packageIds: ["0x0000000000000000000000000000000000000000000000000000000000000001"],
    });
    const env = { terms: t, nonce: 1n, deadline: 9n };
    const steps = await preflightActivateCore({
      terms: t,
      ha: env,
      pa: env,
      holderSig: null,
      providerSig: null,
      chainId: 31337,
      escrow,
      now: 1n,
      usedHolder: false,
      usedProvider: false,
      allowance: 1n,
      dealStatus: 0,
      coreActivate: true,
    });
    expect(steps[0]?.eval.reason).toBe("PR-8 PackageMods");
  });

  it("accepts a P2P Core-only envelope with matching holder sig and allowance", async () => {
    const t = terms();
    const env = { terms: t, nonce: 1n, deadline: 9_999_999_999n };
    const holderSig = await holder.signTypedData({
      domain: { name: "PluriSwap", version: "1", chainId: 31337, verifyingContract: escrow },
      types: eip712Types,
      primaryType: "HolderAuthorization",
      message: {
        terms: t,
        nonce: env.nonce,
        deadline: env.deadline,
      },
    });
    const steps = await preflightActivateCore({
      terms: t,
      ha: env,
      pa: env,
      holderSig,
      providerSig: null,
      chainId: 31337,
      escrow,
      now: 1n,
      usedHolder: false,
      usedProvider: false,
      allowance: 1_000_000n,
      dealStatus: 0,
      coreActivate: true,
    });
    const last = steps[steps.length - 1];
    expect(steps.find((s) => s.step === "InvalidHolderSignature")?.eval.enabled).toBe(true);
    expect(last?.step).toBe("InvalidProviderSignature");
  });
});
