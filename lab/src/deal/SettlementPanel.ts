import { statusName, type DealSnapshot } from "./types.ts";

export function renderSettlementPanel(deal: DealSnapshot): string {
  const s = deal.settlement;
  return `
    <section class="panel">
      <h2>settlementOf</h2>
      <p class="hint"><code>CLAIMED</code> no es un <code>Status</code>. CASE-CORE-06 release y CASE-CORE-07 claim comparten <code>RELEASED</code> y no se distinguen en este record. Claim omite completion fee; release no. Línea de invoice: n/a hasta paquetes (PR-8).</p>
      <dl class="eip712">
        <dt>status</dt><dd><code>${statusName(s.status)}</code> (${s.status})</dd>
        <dt>holderAmt</dt><dd><code>${s.holderAmt.toString()}</code></dd>
        <dt>providerAmt</dt><dd><code>${s.providerAmt.toString()}</code></dd>
        <dt>invoice (completion / verify)</dt><dd><span class="muted">n/a hasta PR-8</span></dd>
      </dl>
    </section>
  `;
}
