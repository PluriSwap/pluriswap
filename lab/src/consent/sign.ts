import type { Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import type { HexAddress } from "../addressbook/types.ts";
import { dualSignTypes, eip712Domain, eip712Types, type Envelope } from "./eip712.ts";

export function accountFromPk(pk: string) {
  const hex = (pk.startsWith("0x") ? pk : `0x${pk}`) as Hex;
  return privateKeyToAccount(hex);
}

export async function signHolderAuthorization(
  pk: string,
  chainId: number,
  escrow: HexAddress,
  env: Envelope,
): Promise<Hex> {
  const account = accountFromPk(pk);
  return account.signTypedData({
    domain: eip712Domain(chainId, escrow),
    types: eip712Types,
    primaryType: "HolderAuthorization",
    message: {
      terms: env.terms,
      nonce: env.nonce,
      deadline: env.deadline,
    },
  });
}

export async function signDualSign(
  pk: string,
  chainId: number,
  escrow: HexAddress,
  primaryType: "MutualCancel" | "CoSignedRelease" | "MutualSplit",
  message: { dealId: Hex; nonce: bigint; deadline: bigint; providerBps?: number },
): Promise<Hex> {
  const account = accountFromPk(pk);
  if (primaryType === "MutualSplit") {
    return account.signTypedData({
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
  return account.signTypedData({
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

export async function signControllerAcceptance(
  pk: string,
  chainId: number,
  escrow: HexAddress,
  env: Envelope,
): Promise<Hex> {
  const account = accountFromPk(pk);
  return account.signTypedData({
    domain: eip712Domain(chainId, escrow),
    types: eip712Types,
    primaryType: "ControllerAcceptance",
    message: {
      terms: env.terms,
      nonce: env.nonce,
      deadline: env.deadline,
    },
  });
}

export async function signProviderAgreement(
  pk: string,
  chainId: number,
  escrow: HexAddress,
  env: Envelope,
): Promise<Hex> {
  const account = accountFromPk(pk);
  return account.signTypedData({
    domain: eip712Domain(chainId, escrow),
    types: eip712Types,
    primaryType: "ProviderAgreement",
    message: {
      terms: env.terms,
      nonce: env.nonce,
      deadline: env.deadline,
    },
  });
}
