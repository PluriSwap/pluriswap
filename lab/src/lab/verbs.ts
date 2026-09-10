import { createPublicClient, http, type Hex } from "viem";
import type { HexAddress, HexBytes32 } from "../addressbook/types.ts";
import { chainOf, writeContractTx } from "../verbs/chain.ts";


export const passportMockAbi = [
  {
    type: "function",
    name: "setHuman",
    stateMutability: "nonpayable",
    inputs: [
      { name: "wallet", type: "address" },
      { name: "subject", type: "bytes32" },
    ],
    outputs: [],
  },
] as const;

export const arbitrationMockAbi = [
  {
    type: "function",
    name: "submitRuling",
    stateMutability: "nonpayable",
    inputs: [
      { name: "dealId", type: "bytes32" },
      { name: "ruling", type: "uint8" },
    ],
    outputs: [],
  },
] as const;

export const testTokenAbi = [
  {
    type: "function",
    name: "mint",
    stateMutability: "nonpayable",
    inputs: [
      { name: "to", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ type: "bool" }],
  },
] as const;

export const bondVaultAbi = [
  {
    type: "function",
    name: "deposit",
    stateMutability: "nonpayable",
    inputs: [
      { name: "subject", type: "bytes32" },
      { name: "token", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [],
  },
] as const;

export async function labSetHuman(args: {
  rpcUrl: string;
  chainId: number;
  passport: HexAddress;
  pk: string;
  wallet: HexAddress;
  subject: HexBytes32;
}): Promise<Hex> {
  return writeContractTx({
    ...args,
    address: args.passport,
    abi: passportMockAbi,
    functionName: "setHuman",
    functionArgs: [args.wallet, args.subject],
  });
}

export async function labSubmitRuling(args: {
  rpcUrl: string;
  chainId: number;
  court: HexAddress;
  pk: string;
  dealId: HexBytes32;
  ruling: number;
}): Promise<Hex> {
  return writeContractTx({
    ...args,
    address: args.court,
    abi: arbitrationMockAbi,
    functionName: "submitRuling",
    functionArgs: [args.dealId, args.ruling],
  });
}

export async function labMint(args: {
  rpcUrl: string;
  chainId: number;
  token: HexAddress;
  pk: string;
  to: HexAddress;
  amount: bigint;
}): Promise<Hex> {
  return writeContractTx({
    ...args,
    address: args.token,
    abi: testTokenAbi,
    functionName: "mint",
    functionArgs: [args.to, args.amount],
  });
}

export async function labApprove(args: {
  rpcUrl: string;
  chainId: number;
  token: HexAddress;
  pk: string;
  spender: HexAddress;
  amount: bigint;
}): Promise<Hex> {
  return writeContractTx({
    ...args,
    address: args.token,
    abi: testTokenAbi,
    functionName: "approve",
    functionArgs: [args.spender, args.amount],
  });
}

export async function labDeposit(args: {
  rpcUrl: string;
  chainId: number;
  vault: HexAddress;
  pk: string;
  subject: HexBytes32;
  token: HexAddress;
  amount: bigint;
}): Promise<Hex> {
  return writeContractTx({
    ...args,
    address: args.vault,
    abi: bondVaultAbi,
    functionName: "deposit",
    functionArgs: [args.subject, args.token, args.amount],
  });
}

export async function anvilIncreaseTime(rpcUrl: string, seconds: number): Promise<void> {
  const client = createPublicClient({ chain: chainOf(31337), transport: http(rpcUrl) });
  await client.request({ method: "evm_increaseTime", params: [seconds] } as never);
  await client.request({ method: "evm_mine", params: [] } as never);
}
