import { decodeKinds, modulesPresent } from "./kinds.ts";
import { isZeroAddress, type DealSnapshot, type ModuleBinding } from "./types.ts";

export function renderKindsPanel(deal: DealSnapshot, bindings: ModuleBinding[]): string {
  const flags = decodeKinds(deal.kinds);
  const m = deal.modules;
  const slots: { name: keyof typeof m; addr: string }[] = [
    { name: "passport", addr: m.passport },
    { name: "reputation", addr: m.reputation },
    { name: "bonds", addr: m.bonds },
    { name: "zk", addr: m.zk },
    { name: "court", addr: m.court },
  ];
  const bindRows = bindings
    .map((b) => {
      const match =
        b.matchesRecinto === true
          ? `<span class="ok">${b.getter}() = Recinto</span>`
          : b.matchesRecinto === false
            ? `<span class="bad">${b.getter}() = ${b.boundTo} ≠ Recinto</span>`
            : `<span class="muted">${b.getter === "none" ? "sin operator/kernel" : "n/a"}</span>`;
      return `<tr><td><code>${b.slot}</code></td><td><code>${b.address}</code></td><td>${match}</td></tr>`;
    })
    .join("");

  return `
    <section class="panel">
      <h2>kinds / modules</h2>
      <p class="hint">Bitmap snapshot. Core-only = 0 y slots nulos. Binding <code>operator</code>/<code>kernel</code> no entra al packageId.</p>
      <p>${flags.map((f) => `<span class="chip${f.on ? " is-on" : ""}">${f.name} ${f.bit}</span>`).join(" ")}</p>
      <p>kinds = <code>${deal.kinds}</code></p>
      <table class="grid">
        <thead><tr><th>slot</th><th>address (snapshot)</th></tr></thead>
        <tbody>
          ${slots
            .map(
              (s) =>
                `<tr><td><code>${s.name}</code></td><td>${
                  isZeroAddress(s.addr) ? `<span class="muted">0x0</span>` : `<code>${s.addr}</code>`
                }</td></tr>`,
            )
            .join("")}
        </tbody>
      </table>
      ${
        modulesPresent(m).length
          ? `<h3>binding vs Recinto</h3>
             <table class="grid"><thead><tr><th>slot</th><th>módulo</th><th>getter</th></tr></thead><tbody>${bindRows}</tbody></table>`
          : `<p class="muted">Sin módulos snapshot: no hay operator/kernel que comparar.</p>`
      }
    </section>
  `;
}
