// Recovering a private account from its secret and the chain.
//
// This is the property the derived leaf salt exists for (§3.15.3). Before it, rebuilding your leaf
// meant reproducing a salt that only lived in your client's local state, so an account was
// recoverable from a database rather than from a secret. Now `sk_id` is enough, and this is the
// code that shows it: compute the candidate leaf, find it in the tree the contract owns.
//
// What it deliberately does NOT do is trust a local cache. Every value here comes from the chain or
// from the secret. If a client's state is lost, wrong, or was never written, recovery still works.

import type { Address, PublicClient } from "viem";
import { accountCommitment, dealSubject, leafRep, leafSalt, nullRep } from "./commitments.ts";
import type { TreeSnapshot } from "./indexer.ts";
import type { Path } from "./tree.ts";

/** The stats a leaf carries, in `leafRep` field order. */
export type Stats = {
  count: bigint;
  volume: bigint;
  penalty: bigint;
  inFlight: bigint;
  /** The token the stats are denominated in; zero on the genesis leaf. */
  token: bigint;
};

export const GENESIS: Stats = { count: 0n, volume: 0n, penalty: 0n, inFlight: 0n, token: 0n };

export type AccountState = {
  skId: bigint;
  /** `S = Poseidon(sk_id)` — what the leaf actually commits to. */
  s: bigint;
  version: bigint;
  stats: Stats;
  /** Where the leaf sits in the accounts tree. */
  index: number;
  /** Membership against the tree's CURRENT root, ready to hand a circuit. */
  path: Path;
  /** The nullifier the next transition will burn. Already spent means this version moved on. */
  nextNullifier: bigint;
};

/** The leaf a given secret and state commit to. No stored salt: the salt is derived. */
export async function leafFor(skId: bigint, stats: Stats, version: bigint): Promise<bigint> {
  const s = await accountCommitment(skId);
  return leafRep(
    s,
    stats.count,
    stats.volume,
    stats.penalty,
    stats.inFlight,
    stats.token,
    await leafSalt(skId, version),
    version,
  );
}

/**
 * Locates an account in a reconstructed tree, given the secret and a candidate state.
 *
 * Returns null when that leaf is not in the tree, which is the honest answer to "is this what my
 * account looks like": a caller replaying deltas uses it to confirm each step rather than assuming.
 */
export async function locate(
  snapshot: TreeSnapshot,
  skId: bigint,
  stats: Stats,
  version: bigint,
): Promise<AccountState | null> {
  const leaf = await leafFor(skId, stats, version);
  const index = snapshot.state.indexOf(leaf);
  if (index < 0) return null;
  return {
    skId,
    s: await accountCommitment(skId),
    version,
    stats,
    index,
    path: snapshot.state.pathFor(index),
    nextNullifier: await nullRep(skId, version),
  };
}

const ESCROW_ABI = [
  {
    type: "event",
    name: "Activated",
    inputs: [
      { name: "dealId", type: "bytes32", indexed: false },
      { name: "holder", type: "address", indexed: false },
      { name: "provider", type: "address", indexed: false },
      { name: "controller", type: "address", indexed: false },
      { name: "token", type: "address", indexed: false },
      { name: "principal", type: "uint256", indexed: false },
    ],
  },
  {
    type: "function",
    name: "subjects",
    inputs: [{ type: "bytes32" }],
    outputs: [{ type: "bytes32" }, { type: "bytes32" }],
    stateMutability: "view",
  },
] as const;

export type OwnDeal = {
  dealId: bigint;
  /** Which seat the secret held. The kernel never knows this; only the secret can tell. */
  side: "holder" | "provider";
  token: bigint;
  principal: bigint;
  subject: bigint;
};

/**
 * Finds the deals a secret took part in, by recomputing the per-deal pseudonym.
 *
 * `dealSubject = Poseidon(sk_id, dealId)` is all the kernel ever stores, and it is unlinkable
 * across deals to anyone without the secret — which is exactly what makes this scan the ONLY way to
 * find your own history, and why it has to be done by the owner rather than served by an indexer.
 */
export async function scanDeals(
  client: PublicClient,
  escrow: Address,
  skId: bigint,
  opts: { fromBlock?: bigint } = {},
): Promise<OwnDeal[]> {
  const logs = await client.getContractEvents({
    address: escrow,
    abi: ESCROW_ABI,
    eventName: "Activated",
    fromBlock: opts.fromBlock ?? 0n,
    toBlock: "latest",
  });

  const mine: OwnDeal[] = [];
  for (const log of logs) {
    const a = log.args as { dealId: `0x${string}`; token: Address; principal: bigint };
    const dealId = BigInt(a.dealId);
    const mySubject = await dealSubject(skId, dealId);
    const [subjectH, subjectP] = (await client.readContract({
      address: escrow,
      abi: ESCROW_ABI,
      functionName: "subjects",
      args: [a.dealId],
    })) as [`0x${string}`, `0x${string}`];

    const side = BigInt(subjectH) === mySubject
      ? ("holder" as const)
      : BigInt(subjectP) === mySubject
        ? ("provider" as const)
        : null;
    if (side === null) continue;
    mine.push({ dealId, side, token: BigInt(a.token), principal: a.principal, subject: mySubject });
  }
  return mine;
}
