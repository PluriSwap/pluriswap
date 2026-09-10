import { PKG, isZeroAddress, type PackageMods } from "./types.ts";

export type KindFlag = { bit: number; name: string; on: boolean };

export function decodeKinds(kinds: number): KindFlag[] {
  return [
    { bit: PKG.PASSPORT, name: "PASSPORT", on: (kinds & PKG.PASSPORT) !== 0 },
    { bit: PKG.REP, name: "REPUTATION", on: (kinds & PKG.REP) !== 0 },
    { bit: PKG.BONDS, name: "BONDS", on: (kinds & PKG.BONDS) !== 0 },
    { bit: PKG.ZK, name: "ZK", on: (kinds & PKG.ZK) !== 0 },
    { bit: PKG.ARB, name: "ARBITRATION", on: (kinds & PKG.ARB) !== 0 },
  ];
}

export function modulesPresent(mods: PackageMods): (keyof PackageMods)[] {
  return (["passport", "reputation", "bonds", "zk", "court"] as const).filter(
    (slot) => !isZeroAddress(mods[slot]),
  );
}
