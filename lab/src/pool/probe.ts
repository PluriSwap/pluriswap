import { createPublicClient, http } from "viem";
import type { HexAddress } from "../addressbook/types.ts";
import { LIFE, poolAbi } from "./abi.ts";

export type PoolSnapshot = {
  pool: HexAddress;
  escrow: HexAddress;
  token: HexAddress;
  life: number;
  lifeName: string;
  idle: bigint;
  locked: bigint;
  credits: bigint;
  consumed: bigint;
  totalShares: bigint;
  nav: bigint;
  controllerFeeBps: number;
  agent: boolean | null;
};

export async function probePool(
  rpcUrl: string,
  pool: HexAddress,
  agent: HexAddress | null,
): Promise<PoolSnapshot> {
  const client = createPublicClient({ transport: http(rpcUrl) });
  const [escrow, token, life, idle, locked, credits, consumed, totalShares, nav, fee] = await Promise.all([
    client.readContract({ address: pool, abi: poolAbi, functionName: "escrow" }),
    client.readContract({ address: pool, abi: poolAbi, functionName: "token" }),
    client.readContract({ address: pool, abi: poolAbi, functionName: "life" }),
    client.readContract({ address: pool, abi: poolAbi, functionName: "idle" }),
    client.readContract({ address: pool, abi: poolAbi, functionName: "locked" }),
    client.readContract({ address: pool, abi: poolAbi, functionName: "credits" }),
    client.readContract({ address: pool, abi: poolAbi, functionName: "consumed" }),
    client.readContract({ address: pool, abi: poolAbi, functionName: "totalShares" }),
    client.readContract({ address: pool, abi: poolAbi, functionName: "nav" }),
    client.readContract({ address: pool, abi: poolAbi, functionName: "controllerFeeBps" }),
  ]);
  let isAgent: boolean | null = null;
  if (agent) {
    try {
      isAgent = await client.readContract({
        address: pool,
        abi: poolAbi,
        functionName: "isAgent",
        args: [agent],
      });
    } catch {
      isAgent = null;
    }
  }
  return {
    pool,
    escrow,
    token,
    life,
    lifeName: LIFE[life] ?? `life(${life})`,
    idle,
    locked,
    credits,
    consumed,
    totalShares,
    nav,
    controllerFeeBps: fee,
    agent: isAgent,
  };
}
