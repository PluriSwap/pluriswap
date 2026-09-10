import { getAddress, isAddress } from "viem";
import type { HexAddress, HexBytes32 } from "../addressbook/types.ts";
import { isHexBytes32, type DealTerms } from "../deal/types.ts";
import type { Envelope } from "./eip712.ts";
import type { ConsentDraft } from "./ConsentPanel.ts";

export function parseIdOverride(raw: string): HexBytes32[] | null {
  const trimmed = raw.trim();
  if (!trimmed) return null;
  const parts = trimmed.split(/[\s,]+/).filter(Boolean);
  const ids: HexBytes32[] = [];
  for (const p of parts) {
    if (!isHexBytes32(p)) throw new Error(`packageId inválido: ${p}`);
    ids.push(p);
  }
  return ids;
}

export function parseDraft(d: ConsentDraft, packageIds: HexBytes32[] = []): {
  terms: DealTerms;
  ha: Envelope;
  pa: Envelope;
  ca: Envelope;
} {
  const need = [d.holder, d.controller, d.provider, d.token];
  for (const a of need) {
    if (!isAddress(a)) throw new Error(`address inválida: ${a || "(vacía)"}`);
  }
  const terms: DealTerms = {
    holder: getAddress(d.holder) as HexAddress,
    controller: getAddress(d.p2p ? d.holder : d.controller) as HexAddress,
    provider: getAddress(d.provider) as HexAddress,
    token: getAddress(d.token) as HexAddress,
    principal: BigInt(d.principal || "0"),
    fiatDuration: BigInt(d.fiatDuration || "0"),
    releaseDuration: BigInt(d.releaseDuration || "0"),
    disputeDuration: BigInt(d.disputeDuration || "0"),
    arbitrationDuration: BigInt(d.arbitrationDuration || "0"),
    packageIds,
  };
  const deadline = BigInt(d.deadline || "0");
  const ha: Envelope = { terms, nonce: BigInt(d.holderNonce || "0"), deadline };
  const pa: Envelope = { terms, nonce: BigInt(d.providerNonce || "0"), deadline };
  const ca: Envelope = { terms, nonce: BigInt(d.controllerNonce || "0"), deadline };
  return { terms, ha, pa, ca };
}
