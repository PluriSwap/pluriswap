import { createPublicClient, getAddress, http, isAddress } from "viem";
import type { HexAddress, HexBytes32 } from "../addressbook/types.ts";
import { ZERO_ADDRESS, isZeroAddress, type PackageMods } from "../deal/types.ts";
import { emptyPolicy, type LivePolicy, type ModsDraft } from "./types.ts";

const slotAbi = [
  { type: "function", name: "passport", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "feeRecipient", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "activationFee", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "completionFee", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "operator", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "sink", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "verifier", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "verifyFee", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  {
    type: "function",
    name: "packageBinding",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { name: "partner", type: "address" },
      { name: "key", type: "uint256" },
    ],
  },
  { type: "function", name: "kernel", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "extraData", stateMutability: "view", inputs: [], outputs: [{ type: "bytes" }] },
  {
    type: "function",
    name: "identify",
    stateMutability: "view",
    inputs: [{ name: "wallet", type: "address" }],
    outputs: [{ type: "bytes32" }],
  },
] as const;

function addr(value: string): HexAddress | null {
  if (!value || !isAddress(value)) return null;
  const a = getAddress(value) as HexAddress;
  return isZeroAddress(a) ? null : a;
}

export function parseModsDraft(d: ModsDraft): PackageMods {
  return {
    passport: addr(d.passport) ?? ZERO_ADDRESS,
    reputation: addr(d.reputation) ?? ZERO_ADDRESS,
    bonds: addr(d.bonds) ?? ZERO_ADDRESS,
    zk: addr(d.zk) ?? ZERO_ADDRESS,
    court: addr(d.court) ?? ZERO_ADDRESS,
  };
}

async function read<T>(
  client: ReturnType<typeof createPublicClient>,
  address: HexAddress,
  functionName: (typeof slotAbi)[number]["name"],
): Promise<T | null> {
  try {
    return (await client.readContract({
      address,
      abi: slotAbi,
      functionName,
    })) as T;
  } catch {
    return null;
  }
}

export async function probeSlots(
  rpcUrl: string,
  mods: PackageMods,
  holder: HexAddress | null,
  provider: HexAddress | null,
): Promise<LivePolicy> {
  const policy = emptyPolicy();
  const client = createPublicClient({ transport: http(rpcUrl) });

  if (!isZeroAddress(mods.passport)) {
    policy.passport = { address: mods.passport };
    if (holder) {
      try {
        policy.identifyHolder = (await client.readContract({
          address: mods.passport,
          abi: slotAbi,
          functionName: "identify",
          args: [holder],
        })) as HexBytes32;
      } catch {
        policy.identifyError = "IPassport.NoPassport";
      }
    }
    if (provider && !policy.identifyError) {
      try {
        policy.identifyProvider = (await client.readContract({
          address: mods.passport,
          abi: slotAbi,
          functionName: "identify",
          args: [provider],
        })) as HexBytes32;
      } catch {
        policy.identifyError = "IPassport.NoPassport";
      }
    }
  }
  if (!isZeroAddress(mods.reputation)) {
    policy.reputation = {
      address: mods.reputation,
      passport: await read(client, mods.reputation, "passport"),
      feeRecipient: await read(client, mods.reputation, "feeRecipient"),
      activationFee: await read(client, mods.reputation, "activationFee"),
      completionFee: await read(client, mods.reputation, "completionFee"),
      operator: await read(client, mods.reputation, "operator"),
    };
  }
  if (!isZeroAddress(mods.bonds)) {
    policy.bonds = {
      address: mods.bonds,
      passport: await read(client, mods.bonds, "passport"),
      sink: await read(client, mods.bonds, "sink"),
      operator: await read(client, mods.bonds, "operator"),
    };
  }
  if (!isZeroAddress(mods.zk)) {
    policy.zk = {
      address: mods.zk,
      verifier: await read(client, mods.zk, "verifier"),
      feeRecipient: await read(client, mods.zk, "feeRecipient"),
      verifyFee: await read(client, mods.zk, "verifyFee"),
      operator: await read(client, mods.zk, "operator"),
    };
  }
  if (!isZeroAddress(mods.court)) {
    let partner: HexAddress | null = null;
    let key: bigint | null = null;
    try {
      const binding = (await client.readContract({
        address: mods.court,
        abi: slotAbi,
        functionName: "packageBinding",
      })) as readonly [HexAddress, bigint];
      partner = binding[0];
      key = binding[1];
    } catch {
      /* not a court */
    }
    policy.court = {
      address: mods.court,
      partner,
      key,
      operator: await read(client, mods.court, "operator"),
      kernel: await read(client, mods.court, "kernel"),
      extraData: await read(client, mods.court, "extraData"),
    };
  }
  return policy;
}
