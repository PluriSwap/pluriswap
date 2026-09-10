import { encodeFunctionData, type Hex } from "viem";
import type { HexAddress } from "../addressbook/types.ts";
import { ZERO_ADDRESS } from "../deal/types.ts";
import type { Envelope } from "../consent/eip712.ts";
import { activateAbi } from "./activateAbi.ts";
import { normalizePk, writeEscrow } from "./chain.ts";

export const dummyCA = {
  terms: {
    holder: ZERO_ADDRESS,
    controller: ZERO_ADDRESS,
    provider: ZERO_ADDRESS,
    token: ZERO_ADDRESS,
    principal: 0n,
    fiatDuration: 0n,
    releaseDuration: 0n,
    disputeDuration: 0n,
    arbitrationDuration: 0n,
    packageIds: [] as Hex[],
  },
  nonce: 0n,
  deadline: 0n,
};

function toArg(env: Envelope) {
  return {
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
  };
}

export function encodeActivate6(
  ha: Envelope,
  holderSig: Hex,
  pa: Envelope,
  providerSig: Hex,
): Hex {
  return encodeFunctionData({
    abi: activateAbi,
    functionName: "activate",
    args: [toArg(ha), holderSig, toArg(pa), providerSig, dummyCA, "0x"],
  });
}

export function inspectActivate6(
  ha: Envelope,
  holderSig: Hex,
  pa: Envelope,
  providerSig: Hex,
): { overload: "6"; dummyCA: true; args: string[] } {
  return {
    overload: "6",
    dummyCA: true,
    args: [
      `ha nonce=${ha.nonce} deadline=${ha.deadline} holder=${ha.terms.holder}`,
      `holderSig ${holderSig}`,
      `pa nonce=${pa.nonce} deadline=${pa.deadline} provider=${pa.terms.provider}`,
      `providerSig ${providerSig}`,
      "ca: ControllerAcceptance (dummy zeros)",
      "controllerSig 0x",
    ],
  };
}

export async function sendActivate6(args: {
  rpcUrl: string;
  chainId: number;
  escrow: HexAddress;
  relayerPk: Hex;
  ha: Envelope;
  holderSig: Hex;
  pa: Envelope;
  providerSig: Hex;
}): Promise<Hex> {
  return writeEscrow({
    rpcUrl: args.rpcUrl,
    chainId: args.chainId,
    escrow: args.escrow,
    pk: normalizePk(args.relayerPk),
    abi: activateAbi,
    functionName: "activate",
    functionArgs: [toArg(args.ha), args.holderSig, toArg(args.pa), args.providerSig, dummyCA, "0x"],
  });
}

