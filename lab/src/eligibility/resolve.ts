import { PKG } from "../deal/types.ts";
import { R, disabled, enabled, type Eval } from "./errors.ts";

export type ResolveSlot = {
  kind: "passport" | "reputation" | "bonds" | "zk" | "court";
  bit: number;
  address: string | null;
  id: string | null;
  peerOk: boolean;
};

/**
 * Escrow._resolve order: per slot passport→rep→bonds→zk→court,
 * PeerMismatch then UnknownPackage per slot; then matched != length → UnknownPackage;
 * then IncompatiblePackages; then PackageRequired.
 */
export function firstResolveRevert(packageIds: string[], slots: ResolveSlot[]): Eval {
  const ids = packageIds.map((id) => id.toLowerCase());
  let matched = 0;
  let pkgs = 0;
  const order: ResolveSlot["kind"][] = ["passport", "reputation", "bonds", "zk", "court"];
  for (const kind of order) {
    const slot = slots.find((s) => s.kind === kind);
    if (!slot?.address) continue;
    if ((kind === "reputation" || kind === "bonds") && !slot.peerOk) {
      return disabled(R.PeerMismatch);
    }
    if (!slot.id || !ids.includes(slot.id.toLowerCase())) return disabled(R.UnknownPackage);
    pkgs |= slot.bit;
    matched++;
  }
  if (matched !== ids.length) return disabled(R.UnknownPackage);
  if ((pkgs & (PKG.ZK | PKG.ARB)) === (PKG.ZK | PKG.ARB)) return disabled(R.IncompatiblePackages);
  if ((pkgs & PKG.REP) !== 0 && (pkgs & PKG.PASSPORT) === 0) return disabled(R.PackageRequired);
  if ((pkgs & PKG.BONDS) !== 0 && (pkgs & (PKG.PASSPORT | PKG.REP)) !== (PKG.PASSPORT | PKG.REP)) {
    return disabled(R.PackageRequired);
  }
  return enabled();
}
