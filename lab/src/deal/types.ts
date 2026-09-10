import type { HexAddress, HexBytes32 } from "../addressbook/types.ts";

/** Types.sol Status. CLAIMED is not a member. */
export const STATUS_NAMES = [
  "NONE",
  "FUNDED",
  "FIAT_SENT",
  "DISPUTED",
  "RELEASED",
  "RESOLVED_SPLIT",
  "STALEMATE",
  "CANCELLED",
  "ARBITRATION_ACTIVE",
  "RESOLVED_BY_ARBITRATION",
] as const;

export type StatusName = (typeof STATUS_NAMES)[number];

export const Status = {
  NONE: 0,
  FUNDED: 1,
  FIAT_SENT: 2,
  DISPUTED: 3,
  RELEASED: 4,
  RESOLVED_SPLIT: 5,
  STALEMATE: 6,
  CANCELLED: 7,
  ARBITRATION_ACTIVE: 8,
  RESOLVED_BY_ARBITRATION: 9,
} as const;

export const PKG = {
  PASSPORT: 1,
  REP: 2,
  BONDS: 4,
  ZK: 8,
  ARB: 16,
} as const;

export type DealTerms = {
  holder: HexAddress;
  controller: HexAddress;
  provider: HexAddress;
  token: HexAddress;
  principal: bigint;
  fiatDuration: bigint;
  releaseDuration: bigint;
  disputeDuration: bigint;
  arbitrationDuration: bigint;
  packageIds: HexBytes32[];
};

export type DealClocks = {
  activatedAt: bigint;
  fiatSentAt: bigint;
  disputedAt: bigint;
  arbitrationOpenedAt: bigint;
};

export type PackageMods = {
  passport: HexAddress;
  reputation: HexAddress;
  bonds: HexAddress;
  zk: HexAddress;
  court: HexAddress;
};

export type DealSnapshot = {
  dealId: HexBytes32;
  status: number;
  terms: DealTerms;
  clocks: DealClocks;
  subjects: { holderSubject: HexBytes32; providerSubject: HexBytes32 };
  modules: PackageMods;
  kinds: number;
  settlement: { status: number; holderAmt: bigint; providerAmt: bigint };
  blockTimestamp: bigint;
  blockNumber: bigint;
};

export type ModuleBinding = {
  slot: keyof PackageMods;
  address: HexAddress;
  getter: "operator" | "kernel" | "none";
  boundTo: HexAddress | null;
  matchesRecinto: boolean | null;
};

export type ClockRow = {
  name: string;
  originName: keyof DealClocks;
  origin: bigint;
  duration: bigint;
  durationField: string;
  deadline: bigint | null;
  overflow: boolean;
  due: boolean | null;
  strictlyBefore: boolean | null;
  dueVerb: string;
  strictlyBeforeVerb: string;
};

export const ZERO_BYTES32 =
  "0x0000000000000000000000000000000000000000000000000000000000000000" as HexBytes32;
export const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000" as HexAddress;

export function statusName(status: number): string {
  return STATUS_NAMES[status] ?? `unknown(${status})`;
}

export function isHexBytes32(value: string): value is HexBytes32 {
  return /^0x[0-9a-fA-F]{64}$/.test(value);
}

export function isZeroAddress(addr: string): boolean {
  return /^0x0{40}$/i.test(addr);
}
