export type HexAddress = `0x${string}`;
export type HexBytes32 = `0x${string}`;

export const ROLES = ["Holder", "Provider", "Controller", "Relayer"] as const;
export type Role = (typeof ROLES)[number];

/** One deployments/*.json file. Identity includes the file so testToken is never merged. */
export type AddressSet = {
  sourceFile: string;
  chainId: number | null;
  /** Present iff the JSON has an `escrow` address. Auxiliary files omit this. */
  escrow: HexAddress | null;
  isRecinto: boolean;
  testToken: HexAddress | null;
  /** Every other JSON field, stringified. No secrets. */
  labels: Record<string, string>;
};

/** Recinto key = (chainId, escrow). Several JSON files may share it. */
export type RecintoRow = {
  chainId: number;
  escrow: HexAddress;
  sources: string[];
  testTokens: { sourceFile: string; token: HexAddress }[];
};

export type SeatState = {
  role: Role;
  /** Session paste only. Never persisted. */
  address: string | null;
  /** Session only. Never written to AddressBook or localStorage. */
  pk: string | null;
};

export const DEFAULT_RPC: Record<number, string> = {
  421614: "https://sepolia-rollup.arbitrum.io/rpc",
  31337: "http://127.0.0.1:8545",
};

export const EIP712_NAME = "PluriSwap";
export const EIP712_VERSION = "1";
