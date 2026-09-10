import { createPublicClient, createWalletClient, http, type Abi, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { anvil, arbitrumSepolia } from "viem/chains";
import type { HexAddress } from "../addressbook/types.ts";

export function chainOf(chainId: number) {
  if (chainId === 31337) return anvil;
  if (chainId === 421614) return arbitrumSepolia;
  return { ...anvil, id: chainId, name: `chain-${chainId}` };
}

export function normalizePk(pk: string): Hex {
  return (pk.startsWith("0x") ? pk : `0x${pk}`) as Hex;
}

export async function writeEscrow(args: {
  rpcUrl: string;
  chainId: number;
  escrow: HexAddress;
  pk: string;
  abi: Abi;
  functionName: string;
  functionArgs?: readonly unknown[];
}): Promise<Hex> {
  const account = privateKeyToAccount(normalizePk(args.pk));
  const chain = chainOf(args.chainId);
  const wallet = createWalletClient({ account, chain, transport: http(args.rpcUrl) });
  const hash = await wallet.writeContract({
    address: args.escrow,
    abi: args.abi,
    functionName: args.functionName,
    args: args.functionArgs ?? [],
    chain,
    account,
  });
  const publicClient = createPublicClient({ chain, transport: http(args.rpcUrl) });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`${args.functionName} reverted (${hash})`);
  return hash;
}
