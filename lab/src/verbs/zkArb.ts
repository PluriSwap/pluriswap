import type { Hex } from "viem";
import type { HexAddress, HexBytes32 } from "../addressbook/types.ts";
import { writeEscrow } from "./chain.ts";

export const ZK_ARB_VERBS = ["verifyProof", "openCourt", "readRuling", "forceArbitrationTimeout"] as const;
export type ZkArbVerb = (typeof ZK_ARB_VERBS)[number];

export function isZkArb(verb: string): verb is ZkArbVerb {
  return (ZK_ARB_VERBS as readonly string[]).includes(verb);
}

export const zkArbAbi = [
  {
    type: "function",
    name: "verifyProof",
    stateMutability: "nonpayable",
    inputs: [
      { name: "dealId", type: "bytes32" },
      { name: "proof", type: "bytes" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "openCourt",
    stateMutability: "payable",
    inputs: [{ name: "dealId", type: "bytes32" }],
    outputs: [],
  },
  {
    type: "function",
    name: "readRuling",
    stateMutability: "nonpayable",
    inputs: [{ name: "dealId", type: "bytes32" }],
    outputs: [],
  },
  {
    type: "function",
    name: "forceArbitrationTimeout",
    stateMutability: "nonpayable",
    inputs: [{ name: "dealId", type: "bytes32" }],
    outputs: [],
  },
] as const;

export async function sendZkArb(args: {
  rpcUrl: string;
  chainId: number;
  escrow: HexAddress;
  pk: string;
  verb: ZkArbVerb;
  dealId: HexBytes32;
  proof?: Hex;
  value?: bigint;
}): Promise<Hex> {
  if (args.verb === "verifyProof") {
    return writeEscrow({
      ...args,
      abi: zkArbAbi,
      functionName: "verifyProof",
      functionArgs: [args.dealId, args.proof ?? "0x"],
    });
  }
  if (args.verb === "openCourt") {
    return writeEscrow({
      ...args,
      abi: zkArbAbi,
      functionName: "openCourt",
      functionArgs: [args.dealId],
      value: args.value ?? 0n,
    });
  }
  return writeEscrow({
    ...args,
    abi: zkArbAbi,
    functionName: args.verb,
    functionArgs: [args.dealId],
  });
}
