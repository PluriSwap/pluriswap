import type { HexBytes32 } from "../addressbook/types.ts";
import type { SlotRow } from "./types.ts";
import type { ModsDraft } from "./types.ts";

export function renderPackageModsPanel(
  root: HTMLElement,
  model: {
    packages: boolean;
    draft: ModsDraft;
    rows: SlotRow[];
    ids: HexBytes32[];
    idsOverride: string;
    suggested: ModsDraft | null;
  },
  on: {
    toggle: () => void;
    draft: (d: ModsDraft) => void;
    idsOverride: (value: string) => void;
    pasteSet: () => void;
  },
): void {
  root.innerHTML = `
    <section class="panel slots">
      <h1>PackageMods</h1>
      <p class="hint">Default Core-only: slots nulos, <code>packageIds = []</code>, overload 6. Pegar addresses; la UI recomputa <code>PackageId</code> y muestra match/mismatch <strong>antes</strong> de firmar. No es un registry. Flag <code>packages</code>.</p>
      <p>
        <label class="inline"><input type="checkbox" id="packages" ${model.packages ? "checked" : ""}/> packages</label>
        ${model.suggested ? `<button type="button" id="pasteSet">Pegar slots del set (atajo)</button>` : ""}
      </p>
      <div class="form-grid">
        <label>passport <input id="passport" spellcheck="false" value="${esc(model.draft.passport)}" ${model.packages ? "" : "readonly"} /></label>
        <label>reputation <input id="reputation" spellcheck="false" value="${esc(model.draft.reputation)}" ${model.packages ? "" : "readonly"} /></label>
        <label>bonds <input id="bonds" spellcheck="false" value="${esc(model.draft.bonds)}" ${model.packages ? "" : "readonly"} /></label>
        <label>zk <input id="zk" spellcheck="false" value="${esc(model.draft.zk)}" ${model.packages ? "" : "readonly"} /></label>
        <label>court <input id="court" spellcheck="false" value="${esc(model.draft.court)}" ${model.packages ? "" : "readonly"} /></label>
        <label class="full">packageIds override (force unsorted / missing; vacío = recomputeado)
          <input id="idsOverride" spellcheck="false" value="${esc(model.idsOverride)}" ${model.packages ? "" : "readonly"} />
        </label>
      </div>
      <p>packageIds = ${model.ids.length === 0 ? "<code>[]</code>" : model.ids.map((id) => `<code>${id}</code>`).join(" ")}</p>
      <table class="grid">
        <thead>
          <tr>
            <th>slot</th><th>address</th><th>id</th><th>∈ packageIds</th><th>peer passport</th><th>binding</th><th></th>
          </tr>
        </thead>
        <tbody>
          ${model.rows
            .map((r) => {
              const match =
                r.inIds === null ? "—" : r.inIds ? `<span class="ok">match</span>` : `<span class="bad">miss</span>`;
              const peer =
                r.peerOk === null
                  ? "—"
                  : r.peerOk
                    ? `<span class="ok">ok</span>`
                    : `<span class="bad">PeerMismatch</span>`;
              const bind =
                r.getter === "none"
                  ? "n/a"
                  : `${r.getter}=<code>${r.boundTo ?? "—"}</code> ${
                      r.matchesRecinto === false ? `<span class="bad">≠ recinto</span>` : ""
                    }`;
              return `<tr>
                <td><code>${r.slot}</code></td>
                <td><code>${r.address ?? "0x0"}</code></td>
                <td><code>${r.id ?? "—"}</code></td>
                <td>${match}</td>
                <td>${peer}</td>
                <td>${bind}</td>
                <td>${r.lab ? `<span class="chip">LAB</span>` : ""}</td>
              </tr>`;
            })
            .join("")}
        </tbody>
      </table>
    </section>
  `;

  root.querySelector("#packages")?.addEventListener("change", () => on.toggle());
  root.querySelector("#pasteSet")?.addEventListener("click", () => on.pasteSet());
  const read = (): ModsDraft => ({
    passport: val("passport"),
    reputation: val("reputation"),
    bonds: val("bonds"),
    zk: val("zk"),
    court: val("court"),
  });
  function val(id: string): string {
    return root.querySelector<HTMLInputElement>(`#${id}`)?.value.trim() ?? "";
  }
  for (const id of ["passport", "reputation", "bonds", "zk", "court"]) {
    root.querySelector(`#${id}`)?.addEventListener("change", () => on.draft(read()));
  }
  root.querySelector("#idsOverride")?.addEventListener("change", (e) => {
    on.idsOverride((e.target as HTMLInputElement).value.trim());
  });
}

function esc(value: string): string {
  return value.replaceAll("&", "&amp;").replaceAll('"', "&quot;").replaceAll("<", "&lt;");
}
