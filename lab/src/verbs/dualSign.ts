import type { Hex } from "viem";
import type { HexAddress } from "../addressbook/types.ts";
import type { DualSignType } from "../session/DualSignDraft.ts";
import { writeEscrow } from "./chain.ts";

const cancelReleaseComponents = [
  { name: "dealId", type: "bytes32" },
  { name: "nonce", type: "uint256" },
  { name: "deadline", type: "uint256" },
] as const;

const splitComponents = [
  { name: "dealId", type: "bytes32" },
  { name: "providerBps", type: "uint16" },
  { name: "nonce", type: "uint256" },
  { name: "deadline", type: "uint256" },
] as const;

export const dualSignAbi = [
  {
    type: "function",
    name: "mutualCancel",
    stateMutability: "nonpayable",
    inputs: [
      { name: "providerMsg", type: "tuple", components: cancelReleaseComponents },
      { name: "providerSig", type: "bytes" },
      { name: "controllerMsg", type: "tuple", components: cancelReleaseComponents },
      { name: "controllerSig", type: "bytes" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "coSignedRelease",
    stateMutability: "nonpayable",
    inputs: [
      { name: "providerMsg", type: "tuple", components: cancelReleaseComponents },
      { name: "providerSig", type: "bytes" },
      { name: "controllerMsg", type: "tuple", components: cancelReleaseComponents },
      { name: "controllerSig", type: "bytes" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "mutualSplit",
    stateMutability: "nonpayable",
    inputs: [
      { name: "providerMsg", type: "tuple", components: splitComponents },
      { name: "providerSig", type: "bytes" },
      { name: "controllerMsg", type: "tuple", components: splitComponents },
      { name: "controllerSig", type: "bytes" },
    ],
    outputs: [],
  },
] as const;

export async function sendDualSign(args: {
  rpcUrl: string;
  chainId: number;
  escrow: HexAddress;
  pk: string;
  type: DualSignType;
  dealId: Hex;
  deadline: bigint;
  nonceP: bigint;
  nonceC: bigint;
  providerBps: number;
  providerSig: Hex;
  controllerSig: Hex;
}): Promise<Hex> {
  const pair = { dealId: args.dealId, nonce: args.nonceP, deadline: args.deadline };
  const pairC = { dealId: args.dealId, nonce: args.nonceC, deadline: args.deadline };
  if (args.type === "MutualCancel") {
    return writeEscrow({
      ...args,
      abi: dualSignAbi,
      functionName: "mutualCancel",
      functionArgs: [pair, args.providerSig, pairC, args.controllerSig],
    });
  }
  if (args.type === "CoSignedRelease") {
    return writeEscrow({
      ...args,
      abi: dualSignAbi,
      functionName: "coSignedRelease",
      functionArgs: [pair, args.providerSig, pairC, args.controllerSig],
    });
  }
  const splitP = { ...pair, providerBps: args.providerBps };
  const splitC = { ...pairC, providerBps: args.providerBps };
  return writeEscrow({
    ...args,
    abi: dualSignAbi,
    functionName: "mutualSplit",
    functionArgs: [splitP, args.providerSig, splitC, args.controllerSig],
  });
}
