import { getAddress, isAddress } from "viem";
import type { AddressSet, HexAddress, RecintoRow } from "./types.ts";

function asRecord(json: unknown): Record<string, unknown> {
  if (json === null || typeof json !== "object" || Array.isArray(json)) {
    throw new Error("deployment JSON must be an object");
  }
  return json as Record<string, unknown>;
}

function readAddress(value: unknown): HexAddress | null {
  if (typeof value !== "string" || !isAddress(value)) return null;
  return getAddress(value);
}

function stringifyLabel(value: unknown): string {
  if (typeof value === "string") return value;
  if (typeof value === "number" || typeof value === "boolean") return String(value);
  return JSON.stringify(value);
}

/**
 * Parse one deployments file. A Recinto exists only when `escrow` is a real address.
 * `sepolia-kleros.json` and `*-pool-factory.json` have no escrow → auxiliary sets.
 */
export function parseDeploymentFile(sourceFile: string, json: unknown): AddressSet {
  const raw = asRecord(json);
  const escrow = readAddress(raw.escrow);
  const testToken = readAddress(raw.testToken);
  const chainId = typeof raw.chainId === "number" ? raw.chainId : null;
  const labels: Record<string, string> = {};
  for (const [key, value] of Object.entries(raw)) {
    if (key === "chainId" || key === "escrow" || key === "testToken") continue;
    if (value === undefined || value === null) continue;
    labels[key] = stringifyLabel(value);
  }
  return {
    sourceFile,
    chainId,
    escrow,
    isRecinto: escrow !== null,
    testToken,
    labels,
  };
}

export function recintosFromSets(sets: AddressSet[]): RecintoRow[] {
  const map = new Map<string, RecintoRow>();
  for (const set of sets) {
    if (!set.isRecinto || set.escrow === null || set.chainId === null) continue;
    const key = `${set.chainId}:${set.escrow.toLowerCase()}`;
    let row = map.get(key);
    if (!row) {
      row = { chainId: set.chainId, escrow: set.escrow, sources: [], testTokens: [] };
      map.set(key, row);
    }
    if (!row.sources.includes(set.sourceFile)) row.sources.push(set.sourceFile);
    if (set.testToken && !row.testTokens.some((t) => t.sourceFile === set.sourceFile)) {
      row.testTokens.push({ sourceFile: set.sourceFile, token: set.testToken });
    }
  }
  return [...map.values()].sort((a, b) => {
    if (a.chainId !== b.chainId) return a.chainId - b.chainId;
    return a.escrow.localeCompare(b.escrow);
  });
}

export function sourceFileName(globPath: string): string {
  const slash = globPath.lastIndexOf("/");
  return slash >= 0 ? globPath.slice(slash + 1) : globPath;
}

/** Eager glob of repo deployments/. Missing gitignored Anvil files simply do not appear. */
export function loadBundledSets(): AddressSet[] {
  const modules = import.meta.glob("../../../deployments/*.json", {
    eager: true,
    import: "default",
  }) as Record<string, unknown>;
  const sets: AddressSet[] = [];
  for (const [path, json] of Object.entries(modules)) {
    sets.push(parseDeploymentFile(sourceFileName(path), json));
  }
  return sets.sort((a, b) => a.sourceFile.localeCompare(b.sourceFile));
}
