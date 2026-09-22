import type { HexAddress, HexBytes32 } from "../addressbook/types.ts";

/**
 * Types.sol Status. CLAIMED (10) is the Provider-positive timeout terminal, distinct from RELEASED.
 * ABANDONED (11) is the other one: the Controller opened a fight and let it expire, so the Provider
 * takes the principal in full (§3.11 OUT-14). It is not a STALEMATE — that name is now reserved for
 * the two terminals where nobody abandoned anything, a tribunal that refused and one that never
 * answered, and both of those are still 50/50.
 */
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
  "CLAIMED",
  "ABANDONED",
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
  CLAIMED: 10,
  ABANDONED: 11,
} as const;

export const PKG = {
  PASSPORT: 1,
  REP: 2,
  BONDS: 4,
  ZK: 8,
  ARB: 16,
} as const;

/** `Packages.POST_*` bits of `Escrow.postPending`. */
export const POST = {
  NOTIFY_H: 0x01,
  NOTIFY_P: 0x02,
  BOND_A: 0x04,
  BOND_B: 0x08,
} as const;

const POST_LABELS: { bit: number; label: string }[] = [
  { bit: POST.NOTIFY_H, label: "notify-H" },
  { bit: POST.NOTIFY_P, label: "notify-P" },
  { bit: POST.BOND_A, label: "bond-A" },
  { bit: POST.BOND_B, label: "bond-B" },
];

export function isTerminalStatus(status: number): boolean {
  return (
    status === Status.RELEASED ||
    status === Status.RESOLVED_SPLIT ||
    status === Status.STALEMATE ||
    status === Status.CANCELLED ||
    status === Status.RESOLVED_BY_ARBITRATION ||
    status === Status.CLAIMED ||
    status === Status.ABANDONED
  );
}

export function postPendingChips(pending: number): string[] {
  return POST_LABELS.filter((row) => (pending & row.bit) !== 0).map((row) => row.label);
}

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
  /** Escrow-only keeper surface, not `IEscrow`. Zero once every post-terminal call succeeded or was abandoned. */
  postPending: number;
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
