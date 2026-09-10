import { createPublicClient, http, isAddress, type Hex } from "viem";
import type { HexAddress, HexBytes32 } from "../addressbook/types.ts";
import { courtAbi, iescrowAbi, kernelAbi, operatorAbi } from "../recinto/iescrow.ts";
import { erc20Abi } from "../verbs/activateAbi.ts";
import { modulesPresent } from "./kinds.ts";
import {
  ZERO_BYTES32,
  isHexBytes32,
  isZeroAddress,
  type DealSnapshot,
  type ModuleBinding,
  type PackageMods,
} from "./types.ts";

export async function resolveDealId(
  rpcUrl: string,
  escrow: HexAddress,
  input: { dealId?: string; signer?: string; nonce?: string },
): Promise<HexBytes32> {
  if (input.dealId && isHexBytes32(input.dealId)) return input.dealId;
  if (input.signer && isAddress(input.signer) && input.nonce !== undefined && input.nonce !== "") {
    const client = createPublicClient({ transport: http(rpcUrl) });
    const id = (await client.readContract({
      address: escrow,
      abi: iescrowAbi,
      functionName: "dealOf",
      args: [input.signer as HexAddress, BigInt(input.nonce)],
    })) as Hex;
    return id as HexBytes32;
  }
  throw new Error("hace falta dealId (bytes32) o (signer, nonce)");
}

export async function fetchDeal(
  rpcUrl: string,
  escrow: HexAddress,
  dealId: HexBytes32,
): Promise<DealSnapshot> {
  const client = createPublicClient({ transport: http(rpcUrl) });
  const [block, status, terms, clocks, subjects, modules, kinds, settlement] = await Promise.all([
    client.getBlock({ blockTag: "latest" }),
    client.readContract({ address: escrow, abi: iescrowAbi, functionName: "status", args: [dealId] }),
    client.readContract({ address: escrow, abi: iescrowAbi, functionName: "terms", args: [dealId] }),
    client.readContract({ address: escrow, abi: iescrowAbi, functionName: "clocks", args: [dealId] }),
    client.readContract({ address: escrow, abi: iescrowAbi, functionName: "subjects", args: [dealId] }),
    client.readContract({ address: escrow, abi: iescrowAbi, functionName: "modules", args: [dealId] }),
    client.readContract({ address: escrow, abi: iescrowAbi, functionName: "kinds", args: [dealId] }),
    client.readContract({ address: escrow, abi: iescrowAbi, functionName: "settlementOf", args: [dealId] }),
  ]);

  const mods: PackageMods = {
    passport: modules.passport,
    reputation: modules.reputation,
    bonds: modules.bonds,
    zk: modules.zk,
    court: modules.court,
  };

  return {
    dealId,
    status,
    terms: {
      holder: terms.holder,
      controller: terms.controller,
      provider: terms.provider,
      token: terms.token,
      principal: terms.principal,
      fiatDuration: terms.fiatDuration,
      releaseDuration: terms.releaseDuration,
      disputeDuration: terms.disputeDuration,
      arbitrationDuration: terms.arbitrationDuration,
      packageIds: [...terms.packageIds] as HexBytes32[],
    },
    clocks: {
      activatedAt: clocks.activatedAt,
      fiatSentAt: clocks.fiatSentAt,
      disputedAt: clocks.disputedAt,
      arbitrationOpenedAt: clocks.arbitrationOpenedAt,
    },
    subjects: { holderSubject: subjects[0] as HexBytes32, providerSubject: subjects[1] as HexBytes32 },
    modules: mods,
    kinds,
    settlement: {
      status: settlement[0],
      holderAmt: settlement[1],
      providerAmt: settlement[2],
    },
    blockTimestamp: block.timestamp,
    blockNumber: block.number ?? 0n,
  };
}

export async function fetchBindings(
  rpcUrl: string,
  recinto: HexAddress,
  mods: PackageMods,
): Promise<ModuleBinding[]> {
  const slots = modulesPresent(mods);
  if (slots.length === 0) return [];
  const client = createPublicClient({ transport: http(rpcUrl) });
  const rows: ModuleBinding[] = [];
  for (const slot of slots) {
    const address = mods[slot];
    const operator = await readAddress(client, address, operatorAbi, "operator");
    const kernel = operator === null ? await readAddress(client, address, kernelAbi, "kernel") : null;
    const getter: ModuleBinding["getter"] = operator !== null ? "operator" : kernel !== null ? "kernel" : "none";
    const boundTo = operator ?? kernel;
    rows.push({
      slot,
      address,
      getter,
      boundTo,
      matchesRecinto: boundTo === null ? null : boundTo.toLowerCase() === recinto.toLowerCase(),
    });
  }
  return rows;
}

async function readAddress(
  client: ReturnType<typeof createPublicClient>,
  address: HexAddress,
  abi: typeof operatorAbi | typeof kernelAbi,
  functionName: "operator" | "kernel",
): Promise<HexAddress | null> {
  try {
    const value = await client.readContract({ address, abi, functionName });
    if (typeof value !== "string" || isZeroAddress(value)) return null;
    return value as HexAddress;
  } catch {
    return null;
  }
}

export function isEmptyDealId(id: string): boolean {
  return id.toLowerCase() === ZERO_BYTES32;
}

export async function fetchCredit(
  rpcUrl: string,
  escrow: HexAddress,
  token: HexAddress,
  beneficiary: HexAddress,
): Promise<bigint> {
  const client = createPublicClient({ transport: http(rpcUrl) });
  return client.readContract({
    address: escrow,
    abi: iescrowAbi,
    functionName: "creditOf",
    args: [token, beneficiary],
  });
}

export async function fetchUsed(
  rpcUrl: string,
  escrow: HexAddress,
  signer: HexAddress,
  nonce: bigint,
): Promise<boolean> {
  const client = createPublicClient({ transport: http(rpcUrl) });
  return client.readContract({
    address: escrow,
    abi: iescrowAbi,
    functionName: "used",
    args: [signer, nonce],
  });
}

export async function fetchAllowance(
  rpcUrl: string,
  token: HexAddress,
  owner: HexAddress,
  spender: HexAddress,
): Promise<bigint> {
  const client = createPublicClient({ transport: http(rpcUrl) });
  return client.readContract({
    address: token,
    abi: erc20Abi,
    functionName: "allowance",
    args: [owner, spender],
  });
}

export async function fetchStatus(
  rpcUrl: string,
  escrow: HexAddress,
  dealId: HexBytes32,
): Promise<number> {
  const client = createPublicClient({ transport: http(rpcUrl) });
  return client.readContract({
    address: escrow,
    abi: iescrowAbi,
    functionName: "status",
    args: [dealId],
  });
}

export async function fetchRuling(
  rpcUrl: string,
  court: HexAddress,
  dealId: HexBytes32,
): Promise<number | null> {
  if (isZeroAddress(court)) return null;
  const client = createPublicClient({ transport: http(rpcUrl) });
  try {
    return await client.readContract({
      address: court,
      abi: courtAbi,
      functionName: "readRuling",
      args: [dealId],
    });
  } catch {
    return null;
  }
}
