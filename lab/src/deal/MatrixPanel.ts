import type { MatrixRow } from "../eligibility/matrix.ts";

export function renderMatrixPanel(rows: MatrixRow[], senderLabel: string): string {
  const body = rows
    .map((row) => {
      const st = row.eval.enabled
        ? `<span class="ok">ENABLED</span>`
        : `<span class="${row.eval.reasonKind === "ui-policy" ? "warn" : "bad"}">DISABLED: <code>${escapeHtml(row.eval.reason)}</code></span>`;
      return `<tr>
        <td><code>${row.verb}</code></td>
        <td>${row.class}</td>
        <td><code>${row.requiredStatus}</code></td>
        <td>${row.kinds}</td>
        <td>${row.clock}</td>
        <td>${row.senderSeat}</td>
        <td>${st}</td>
      </tr>`;
    })
    .join("");
  return `
    <section class="panel">
      <h2>Matriz de elegibilidad</h2>
      <p class="hint">Todos los verbos de <code>Escrow.sol</code> visibles. DISABLED = primer revert del bytecode, o <code>ui-policy</code> (<code>draft-empty</code>, <code>no-op</code>, <code>no-sender</code>). Asiento activo = <code>msg.sender</code> (${escapeHtml(senderLabel)}). Dual-sign sin composer (PR-6) = <code>draft-empty</code>. CASE-CORE-16/17 no se ocultan.</p>
      <table class="grid matrix">
        <thead>
          <tr>
            <th>verbo</th><th>clase</th><th>status</th><th>kinds</th><th>reloj</th><th>sender</th><th>oráculo</th>
          </tr>
        </thead>
        <tbody>${body}</tbody>
      </table>
    </section>
  `;
}

function escapeHtml(value: string): string {
  return value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
}
