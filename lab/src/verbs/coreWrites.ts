import type { Hex } from "viem";
import type { HexAddress, HexBytes32 } from "../addressbook/types.ts";
import { writeEscrow } from "./chain.ts";

export const CORE_WRITE_VERBS = [
  "markFiat",
  "cancelByProvider",
  "timeoutFiat",
  "release",
  "claim",
  "openDisputed",
  "forceStalemate",
  "withdraw",
  "cancelNonce",
  "retryPostTerminal",
] as const;

export type CoreWriteVerb = (typeof CORE_WRITE_VERBS)[number];

export const coreWriteAbi = [
  {
    type: "function",
    name: "markFiat",
    stateMutability: "nonpayable",
    inputs: [{ name: "dealId", type: "bytes32" }],
    outputs: [],
  },
  {
    type: "function",
    name: "cancelByProvider",
    stateMutability: "nonpayable",
    inputs: [{ name: "dealId", type: "bytes32" }],
    outputs: [],
  },
  {
    type: "function",
    name: "timeoutFiat",
    stateMutability: "nonpayable",
    inputs: [{ name: "dealId", type: "bytes32" }],
    outputs: [],
  },
  {
    type: "function",
    name: "release",
    stateMutability: "nonpayable",
    inputs: [{ name: "dealId", type: "bytes32" }],
    outputs: [],
  },
  {
    type: "function",
    name: "claim",
    stateMutability: "nonpayable",
    inputs: [{ name: "dealId", type: "bytes32" }],
    outputs: [],
  },
  {
    type: "function",
    name: "openDisputed",
    stateMutability: "nonpayable",
    inputs: [{ name: "dealId", type: "bytes32" }],
    outputs: [],
  },
  {
    type: "function",
    name: "forceStalemate",
    stateMutability: "nonpayable",
    inputs: [{ name: "dealId", type: "bytes32" }],
    outputs: [],
  },
  {
    type: "function",
    name: "withdraw",
    stateMutability: "nonpayable",
    inputs: [{ name: "token", type: "address" }],
    outputs: [],
  },
  {
    type: "function",
    name: "cancelNonce",
    stateMutability: "nonpayable",
    inputs: [{ name: "nonce", type: "uint256" }],
    outputs: [],
  },
  {
    type: "function",
    name: "retryPostTerminal",
    stateMutability: "nonpayable",
    inputs: [{ name: "dealId", type: "bytes32" }],
    outputs: [],
  },
] as const;

export function isCoreWrite(verb: string): verb is CoreWriteVerb {
  return (CORE_WRITE_VERBS as readonly string[]).includes(verb);
}

export async function sendCoreWrite(args: {
  rpcUrl: string;
  chainId: number;
  escrow: HexAddress;
  pk: string;
  verb: CoreWriteVerb;
  dealId: HexBytes32;
  token: HexAddress;
  nonce: bigint;
}): Promise<Hex> {
  if (args.verb === "withdraw") {
    return writeEscrow({
      ...args,
      abi: coreWriteAbi,
      functionName: "withdraw",
      functionArgs: [args.token],
    });
  }
  if (args.verb === "cancelNonce") {
    return writeEscrow({
      ...args,
      abi: coreWriteAbi,
      functionName: "cancelNonce",
      functionArgs: [args.nonce],
    });
  }
  return writeEscrow({
    ...args,
    abi: coreWriteAbi,
    functionName: args.verb,
    functionArgs: [args.dealId],
  });
}
