import { statusName, type DealSnapshot } from "./types.ts";

export function renderSettlementPanel(deal: DealSnapshot): string {
  const s = deal.settlement;
  return `
    <section class="panel">
      <h2>settlementOf</h2>
      <p class="hint">Terminales: <code>RELEASED</code> (release / co-sign / ZK), <code>CLAIMED</code> (timeout Provider-positivo), <code>RESOLVED_SPLIT</code>, <code>STALEMATE</code>, <code>CANCELLED</code>, <code>RESOLVED_BY_ARBITRATION</code>. Completion fee: sobre el pot total siempre que el Provider cobre algo; un refund nunca la paga. Línea de invoice: n/a hasta paquetes (PR-8).</p>
      <dl class="eip712">
        <dt>status</dt><dd><code>${statusName(s.status)}</code> (${s.status})</dd>
        <dt>holderAmt</dt><dd><code>${s.holderAmt.toString()}</code></dd>
        <dt>providerAmt</dt><dd><code>${s.providerAmt.toString()}</code></dd>
        <dt>invoice (completion / verify)</dt><dd><span class="muted">n/a hasta PR-8</span></dd>
      </dl>
    </section>
  `;
}
