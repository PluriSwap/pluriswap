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

function caArg(ca: Envelope | null | undefined, controllerSig: Hex | null | undefined) {
  const dummy = !ca || !controllerSig;
  return {
    ca: dummy ? dummyCA : toArg(ca),
    controllerSig: dummy ? ("0x" as Hex) : controllerSig,
    dummy,
  };
}

export function encodeActivate6(
  ha: Envelope,
  holderSig: Hex,
  pa: Envelope,
  providerSig: Hex,
  ca?: Envelope | null,
  controllerSig?: Hex | null,
): Hex {
  const packed = caArg(ca, controllerSig);
  return encodeFunctionData({
    abi: activateAbi,
    functionName: "activate",
    args: [toArg(ha), holderSig, toArg(pa), providerSig, packed.ca, packed.controllerSig],
  });
}

export function inspectActivate6(
  ha: Envelope,
  holderSig: Hex,
  pa: Envelope,
  providerSig: Hex,
  ca?: Envelope | null,
  controllerSig?: Hex | null,
): { overload: "6"; dummyCA: boolean; args: string[] } {
  const packed = caArg(ca, controllerSig);
  return {
    overload: "6",
    dummyCA: packed.dummy,
    args: [
      `ha nonce=${ha.nonce} deadline=${ha.deadline} holder=${ha.terms.holder}`,
      `holderSig ${holderSig}`,
      `pa nonce=${pa.nonce} deadline=${pa.deadline} provider=${pa.terms.provider}`,
      `providerSig ${providerSig}`,
      packed.dummy
        ? "ca: ControllerAcceptance (dummy zeros)"
        : `ca nonce=${ca!.nonce} deadline=${ca!.deadline} controller=${ca!.terms.controller}`,
      packed.dummy ? "controllerSig 0x" : `controllerSig ${controllerSig}`,
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
  ca?: Envelope | null;
  controllerSig?: Hex | null;
}): Promise<Hex> {
  const packed = caArg(args.ca, args.controllerSig);
  return writeEscrow({
    rpcUrl: args.rpcUrl,
    chainId: args.chainId,
    escrow: args.escrow,
    pk: normalizePk(args.relayerPk),
    abi: activateAbi,
    functionName: "activate",
    functionArgs: [
      toArg(args.ha),
      args.holderSig,
      toArg(args.pa),
      args.providerSig,
      packed.ca,
      packed.controllerSig,
    ],
  });
}
