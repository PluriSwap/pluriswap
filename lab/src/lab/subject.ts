import { keccak256, toHex } from "viem";
import type { HexBytes32 } from "../addressbook/types.ts";

/** Sujeto de laboratorio: keccak256 de un string. Elegido por el operador, nunca un nombre de persona. */
export function packageIdSubjectHint(seed: string): HexBytes32 {
  return keccak256(toHex(seed || `subject-${Date.now()}`)) as HexBytes32;
}
