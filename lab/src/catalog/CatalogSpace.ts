import type { PathNeed, PathTemplate } from "./paths.ts";

export function renderCatalogSpace(
  root: HTMLElement,
  model: {
    paths: PathTemplate[];
    flags: Record<PathNeed, boolean>;
  },
  on: { start: (id: string) => void },
): void {
  const rows = model.paths
    .map((p) => {
      const blocked = p.needs.filter((n) => n !== "core" && !model.flags[n]);
      const disabled = blocked.length > 0;
      const why = disabled ? `flag ${blocked.join(", ")} off` : "";
      return `<tr>
        <td><code>${p.id}</code></td>
        <td><code>(${p.fiatDuration}, ${p.releaseDuration}, ${p.disputeDuration}, ${p.arbitrationDuration})</code></td>
        <td>${p.p2p ? "P2P" : "CTRL"}</td>
        <td>${esc(p.sequence)}</td>
        <td>${esc(p.assertion)}</td>
        <td>${
          disabled
            ? `<span class="warn">${esc(why)}</span>`
            : `<button type="button" data-path="${p.id}">Arrancar</button>`
        }</td>
      </tr>`;
    })
    .join("");
  root.innerHTML = `
    <section class="panel catalog">
      <h1>Catálogo de Paths</h1>
      <p class="hint">Arrancar un Path rellena Consentimiento con la tupla de duraciones. <strong>No</strong> sustituye la matriz por un “Siguiente”. CASE-CORE-11 nunca clona ceros en <code>releaseDuration</code>. Plantillas packaged se deshabilitan si su flag está off.</p>
      <table class="grid">
        <thead>
          <tr>
            <th>id</th><th>duraciones</th><th>seats</th><th>secuencia</th><th>aserción</th><th></th>
          </tr>
        </thead>
        <tbody>${rows}</tbody>
      </table>
    </section>
  `;
  root.querySelectorAll<HTMLButtonElement>("[data-path]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const id = btn.dataset.path;
      if (id) on.start(id);
    });
  });
}

function esc(value: string): string {
  return value.replaceAll("&", "&amp;").replaceAll('"', "&quot;").replaceAll("<", "&lt;");
}
