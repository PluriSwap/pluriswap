import { encodeAbiParameters, keccak256, toHex, type Address, type Hex } from "viem";
import type { HexAddress, HexBytes32 } from "../addressbook/types.ts";

/** Same strings as `src/libraries/PackageId.sol`. Not an allowlist. */
export const KIND = {
  BONDS: keccak256(toHex("PluriSwap.Package.BONDS")),
  PASSPORT: keccak256(toHex("PluriSwap.Package.PASSPORT")),
  REPUTATION: keccak256(toHex("PluriSwap.Package.REPUTATION")),
  ARBITRATION: keccak256(toHex("PluriSwap.Package.ARBITRATION")),
  ZK: keccak256(toHex("PluriSwap.Package.ZK")),
} as const;

export const BOND_LOCK_BPS = 1000;

export function passportId(adapter: HexAddress): HexBytes32 {
  return keccak256(
    encodeAbiParameters(
      [{ type: "bytes32" }, { type: "address" }],
      [KIND.PASSPORT, adapter as Address],
    ),
  ) as HexBytes32;
}

export function reputationId(
  module: HexAddress,
  feeRecipient: HexAddress,
  activationFee: bigint,
  completionFee: bigint,
  contestBps: bigint,
  contestFloor: bigint,
): HexBytes32 {
  return keccak256(
    encodeAbiParameters(
      [
        { type: "bytes32" },
        { type: "address" },
        { type: "address" },
        { type: "uint256" },
        { type: "uint256" },
        { type: "uint256" },
        { type: "uint256" },
      ],
      [KIND.REPUTATION, module as Address, feeRecipient as Address, activationFee, completionFee, contestBps, contestFloor],
    ),
  ) as HexBytes32;
}

/** Same formula as `Packages.contestDue`. Zero bps is a flat floor. */
export function contestDue(principal: bigint, bps: bigint, floor: bigint): bigint {
  if (bps === 0n) return floor;
  const pct = (principal * bps) / 10_000n;
  return pct < floor ? floor : pct;
}

export function bondsId(vault: HexAddress, sink: HexAddress): HexBytes32 {
  return keccak256(
    encodeAbiParameters(
      [{ type: "bytes32" }, { type: "address" }, { type: "address" }, { type: "uint16" }],
      [KIND.BONDS, vault as Address, sink as Address, BOND_LOCK_BPS],
    ),
  ) as HexBytes32;
}

export function arbitrationId(adapter: HexAddress, tribunal: HexAddress, courtFee: bigint): HexBytes32 {
  return keccak256(
    encodeAbiParameters(
      [{ type: "bytes32" }, { type: "address" }, { type: "address" }, { type: "uint256" }],
      [KIND.ARBITRATION, adapter as Address, tribunal as Address, courtFee],
    ),
  ) as HexBytes32;
}

/** Same kind as arbitration. Third word is keccak(extraData). */
export function klerosId(adapter: HexAddress, arbitrator: HexAddress, extraData: Hex): HexBytes32 {
  return arbitrationId(adapter, arbitrator, BigInt(keccak256(extraData)));
}

export function zkId(
  module: HexAddress,
  verifier: HexAddress,
  feeRecipient: HexAddress,
  verifyFee: bigint,
): HexBytes32 {
  return keccak256(
    encodeAbiParameters(
      [
        { type: "bytes32" },
        { type: "address" },
        { type: "address" },
        { type: "address" },
        { type: "uint256" },
      ],
      [KIND.ZK, module as Address, verifier as Address, feeRecipient as Address, verifyFee],
    ),
  ) as HexBytes32;
}

export function bondLock(principal: bigint): bigint {
  return (principal + 9n) / 10n;
}

export function sortUniqueIds(ids: HexBytes32[]): HexBytes32[] {
  const seen = new Set<string>();
  const out: HexBytes32[] = [];
  for (const id of ids) {
    const k = id.toLowerCase();
    if (seen.has(k)) continue;
    seen.add(k);
    out.push(id);
  }
  out.sort((a, b) => (a.toLowerCase() < b.toLowerCase() ? -1 : a.toLowerCase() > b.toLowerCase() ? 1 : 0));
  return out;
}
