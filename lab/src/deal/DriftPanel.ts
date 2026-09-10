import type { HexBytes32 } from "../addressbook/types.ts";
import { isZeroAddress, type DealSnapshot } from "./types.ts";

export type DriftRow = {
  slot: string;
  liveId: HexBytes32 | null;
  inSigned: boolean;
};

export function renderDriftPanel(deal: DealSnapshot, rows: DriftRow[]): string {
  if (deal.terms.packageIds.length === 0) {
    return `<section class="panel"><h2>Drift / KERNEL-04</h2><p class="muted">Core-only: no hay ids que derivar.</p></section>`;
  }
  const drifted = rows.some((r) => r.liveId !== null && !r.inSigned);
  const body = rows
    .map((r) => {
      const st =
        r.liveId === null
          ? "—"
          : r.inSigned
            ? `<span class="ok">match</span>`
            : `<span class="bad">DRIFT</span>`;
      return `<tr><td><code>${r.slot}</code></td><td><code>${r.liveId ?? "—"}</code></td><td>${st}</td></tr>`;
    })
    .join("");
  return `
    <section class="panel">
      <h2>Drift / KERNEL-04</h2>
      <p class="hint">TRUST-03: el id vivo debe seguir en <code>packageIds</code>. Drift <strong>no</strong> congela salidas Core. Invoice de Rep drifted se omite (KERNEL-04). Bonds drifted: lock puede quedar en el vault.</p>
      ${drifted ? `<p class="warn">DRIFT — Core exits siguen. Invoice omitido (KERNEL-04) si Rep drifted.</p>` : `<p class="ok">ids vivos ∈ packageIds</p>`}
      <table class="grid">
        <thead><tr><th>slot</th><th>id vivo</th><th></th></tr></thead>
        <tbody>${body}</tbody>
      </table>
      <p class="muted">signed: ${deal.terms.packageIds.map((id) => `<code>${id}</code>`).join(" ")}</p>
      ${isZeroAddress(deal.modules.zk) ? "" : `<p class="hint">Deal ZK: <code>markFiat</code>/<code>claim</code>/<code>openDisputed</code>/<code>openCourt</code> = EdgeOff o PackageNotSelected. Siguen timeoutFiat, cancelByProvider, mutualCancel, verifyProof.</p>`}
    </section>
  `;
}
