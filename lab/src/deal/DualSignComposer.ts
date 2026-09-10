import { DUAL_SIGN_TYPES, type DualSignForm } from "../session/DualSignDraft.ts";

export function renderDualSignComposer(
  root: HTMLElement,
  model: {
    form: DualSignForm;
    dualSign: boolean;
    digestP: string | null;
    digestC: string | null;
    sending: boolean;
  },
  on: {
    form: (f: DualSignForm) => void;
    toggle: () => void;
    signP: () => void;
    signC: () => void;
    relay: () => void;
  },
): void {
  const f = model.form;
  const split = f.type === "MutualSplit";
  root.innerHTML = `
    <section class="panel">
      <h2>Dual-sign</h2>
      <p class="hint">Dos envelopes, una tx Relayer. No reusa <code>DealTerms</code>. <code>providerBps = 10000</code> sigue siendo <code>MutualSplit</code>, no <code>CoSignedRelease</code>.</p>
      <p>
        <label class="inline"><input type="checkbox" id="dualSign" ${model.dualSign ? "checked" : ""}/> dualSign</label>
      </p>
      <div class="form-grid">
        <label>type
          <select id="dsType">
            <option value="">—</option>
            ${DUAL_SIGN_TYPES.map((t) => `<option value="${t}" ${f.type === t ? "selected" : ""}>${t}</option>`).join("")}
          </select>
        </label>
        <label class="full">dealId <input id="dsDeal" spellcheck="false" value="${esc(f.dealId)}" readonly /></label>
        <label>deadline unix <input id="dsDeadline" value="${esc(f.deadline)}" /></label>
        <label>nonceP <input id="dsNonceP" value="${esc(f.nonceP)}" /></label>
        <label>nonceC <input id="dsNonceC" value="${esc(f.nonceC)}" /></label>
        ${split ? `<label>providerBps <input id="dsBps" value="${esc(f.providerBps)}" /></label>` : ""}
      </div>
      <dl class="eip712">
        <dt>digest Provider</dt><dd><code>${model.digestP ?? "—"}</code></dd>
        <dt>digest Controller</dt><dd><code>${model.digestC ?? "—"}</code></dd>
        <dt>providerSig</dt><dd><code>${f.providerSig ?? "—"}</code></dd>
        <dt>controllerSig</dt><dd><code>${f.controllerSig ?? "—"}</code></dd>
      </dl>
      <p>
        <button type="button" id="signP">Firmar Provider</button>
        <button type="button" id="signC">Firmar Controller</button>
        <button type="button" id="relay" ${model.sending || !model.dualSign ? "disabled" : ""}>Relayer: una tx</button>
      </p>
    </section>
  `;

  const read = (): DualSignForm => ({
    type: (root.querySelector<HTMLSelectElement>("#dsType")?.value ?? "") as DualSignForm["type"],
    dealId: f.dealId,
    deadline: root.querySelector<HTMLInputElement>("#dsDeadline")?.value.trim() ?? "",
    nonceP: root.querySelector<HTMLInputElement>("#dsNonceP")?.value.trim() ?? "",
    nonceC: root.querySelector<HTMLInputElement>("#dsNonceC")?.value.trim() ?? "",
    providerBps: root.querySelector<HTMLInputElement>("#dsBps")?.value.trim() ?? f.providerBps,
    providerSig: f.providerSig,
    controllerSig: f.controllerSig,
  });

  root.querySelector("#dualSign")?.addEventListener("change", () => on.toggle());
  root.querySelector("#dsType")?.addEventListener("change", () => {
    const next = read();
    next.providerSig = null;
    next.controllerSig = null;
    on.form(next);
  });
  for (const id of ["dsDeadline", "dsNonceP", "dsNonceC", "dsBps"]) {
    root.querySelector(`#${id}`)?.addEventListener("change", () => {
      const next = read();
      next.providerSig = null;
      next.controllerSig = null;
      on.form(next);
    });
  }
  root.querySelector("#signP")?.addEventListener("click", () => on.signP());
  root.querySelector("#signC")?.addEventListener("click", () => on.signC());
  root.querySelector("#relay")?.addEventListener("click", () => on.relay());
}

function esc(value: string): string {
  return value.replaceAll("&", "&amp;").replaceAll('"', "&quot;").replaceAll("<", "&lt;");
}
