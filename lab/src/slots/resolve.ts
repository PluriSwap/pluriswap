import type { HexBytes32 } from "../addressbook/types.ts";
import { PKG, isZeroAddress, type PackageMods } from "../deal/types.ts";
import { R, disabled, enabled, type Eval } from "../eligibility/errors.ts";
import { arbitrationId, bondsId, passportId, reputationId, sortUniqueIds, zkId } from "../packageid/hash.ts";
import type { LivePolicy, SlotRow } from "./types.ts";

const ORDER: (keyof PackageMods)[] = ["passport", "reputation", "bonds", "zk", "court"];

function has(ids: HexBytes32[], id: HexBytes32): boolean {
  const k = id.toLowerCase();
  return ids.some((x) => x.toLowerCase() === k);
}

export function recomputeId(slot: keyof PackageMods, policy: LivePolicy): HexBytes32 | null {
  if (slot === "passport" && policy.passport) return passportId(policy.passport.address);
  if (slot === "reputation" && policy.reputation?.feeRecipient != null && policy.reputation.activationFee != null && policy.reputation.completionFee != null) {
    return reputationId(
      policy.reputation.address,
      policy.reputation.feeRecipient,
      policy.reputation.activationFee,
      policy.reputation.completionFee,
    );
  }
  if (slot === "bonds" && policy.bonds?.sink) return bondsId(policy.bonds.address, policy.bonds.sink);
  if (slot === "zk" && policy.zk?.verifier && policy.zk.feeRecipient != null && policy.zk.verifyFee != null) {
    return zkId(policy.zk.address, policy.zk.verifier, policy.zk.feeRecipient, policy.zk.verifyFee);
  }
  if (slot === "court" && policy.court?.partner != null && policy.court.key != null) {
    return arbitrationId(policy.court.address, policy.court.partner, policy.court.key);
  }
  return null;
}

export function slotRows(mods: PackageMods, ids: HexBytes32[], policy: LivePolicy, recinto: string): SlotRow[] {
  return ORDER.map((slot) => {
    const address = isZeroAddress(mods[slot]) ? null : mods[slot];
    const id = address ? recomputeId(slot, policy) : null;
    const lab =
      slot === "passport" ||
      slot === "zk" ||
      (slot === "court" && Boolean(policy.court?.operator));
    let getter: SlotRow["getter"] = "none";
    let boundTo: SlotRow["boundTo"] = null;
    if (slot === "reputation") {
      getter = "operator";
      boundTo = policy.reputation?.operator ?? null;
    } else if (slot === "bonds") {
      getter = "operator";
      boundTo = policy.bonds?.operator ?? null;
    } else if (slot === "zk") {
      getter = "operator";
      boundTo = policy.zk?.operator ?? null;
    } else if (slot === "court") {
      if (policy.court?.kernel) {
        getter = "kernel";
        boundTo = policy.court.kernel;
      } else if (policy.court?.operator) {
        getter = "operator";
        boundTo = policy.court.operator;
      }
    }
    const peerPassport =
      slot === "reputation" ? (policy.reputation?.passport ?? null) : slot === "bonds" ? (policy.bonds?.passport ?? null) : null;
    const peerOk =
      peerPassport === null || !mods.passport
        ? null
        : peerPassport.toLowerCase() === mods.passport.toLowerCase();
    return {
      slot,
      address,
      id,
      inIds: id ? has(ids, id) : null,
      peerPassport,
      peerOk,
      getter,
      boundTo,
      matchesRecinto: boundTo ? boundTo.toLowerCase() === recinto.toLowerCase() : null,
      lab,
      note: lab ? "LAB adapter" : "",
    };
  });
}

/** Escrow._resolve first-revert, slot order passport → reputation → bonds → zk → court. */
export function firstResolveRevert(ids: HexBytes32[], mods: PackageMods, policy: LivePolicy): Eval {
  let matched = 0;
  let pkgs = 0;

  if (!isZeroAddress(mods.passport)) {
    const id = recomputeId("passport", policy);
    if (!id || !has(ids, id)) return disabled(R.UnknownPackage);
    pkgs |= PKG.PASSPORT;
    matched++;
  }
  if (!isZeroAddress(mods.reputation)) {
    const peer = policy.reputation?.passport;
    if (peer && peer.toLowerCase() !== mods.passport.toLowerCase()) return disabled(R.PeerMismatch);
    const id = recomputeId("reputation", policy);
    if (!id || !has(ids, id)) return disabled(R.UnknownPackage);
    pkgs |= PKG.REP;
    matched++;
  }
  if (!isZeroAddress(mods.bonds)) {
    const peer = policy.bonds?.passport;
    if (peer && peer.toLowerCase() !== mods.passport.toLowerCase()) return disabled(R.PeerMismatch);
    const id = recomputeId("bonds", policy);
    if (!id || !has(ids, id)) return disabled(R.UnknownPackage);
    pkgs |= PKG.BONDS;
    matched++;
  }
  if (!isZeroAddress(mods.zk)) {
    const id = recomputeId("zk", policy);
    if (!id || !has(ids, id)) return disabled(R.UnknownPackage);
    pkgs |= PKG.ZK;
    matched++;
  }
  if (!isZeroAddress(mods.court)) {
    const id = recomputeId("court", policy);
    if (!id || !has(ids, id)) return disabled(R.UnknownPackage);
    pkgs |= PKG.ARB;
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

export function computedIds(mods: PackageMods, policy: LivePolicy): HexBytes32[] {
  const ids: HexBytes32[] = [];
  for (const slot of ORDER) {
    if (isZeroAddress(mods[slot])) continue;
    const id = recomputeId(slot, policy);
    if (id) ids.push(id);
  }
  return sortUniqueIds(ids);
}

export function firstEngageRevert(mods: PackageMods, policy: LivePolicy): Eval {
  if (!isZeroAddress(mods.passport)) {
    if (policy.identifyError) return disabled(policy.identifyError);
    if (!policy.identifyHolder || !policy.identifyProvider) {
      return disabled("IPassport.NoPassport");
    }
  }
  return enabled();
}
