import type { MatrixRow } from "../eligibility/matrix.ts";

export function renderMatrixPanel(
  rows: MatrixRow[],
  senderLabel: string,
  opts: { coreWrites: boolean; nonce: string; dualSign?: boolean },
): string {
  const body = rows
    .map((row) => {
      const st = row.eval.enabled
        ? `<span class="ok">ENABLED</span>`
        : `<span class="${row.eval.reasonKind === "ui-policy" ? "warn" : "bad"}">DISABLED: <code>${escapeHtml(row.eval.reason)}</code></span>`;
      const dualVerb = ["mutualCancel", "coSignedRelease", "mutualSplit"].includes(row.verb);
      const sendable =
        row.eval.enabled &&
        ((opts.coreWrites &&
          [
            "markFiat",
            "cancelByProvider",
            "timeoutFiat",
            "release",
            "claim",
            "openDisputed",
            "forceStalemate",
            "withdraw",
            "cancelNonce",
          ].includes(row.verb)) ||
          (Boolean(opts.dualSign) && dualVerb));
      const send = sendable
        ? `<button type="button" data-verb="${row.verb}">Enviar</button>`
        : "";
      return `<tr>
        <td><code>${row.verb}</code></td>
        <td>${row.class}</td>
        <td><code>${row.requiredStatus}</code></td>
        <td>${row.kinds}</td>
        <td>${row.clock}</td>
        <td>${row.senderSeat}</td>
        <td>${st} ${send}</td>
      </tr>`;
    })
    .join("");
  return `
    <section class="panel">
      <h2>Matriz de elegibilidad</h2>
      <p class="hint">Todos los verbos de <code>Escrow.sol</code> visibles. DISABLED = primer revert. Enviar usa el asiento activo (${escapeHtml(senderLabel)}). Dual-sign = PR-6. Filas ilegales no se ocultan.</p>
      <p>
        <label class="inline"><input type="checkbox" id="coreWrites" ${opts.coreWrites ? "checked" : ""}/> coreWrites</label>
        <label class="inline">cancelNonce <input id="cancelNonce" spellcheck="false" value="${escapeHtml(opts.nonce)}" placeholder="uint256" /></label>
      </p>
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
