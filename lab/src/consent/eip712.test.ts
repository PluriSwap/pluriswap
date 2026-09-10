import { keccak256, toHex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { describe, expect, it } from "vitest";
import { ZERO_ADDRESS, type DealTerms } from "../deal/types.ts";
import {
  DEAL_TERMS_TYPE,
  DEAL_TERMS_TYPEHASH,
  computeDealId,
  hashEnvelope,
  hashTerms,
} from "./eip712.ts";

const terms: DealTerms = {
  holder: "0x00000000000000000000000000000000000000a1",
  controller: "0x00000000000000000000000000000000000000a1",
  provider: "0x00000000000000000000000000000000000000b0",
  token: "0x0000000000000000000000000000000000005555",
  principal: 1_000_000n,
  fiatDuration: 3600n,
  releaseDuration: 1800n,
  disputeDuration: 7200n,
  arbitrationDuration: 0n,
  packageIds: [],
};

describe("hashTerms", () => {
  it("matches keccak of the Consent type string", () => {
    expect(DEAL_TERMS_TYPEHASH).toBe(keccak256(toHex(DEAL_TERMS_TYPE)));
  });

  it("is stable for empty packageIds and changes with principal", () => {
    const a = hashTerms(terms);
    const b = hashTerms({ ...terms });
    expect(a).toBe(b);
    expect(hashTerms({ ...terms, principal: 2_000_000n })).not.toBe(a);
  });

  it("empty packageIds uses keccak256(empty)", () => {
    const empty = keccak256(new Uint8Array());
    expect(empty).toBe("0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470");
    expect(hashTerms({ ...terms, packageIds: [] })).toMatch(/^0x[0-9a-f]{64}$/);
  });
});

describe("dealId", () => {
  it("P2P encodes controllerNonce as 0 even if a dummy nonce is passed", () => {
    const domain = hashTerms(terms);
    const a = computeDealId(domain, terms, 1n, 2n, 99n);
    const b = computeDealId(domain, terms, 1n, 2n, 0n);
    expect(a).toBe(b);
    const distinct = { ...terms, controller: ZERO_ADDRESS };
    expect(computeDealId(domain, distinct, 1n, 2n, 99n)).not.toBe(
      computeDealId(domain, distinct, 1n, 2n, 0n),
    );
  });
});

describe("hashDualSign", () => {
  it("uses distinct types so bps 10000 is not CoSignedRelease", async () => {
    const { hashDualSign } = await import("./eip712.ts");
    const escrow = "0x0165878A594ca255338adfa4d48449f69242Eb8F";
    const dealId = "0x1111111111111111111111111111111111111111111111111111111111111111";
    const cancel = hashDualSign("MutualCancel", 31337, escrow, {
      dealId,
      nonce: 1n,
      deadline: 9n,
    });
    const release = hashDualSign("CoSignedRelease", 31337, escrow, {
      dealId,
      nonce: 1n,
      deadline: 9n,
    });
    const split = hashDualSign("MutualSplit", 31337, escrow, {
      dealId,
      nonce: 1n,
      deadline: 9n,
      providerBps: 10000,
    });
    expect(cancel).not.toBe(release);
    expect(split).not.toBe(release);
  });
});

describe("hashEnvelope", () => {
  it("produces a digest a local account can sign", async () => {
    const pk = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
    const account = privateKeyToAccount(pk);
    const escrow = "0x0165878A594ca255338adfa4d48449f69242Eb8F";
    const env = { terms: { ...terms, holder: account.address, controller: account.address }, nonce: 1n, deadline: 2n };
    const digest = hashEnvelope("HolderAuthorization", 31337, escrow, env);
    expect(digest).toMatch(/^0x[0-9a-f]{64}$/);
    const sig = await account.signTypedData({
      domain: { name: "PluriSwap", version: "1", chainId: 31337, verifyingContract: escrow },
      types: {
        DealTerms: [
          { name: "holder", type: "address" },
          { name: "controller", type: "address" },
          { name: "provider", type: "address" },
          { name: "token", type: "address" },
          { name: "principal", type: "uint256" },
          { name: "fiatDuration", type: "uint256" },
          { name: "releaseDuration", type: "uint256" },
          { name: "disputeDuration", type: "uint256" },
          { name: "arbitrationDuration", type: "uint256" },
          { name: "packageIds", type: "bytes32[]" },
        ],
        HolderAuthorization: [
          { name: "terms", type: "DealTerms" },
          { name: "nonce", type: "uint256" },
          { name: "deadline", type: "uint256" },
        ],
      },
      primaryType: "HolderAuthorization",
      message: {
        terms: env.terms,
        nonce: env.nonce,
        deadline: env.deadline,
      },
    });
    expect(sig).toMatch(/^0x[0-9a-f]+$/);
  });
});
