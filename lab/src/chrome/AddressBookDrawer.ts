import type { AddressSet } from "../addressbook/types.ts";

export function renderAddressBook(root: HTMLElement, sets: AddressSet[], onUseEscrow: (set: AddressSet) => void): void {
  const recintoSets = sets.filter((s) => s.isRecinto);
  const aux = sets.filter((s) => !s.isRecinto);

  root.innerHTML = `
    <header>
      <h2>AddressBook</h2>
      <p class="hint">Atajo, no gate. Cada archivo es un <em>set</em> bound a su <code>escrow</code> si lo tiene. <code>testToken</code> no se fusiona entre archivos.</p>
    </header>
    <h3>Sets con Recinto</h3>
    ${recintoSets.map((s) => renderSet(s, true)).join("") || `<p class="muted">Ninguno.</p>`}
    <h3>Sets auxiliares (no son Recinto)</h3>
    <p class="hint"><code>sepolia-kleros.json</code> es un dispute live. <code>*-pool-factory.json</code> es factory + <code>officialCodehash</code>.</p>
    ${aux.map((s) => renderSet(s, false)).join("") || `<p class="muted">Ninguno.</p>`}
  `;

  root.querySelectorAll<HTMLButtonElement>("[data-use]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const file = btn.dataset.use;
      const set = sets.find((s) => s.sourceFile === file);
      if (set?.escrow) onUseEscrow(set);
    });
  });
}

function renderSet(set: AddressSet, canFocus: boolean): string {
  const rows = [
    set.chainId !== null ? `<tr><th>chainId</th><td><code>${set.chainId}</code></td></tr>` : "",
    set.escrow ? `<tr><th>escrow</th><td><code>${set.escrow}</code></td></tr>` : `<tr><th>escrow</th><td class="muted">ausente → no Recinto</td></tr>`,
    `<tr><th>testToken</th><td>${set.testToken ? `<code>${set.testToken}</code>` : `<span class="muted">— (este archivo)</span>`}</td></tr>`,
    ...Object.entries(set.labels).map(
      ([k, v]) => `<tr><th><code>${escapeHtml(k)}</code></th><td><code>${escapeHtml(v)}</code></td></tr>`,
    ),
  ].join("");
  const use = canFocus && set.escrow
    ? `<button type="button" data-use="${escapeHtml(set.sourceFile)}">Usar este escrow (atajo)</button>`
    : "";
  return `<section class="set">
    <header>
      <code>${escapeHtml(set.sourceFile)}</code>
      ${use}
    </header>
    <table>${rows}</table>
  </section>`;
}

function escapeHtml(value: string): string {
  return value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
}
