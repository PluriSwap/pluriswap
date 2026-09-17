import type { HexAddress, HexBytes32 } from "../addressbook/types.ts";
import { ZERO_ADDRESS, type PackageMods } from "../deal/types.ts";

export type ModsDraft = {
  passport: string;
  reputation: string;
  bonds: string;
  zk: string;
  court: string;
};

export const emptyModsDraft = (): ModsDraft => ({
  passport: "",
  reputation: "",
  bonds: "",
  zk: "",
  court: "",
});

export const ZERO_MODS: PackageMods = {
  passport: ZERO_ADDRESS,
  reputation: ZERO_ADDRESS,
  bonds: ZERO_ADDRESS,
  zk: ZERO_ADDRESS,
  court: ZERO_ADDRESS,
};

export function modsEmpty(m: PackageMods): boolean {
  return (
    m.passport === ZERO_ADDRESS &&
    m.reputation === ZERO_ADDRESS &&
    m.bonds === ZERO_ADDRESS &&
    m.zk === ZERO_ADDRESS &&
    m.court === ZERO_ADDRESS
  );
}

export type SlotRow = {
  slot: keyof PackageMods;
  address: HexAddress | null;
  id: HexBytes32 | null;
  inIds: boolean | null;
  peerPassport: HexAddress | null;
  peerOk: boolean | null;
  getter: "operator" | "kernel" | "none";
  boundTo: HexAddress | null;
  matchesRecinto: boolean | null;
  lab: boolean;
  note: string;
};

export type LivePolicy = {
  passport: { address: HexAddress } | null;
  reputation: {
    address: HexAddress;
    passport: HexAddress | null;
    feeRecipient: HexAddress | null;
    activationFee: bigint | null;
    completionFee: bigint | null;
    contestFee: bigint | null;
    operator: HexAddress | null;
  } | null;
  bonds: {
    address: HexAddress;
    passport: HexAddress | null;
    sink: HexAddress | null;
    operator: HexAddress | null;
  } | null;
  zk: {
    address: HexAddress;
    verifier: HexAddress | null;
    feeRecipient: HexAddress | null;
    verifyFee: bigint | null;
    operator: HexAddress | null;
  } | null;
  court: {
    address: HexAddress;
    partner: HexAddress | null;
    key: bigint | null;
    operator: HexAddress | null;
    kernel: HexAddress | null;
    extraData: `0x${string}` | null;
  } | null;
  identifyHolder: HexBytes32 | null;
  identifyProvider: HexBytes32 | null;
  identifyError: string | null;
};

export const emptyPolicy = (): LivePolicy => ({
  passport: null,
  reputation: null,
  bonds: null,
  zk: null,
  court: null,
  identifyHolder: null,
  identifyProvider: null,
  identifyError: null,
});
