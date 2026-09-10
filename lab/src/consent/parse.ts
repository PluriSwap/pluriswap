import { getAddress, isAddress } from "viem";
import type { HexAddress } from "../addressbook/types.ts";
import { type DealTerms } from "../deal/types.ts";
import type { Envelope } from "./eip712.ts";
import type { ConsentDraft } from "./ConsentPanel.ts";

export function parseDraft(d: ConsentDraft): { terms: DealTerms; ha: Envelope; pa: Envelope } {
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
    packageIds: [],
  };
  const deadline = BigInt(d.deadline || "0");
  const ha: Envelope = { terms, nonce: BigInt(d.holderNonce || "0"), deadline };
  const pa: Envelope = { terms, nonce: BigInt(d.providerNonce || "0"), deadline };
  return { terms, ha, pa };
}
