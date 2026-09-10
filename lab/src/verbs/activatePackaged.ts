import { encodeFunctionData, type Hex } from "viem";
import type { HexAddress } from "../addressbook/types.ts";
import type { Envelope } from "../consent/eip712.ts";
import type { PackageMods } from "../deal/types.ts";
import { dummyCA } from "./activateCore.ts";
import { activate7Abi } from "./activateAbi.ts";
import { normalizePk, writeEscrow } from "./chain.ts";

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

export function inspectActivate7(
  ha: Envelope,
  holderSig: Hex,
  pa: Envelope,
  providerSig: Hex,
  mods: PackageMods,
  ca?: Envelope | null,
  controllerSig?: Hex | null,
): { overload: "7"; dummyCA: boolean; args: string[] } {
  const packed = caArg(ca, controllerSig);
  return {
    overload: "7",
    dummyCA: packed.dummy,
    args: [
      `ha nonce=${ha.nonce} packageIds=${ha.terms.packageIds.length}`,
      `holderSig ${holderSig}`,
      `pa nonce=${pa.nonce}`,
      `providerSig ${providerSig}`,
      packed.dummy ? "ca dummy" : `ca nonce=${ca!.nonce}`,
      packed.dummy ? "controllerSig 0x" : `controllerSig ${controllerSig}`,
      `mods passport=${mods.passport} reputation=${mods.reputation} bonds=${mods.bonds} zk=${mods.zk} court=${mods.court}`,
    ],
  };
}

export function encodeActivate7(
  ha: Envelope,
  holderSig: Hex,
  pa: Envelope,
  providerSig: Hex,
  mods: PackageMods,
  ca?: Envelope | null,
  controllerSig?: Hex | null,
): Hex {
  const packed = caArg(ca, controllerSig);
  return encodeFunctionData({
    abi: activate7Abi,
    functionName: "activate",
    args: [toArg(ha), holderSig, toArg(pa), providerSig, packed.ca, packed.controllerSig, mods],
  });
}

export async function sendActivate7(args: {
  rpcUrl: string;
  chainId: number;
  escrow: HexAddress;
  relayerPk: Hex;
  ha: Envelope;
  holderSig: Hex;
  pa: Envelope;
  providerSig: Hex;
  mods: PackageMods;
  ca?: Envelope | null;
  controllerSig?: Hex | null;
}): Promise<Hex> {
  const packed = caArg(args.ca, args.controllerSig);
  return writeEscrow({
    rpcUrl: args.rpcUrl,
    chainId: args.chainId,
    escrow: args.escrow,
    pk: normalizePk(args.relayerPk),
    abi: activate7Abi,
    functionName: "activate",
    functionArgs: [
      toArg(args.ha),
      args.holderSig,
      toArg(args.pa),
      args.providerSig,
      packed.ca,
      packed.controllerSig,
      args.mods,
    ],
  });
}
