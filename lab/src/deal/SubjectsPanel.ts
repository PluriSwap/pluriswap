import { ZERO_BYTES32, type DealSnapshot } from "./types.ts";

export function renderSubjectsPanel(deal: DealSnapshot): string {
  const h = deal.subjects.holderSubject;
  const p = deal.subjects.providerSubject;
  const empty = h === ZERO_BYTES32 && p === ZERO_BYTES32;
  return `
    <section class="panel">
      <h2>subjects</h2>
      <p class="hint">Snapshot de Passport en activate. Core-only: <code>0x0</code>. No se etiquetan “humanos”.</p>
      <dl class="eip712">
        <dt>holderSubject</dt><dd><code>${h}</code></dd>
        <dt>providerSubject</dt><dd><code>${p}</code></dd>
      </dl>
      ${empty ? `<p class="muted">Sin Passport en este deal.</p>` : ""}
    </section>
  `;
}
