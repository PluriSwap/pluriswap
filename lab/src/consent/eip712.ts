import {
  concat,
  encodeAbiParameters,
  hashTypedData,
  keccak256,
  toHex,
  type Address,
  type Hex,
  type TypedData,
} from "viem";
import { EIP712_NAME, EIP712_VERSION, type HexAddress, type HexBytes32 } from "../addressbook/types.ts";
import type { DealTerms } from "../deal/types.ts";

export const DEAL_TERMS_TYPE =
  "DealTerms(address holder,address controller,address provider,address token,uint256 principal,uint256 fiatDuration,uint256 releaseDuration,uint256 disputeDuration,uint256 arbitrationDuration,bytes32[] packageIds)";

export const DEAL_TERMS_TYPEHASH = keccak256(toHex(DEAL_TERMS_TYPE));

export const eip712Types = {
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
  ProviderAgreement: [
    { name: "terms", type: "DealTerms" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
  ControllerAcceptance: [
    { name: "terms", type: "DealTerms" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
} as const satisfies TypedData;

export const dualSignTypes = {
  MutualCancel: [
    { name: "dealId", type: "bytes32" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
  CoSignedRelease: [
    { name: "dealId", type: "bytes32" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
  MutualSplit: [
    { name: "dealId", type: "bytes32" },
    { name: "providerBps", type: "uint16" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
} as const satisfies TypedData;

export type Envelope = {
  terms: DealTerms;
  nonce: bigint;
  deadline: bigint;
};

export function eip712Domain(chainId: number, escrow: HexAddress) {
  return {
    name: EIP712_NAME,
    version: EIP712_VERSION,
    chainId,
    verifyingContract: escrow as Address,
  };
}

/** Terms.hashTerms: hashStruct(DealTerms), not a loose abi.encode of the struct. */
export function hashTerms(t: DealTerms): HexBytes32 {
  const packedIds =
    t.packageIds.length === 0 ? keccak256(new Uint8Array()) : keccak256(concat(t.packageIds as Hex[]));
  return keccak256(
    encodeAbiParameters(
      [
        { type: "bytes32" },
        { type: "address" },
        { type: "address" },
        { type: "address" },
        { type: "address" },
        { type: "uint256" },
        { type: "uint256" },
        { type: "uint256" },
        { type: "uint256" },
        { type: "uint256" },
        { type: "bytes32" },
      ],
      [
        DEAL_TERMS_TYPEHASH,
        t.holder,
        t.controller,
        t.provider,
        t.token,
        t.principal,
        t.fiatDuration,
        t.releaseDuration,
        t.disputeDuration,
        t.arbitrationDuration,
        packedIds,
      ],
    ),
  ) as HexBytes32;
}

export function hashEnvelope(
  primaryType: "HolderAuthorization" | "ProviderAgreement" | "ControllerAcceptance",
  chainId: number,
  escrow: HexAddress,
  env: Envelope,
): Hex {
  return hashTypedData({
    domain: eip712Domain(chainId, escrow),
    types: eip712Types,
    primaryType,
    message: {
      terms: {
        holder: env.terms.holder,
        controller: env.terms.controller,
        provider: env.terms.provider,
        token: env.terms.token,
        principal: env.terms.principal,
        fiatDuration: env.terms.fiatDuration,
        releaseDuration: env.terms.releaseDuration,
        disputeDuration: env.terms.disputeDuration,
        arbitrationDuration: env.terms.arbitrationDuration,
        packageIds: env.terms.packageIds,
      },
      nonce: env.nonce,
      deadline: env.deadline,
    },
  });
}

export function hashDualSign(
  primaryType: "MutualCancel" | "CoSignedRelease" | "MutualSplit",
  chainId: number,
  escrow: HexAddress,
  message: {
    dealId: Hex;
    nonce: bigint;
    deadline: bigint;
    providerBps?: number;
  },
): Hex {
  if (primaryType === "MutualSplit") {
    return hashTypedData({
      domain: eip712Domain(chainId, escrow),
      types: dualSignTypes,
      primaryType: "MutualSplit",
      message: {
        dealId: message.dealId,
        providerBps: message.providerBps ?? 0,
        nonce: message.nonce,
        deadline: message.deadline,
      },
    });
  }
  return hashTypedData({
    domain: eip712Domain(chainId, escrow),
    types: dualSignTypes,
    primaryType,
    message: {
      dealId: message.dealId,
      nonce: message.nonce,
      deadline: message.deadline,
    },
  });
}

/** Consent.dealId: keccak256(abi.encode(domainSeparator, termsHash, hNonce, pNonce, holder==controller ? 0 : cNonce)) */
export function computeDealId(
  domainSeparator: Hex,
  terms: DealTerms,
  holderNonce: bigint,
  providerNonce: bigint,
  controllerNonce: bigint,
): HexBytes32 {
  const cNonce = terms.holder.toLowerCase() === terms.controller.toLowerCase() ? 0n : controllerNonce;
  return keccak256(
    encodeAbiParameters(
      [
        { type: "bytes32" },
        { type: "bytes32" },
        { type: "uint256" },
        { type: "uint256" },
        { type: "uint256" },
      ],
      [domainSeparator, hashTerms(terms), holderNonce, providerNonce, cNonce],
    ),
  ) as HexBytes32;
}
