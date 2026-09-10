import { R, disabled, enabled, type Eval } from "./errors.ts";
import type { DealTerms } from "../deal/types.ts";

/** Terms.hashTerms checks, in bytecode order, before any Escrow.TermsMismatch. */
export function firstTermsRevert(t: DealTerms): Eval {
  if (t.holder.toLowerCase() === t.provider.toLowerCase()) {
    return disabled(R.HolderEqualsProvider);
  }
  if (t.principal === 0n) return disabled(R.ZeroPrincipal);
  for (let i = 1; i < t.packageIds.length; i++) {
    if (t.packageIds[i]!.toLowerCase() <= t.packageIds[i - 1]!.toLowerCase()) {
      return disabled(R.UnsortedPackageIds);
    }
  }
  return enabled();
}
