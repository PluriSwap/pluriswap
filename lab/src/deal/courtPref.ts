import { createPublicClient, http, type Hex } from "viem";
import type { HexAddress } from "../addressbook/types.ts";
import { isZeroAddress } from "./types.ts";
import { erc20Abi } from "../verbs/activateAbi.ts";

const courtExtraAbi = [
  { type: "function", name: "courtFee", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "feeToken", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "extraData", stateMutability: "view", inputs: [], outputs: [{ type: "bytes" }] },
  { type: "function", name: "arbitrator", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "operator", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "kernel", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
] as const;

const arbCostAbi = [
  {
    type: "function",
    name: "arbitrationCost",
    stateMutability: "view",
    inputs: [{ name: "extraData", type: "bytes" }],
    outputs: [{ type: "uint256" }],
  },
] as const;

export type CourtPref = {
  kind: "mock" | "kleros" | "unknown";
  courtFee: bigint | null;
  feeToken: HexAddress | null;
  allowance: bigint | null;
  extraData: Hex | null;
  cost: bigint | null;
};

export async function fetchCourtPref(
  rpcUrl: string,
  court: HexAddress,
  controller: HexAddress | null,
): Promise<CourtPref> {
  const empty: CourtPref = {
    kind: "unknown",
    courtFee: null,
    feeToken: null,
    allowance: null,
    extraData: null,
    cost: null,
  };
  if (isZeroAddress(court)) return empty;
  const client = createPublicClient({ transport: http(rpcUrl) });
  let courtFee: bigint | null = null;
  let feeToken: HexAddress | null = null;
  let extraData: Hex | null = null;
  let arbitrator: HexAddress | null = null;
  try {
    courtFee = (await client.readContract({ address: court, abi: courtExtraAbi, functionName: "courtFee" })) as bigint;
  } catch {
    courtFee = null;
  }
  try {
    feeToken = (await client.readContract({
      address: court,
      abi: courtExtraAbi,
      functionName: "feeToken",
    })) as HexAddress;
  } catch {
    feeToken = null;
  }
  try {
    extraData = (await client.readContract({
      address: court,
      abi: courtExtraAbi,
      functionName: "extraData",
    })) as Hex;
  } catch {
    extraData = null;
  }
  try {
    arbitrator = (await client.readContract({
      address: court,
      abi: courtExtraAbi,
      functionName: "arbitrator",
    })) as HexAddress;
  } catch {
    arbitrator = null;
  }
  let allowance: bigint | null = null;
  if (feeToken && controller) {
    try {
      allowance = await client.readContract({
        address: feeToken,
        abi: erc20Abi,
        functionName: "allowance",
        args: [controller, court],
      });
    } catch {
      allowance = null;
    }
  }
  let cost: bigint | null = null;
  if (arbitrator && extraData) {
    try {
      cost = (await client.readContract({
        address: arbitrator,
        abi: arbCostAbi,
        functionName: "arbitrationCost",
        args: [extraData],
      })) as bigint;
    } catch {
      cost = null;
    }
  }
  const kind: CourtPref["kind"] = extraData ? "kleros" : courtFee !== null ? "mock" : "unknown";
  return { kind, courtFee, feeToken, allowance, extraData, cost };
}
