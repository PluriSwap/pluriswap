import { createPublicClient, http, type Hex } from "viem";
import type { HexAddress } from "../addressbook/types.ts";
import { writeContractTx } from "../verbs/chain.ts";

export type RampIntent = {
  token: HexAddress;
  amount: bigint;
  minAmountOut: bigint;
  dest: number;
  to: HexAddress;
  refund: HexAddress;
};

const rampAbi = [
  {
    type: "function",
    name: "quote",
    stateMutability: "view",
    inputs: [
      {
        name: "intent",
        type: "tuple",
        components: [
          { name: "token", type: "address" },
          { name: "amount", type: "uint256" },
          { name: "minAmountOut", type: "uint256" },
          { name: "dest", type: "uint32" },
          { name: "to", type: "address" },
          { name: "refund", type: "address" },
        ],
      },
    ],
    outputs: [
      {
        name: "",
        type: "tuple",
        components: [
          { name: "nativeFee", type: "uint256" },
          { name: "amountOut", type: "uint256" },
        ],
      },
    ],
  },
  {
    type: "function",
    name: "send",
    stateMutability: "payable",
    inputs: [
      {
        name: "intent",
        type: "tuple",
        components: [
          { name: "token", type: "address" },
          { name: "amount", type: "uint256" },
          { name: "minAmountOut", type: "uint256" },
          { name: "dest", type: "uint32" },
          { name: "to", type: "address" },
          { name: "refund", type: "address" },
        ],
      },
    ],
    outputs: [],
  },
  { type: "function", name: "token", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
] as const;

export async function rampQuote(
  rpcUrl: string,
  ramp: HexAddress,
  intent: RampIntent,
): Promise<{ nativeFee: bigint; amountOut: bigint }> {
  const client = createPublicClient({ transport: http(rpcUrl) });
  return client.readContract({
    address: ramp,
    abi: rampAbi,
    functionName: "quote",
    args: [intent],
  });
}

export async function rampSend(args: {
  rpcUrl: string;
  chainId: number;
  ramp: HexAddress;
  pk: string;
  intent: RampIntent;
  value: bigint;
}): Promise<Hex> {
  return writeContractTx({
    rpcUrl: args.rpcUrl,
    chainId: args.chainId,
    address: args.ramp,
    pk: args.pk,
    abi: rampAbi,
    functionName: "send",
    functionArgs: [args.intent],
    value: args.value,
  });
}
