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
      ca: env,
      holderSig: null,
      providerSig: null,
      controllerSig: null,
      chainId: 31337,
      escrow,
      now: 1n,
      usedHolder: false,
      usedProvider: false,
      usedController: false,
      allowance: 1_000_000n,
      dealStatus: 0,
      coreActivate: true,
      distinctController: true,
    });
    expect(steps[0]?.eval.reason).toBe(R.HolderEqualsProvider);
  });

  it("rejects distinct controller when the flag is off", async () => {
    const t = terms({ controller: ZERO_ADDRESS });
    const env = { terms: t, nonce: 1n, deadline: 9n };
    const steps = await preflightActivateCore({
      terms: t,
      ha: env,
      pa: env,
      ca: env,
      holderSig: null,
      providerSig: null,
      controllerSig: null,
      chainId: 31337,
      escrow,
      now: 1n,
      usedHolder: false,
      usedProvider: false,
      usedController: false,
      allowance: 1n,
      dealStatus: 0,
      coreActivate: true,
      distinctController: false,
    });
    expect(steps[0]?.eval.reason).toBe("distinctController off");
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
      ca: env,
      holderSig: null,
      providerSig: null,
      controllerSig: null,
      chainId: 31337,
      escrow,
      now: 1n,
      usedHolder: false,
      usedProvider: false,
      usedController: false,
      allowance: 1n,
      dealStatus: 0,
      coreActivate: true,
      distinctController: true,
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
      ca: env,
      holderSig,
      providerSig: null,
      controllerSig: null,
      chainId: 31337,
      escrow,
      now: 1n,
      usedHolder: false,
      usedProvider: false,
      usedController: false,
      allowance: 1_000_000n,
      dealStatus: 0,
      coreActivate: true,
      distinctController: true,
    });
    const last = steps[steps.length - 1];
    expect(steps.find((s) => s.step === "InvalidHolderSignature")?.eval.enabled).toBe(true);
    expect(last?.step).toBe("InvalidProviderSignature");
  });

  it("accepts a hashed ControllerAcceptance when holder != controller", async () => {
    const controllerPk = "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a";
    const controller = privateKeyToAccount(controllerPk);
    const t = terms({ controller: controller.address });
    const env = { terms: t, nonce: 1n, deadline: 9_999_999_999n };
    const ca = { terms: t, nonce: 3n, deadline: env.deadline };
    const holderSig = await holder.signTypedData({
      domain: { name: "PluriSwap", version: "1", chainId: 31337, verifyingContract: escrow },
      types: eip712Types,
      primaryType: "HolderAuthorization",
      message: { terms: t, nonce: env.nonce, deadline: env.deadline },
    });
    const providerPk = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d";
    const providerAccount = privateKeyToAccount(providerPk);
    const providerSig = await providerAccount.signTypedData({
      domain: { name: "PluriSwap", version: "1", chainId: 31337, verifyingContract: escrow },
      types: eip712Types,
      primaryType: "ProviderAgreement",
      message: { terms: t, nonce: env.nonce, deadline: env.deadline },
    });
    const controllerSig = await controller.signTypedData({
      domain: { name: "PluriSwap", version: "1", chainId: 31337, verifyingContract: escrow },
      types: eip712Types,
      primaryType: "ControllerAcceptance",
      message: { terms: t, nonce: ca.nonce, deadline: ca.deadline },
    });
    const steps = await preflightActivateCore({
      terms: t,
      ha: env,
      pa: env,
      ca,
      holderSig,
      providerSig,
      controllerSig,
      chainId: 31337,
      escrow,
      now: 1n,
      usedHolder: false,
      usedProvider: false,
      usedController: false,
      allowance: 1_000_000n,
      dealStatus: 0,
      coreActivate: true,
      distinctController: true,
    });
    expect(steps.find((s) => s.step === "InvalidControllerSignature")?.eval.enabled).toBe(true);
    expect(steps[steps.length - 1]?.eval.enabled).toBe(true);
  });
});
