import { deriveClocks } from "./clocks.ts";
import type { DealSnapshot } from "./types.ts";

export function renderClocksPanel(deal: DealSnapshot): string {
  const rows = deriveClocks(deal.clocks, deal.terms, deal.blockTimestamp);
  const c = deal.clocks;
  return `
    <section class="panel">
      <h2>Clocks</h2>
      <p class="hint">Orígenes snapshot. Deadlines = origin + duration. <code>duration = 0</code> ⇒ due inmediato <strong>y</strong> strictly-before ya <code>TooLate</code>. Origen 0 = reloj no arrancó.</p>
      <p class="muted">block.timestamp = <code>${deal.blockTimestamp.toString()}</code> · number <code>${deal.blockNumber.toString()}</code></p>
      <table class="grid">
        <thead>
          <tr>
            <th>reloj</th><th>origen</th><th>duration</th><th>deadline</th>
            <th>requireDue</th><th>requireStrictlyBefore</th>
          </tr>
        </thead>
        <tbody>
          ${rows
            .map((r) => {
              const originLabel = r.origin === 0n ? `<span class="muted">0 (no arrancó)</span>` : `<code>${r.origin.toString()}</code>`;
              const deadline = r.overflow
                ? `<span class="bad">overflow (timeout revertiría)</span>`
                : r.deadline === null
                  ? `<span class="muted">—</span>`
                  : `<code>${r.deadline.toString()}</code>`;
              const due =
                r.due === null ? "—" : r.due ? `<span class="ok">due (${r.dueVerb})</span>` : `<span class="muted">TooEarly</span>`;
              const before =
                r.strictlyBeforeVerb === "—"
                  ? `<span class="muted">—</span>`
                  : r.strictlyBefore === null
                    ? "—"
                    : r.strictlyBefore
                      ? `<span class="ok">open (${r.strictlyBeforeVerb})</span>`
                      : `<span class="bad">TooLate (${r.strictlyBeforeVerb})</span>`;
              const zeroNote = r.origin !== 0n && r.duration === 0n ? ` <span class="warn">duration=0</span>` : "";
              return `<tr>
                <td><code>${r.name}</code></td>
                <td>${r.originName} ${originLabel}</td>
                <td><code>${r.durationField}=${r.duration.toString()}</code>${zeroNote}</td>
                <td>${deadline}</td>
                <td>${due}</td>
                <td>${before}</td>
              </tr>`;
            })
            .join("")}
        </tbody>
      </table>
      <dl class="eip712">
        <dt>activatedAt</dt><dd><code>${c.activatedAt.toString()}</code></dd>
        <dt>fiatSentAt</dt><dd><code>${c.fiatSentAt.toString()}</code></dd>
        <dt>disputedAt</dt><dd><code>${c.disputedAt.toString()}</code></dd>
        <dt>arbitrationOpenedAt</dt><dd><code>${c.arbitrationOpenedAt.toString()}</code></dd>
      </dl>
    </section>
  `;
}
