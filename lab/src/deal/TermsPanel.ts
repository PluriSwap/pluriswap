import { isZeroAddress, statusName, type DealSnapshot } from "./types.ts";

export function renderTermsPanel(deal: DealSnapshot): string {
  const t = deal.terms;
  const coreOnly = t.packageIds.length === 0;
  const p2p = t.holder.toLowerCase() === t.controller.toLowerCase();
  return `
    <section class="panel">
      <h2>DealTerms</h2>
      <p class="hint">Firmado. Fees y addresses de módulo no están aquí.</p>
      <p>
        ${coreOnly ? `<span class="chip">Core-only</span>` : `<span class="chip">packageIds ${t.packageIds.length}</span>`}
        ${p2p ? `<span class="chip">Holder=Controller</span>` : `<span class="chip">Controller distinto</span>`}
        <span class="chip"><code>${statusName(deal.status)}</code></span>
      </p>
      <dl class="eip712">
        <dt>holder</dt><dd><code>${t.holder}</code></dd>
        <dt>controller</dt><dd><code>${t.controller}</code></dd>
        <dt>provider</dt><dd><code>${t.provider}</code></dd>
        <dt>token</dt><dd><code>${t.token}</code></dd>
        <dt>principal</dt><dd><code>${t.principal.toString()}</code></dd>
        <dt>fiatDuration</dt><dd><code>${t.fiatDuration.toString()}</code></dd>
        <dt>releaseDuration</dt><dd><code>${t.releaseDuration.toString()}</code></dd>
        <dt>disputeDuration</dt><dd><code>${t.disputeDuration.toString()}</code></dd>
        <dt>arbitrationDuration</dt><dd><code>${t.arbitrationDuration.toString()}</code>${coreOnly ? ` <span class="muted">ignorado si ARBITRATION off</span>` : ""}</dd>
        <dt>packageIds</dt><dd>${
          coreOnly
            ? `<span class="muted">[]</span>`
            : t.packageIds.map((id) => `<code>${id}</code>`).join("<br>")
        }</dd>
      </dl>
      ${isZeroAddress(t.token) ? `<p class="warn">token es address(0)</p>` : ""}
    </section>
  `;
}
