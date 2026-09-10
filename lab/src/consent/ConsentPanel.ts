import type { Hex } from "viem";
import type { PreflightStep } from "./preflight.ts";
import { inspectActivate6 } from "../verbs/activateCore.ts";
import type { Envelope } from "./eip712.ts";

export type ConsentDraft = {
  p2p: boolean;
  holder: string;
  controller: string;
  provider: string;
  token: string;
  principal: string;
  fiatDuration: string;
  releaseDuration: string;
  disputeDuration: string;
  arbitrationDuration: string;
  holderNonce: string;
  providerNonce: string;
  deadline: string;
};

export const defaultDraft = (token: string): ConsentDraft => ({
  p2p: true,
  holder: "",
  controller: "",
  provider: "",
  token,
  principal: "1000000",
  fiatDuration: "3600",
  releaseDuration: "1800",
  disputeDuration: "7200",
  arbitrationDuration: "0",
  holderNonce: "1",
  providerNonce: "1",
  deadline: String(Math.floor(Date.now() / 1000) + 86_400),
});

export function renderConsentPanel(
  root: HTMLElement,
  model: {
    draft: ConsentDraft;
    coreActivate: boolean;
    steps: PreflightStep[];
    holderSig: Hex | null;
    providerSig: Hex | null;
    ha: Envelope | null;
    pa: Envelope | null;
    dealId: string | null;
    sending: boolean;
    sendError: string | null;
    suggestedToken: string | null;
  },
  on: {
    draft: (d: ConsentDraft) => void;
    toggleFlag: () => void;
    fillSeats: () => void;
    useToken: () => void;
    signHa: () => void;
    signPa: () => void;
    send: () => void;
    refresh: () => void;
  },
): void {
  const d = model.draft;
  const inspect =
    model.ha && model.pa && model.holderSig && model.providerSig
      ? inspectActivate6(model.ha, model.holderSig, model.pa, model.providerSig)
      : null;

  root.innerHTML = `
    <section class="panel consent">
      <h1>Consentimiento <code>activate</code> Core-only</h1>
      <p class="hint">P2P: dos firmas (HA + PA). El tx <strong>siempre</strong> es el overload de <code>6</code> args con <code>ControllerAcceptance</code> dummy + <code>bytes("")</code>. <code>packageIds = []</code>. Flag <code>coreActivate</code>.</p>
      <p>
        <label class="inline"><input type="checkbox" id="flag" ${model.coreActivate ? "checked" : ""}/> coreActivate</label>
        <button type="button" id="fill">Copiar asientos Holder/Provider</button>
        ${model.suggestedToken ? `<button type="button" id="tok">Usar testToken del set</button>` : ""}
        <button type="button" id="refresh">Releer preflight</button>
      </p>
      <div class="form-grid">
        <label>holder <input id="holder" spellcheck="false" value="${esc(d.holder)}" /></label>
        <label>controller ${d.p2p ? "(= holder)" : ""}
          <input id="controller" spellcheck="false" value="${esc(d.controller)}" ${d.p2p ? "readonly" : ""} /></label>
        <label>provider <input id="provider" spellcheck="false" value="${esc(d.provider)}" /></label>
        <label>token <input id="token" spellcheck="false" value="${esc(d.token)}" /></label>
        <label>principal <input id="principal" value="${esc(d.principal)}" /></label>
        <label>fiatDuration <input id="fiatDuration" value="${esc(d.fiatDuration)}" /></label>
        <label>releaseDuration <input id="releaseDuration" value="${esc(d.releaseDuration)}" /></label>
        <label>disputeDuration <input id="disputeDuration" value="${esc(d.disputeDuration)}" /></label>
        <label>arbitrationDuration <input id="arbitrationDuration" value="${esc(d.arbitrationDuration)}" /></label>
        <label>holder nonce <input id="holderNonce" value="${esc(d.holderNonce)}" /></label>
        <label>provider nonce <input id="providerNonce" value="${esc(d.providerNonce)}" /></label>
        <label>deadline (unix) <input id="deadline" value="${esc(d.deadline)}" /></label>
        <label class="inline full"><input type="checkbox" id="p2p" ${d.p2p ? "checked" : ""}/> P2P holder == controller</label>
      </div>
      <p class="hint">0 en un reloj = due inmediato <strong>y</strong> strictly-before ya TooLate. CASE-CORE-01-P2P usa (3600, 1800, 7200, 0).</p>
      <p>packageIds = <code>[]</code> · overload = <code>6</code> · CA dummy.</p>
      ${model.dealId ? `<p>dealId proyectado <code>${model.dealId}</code></p>` : ""}
      <h2>Preflight <code>_activate</code> Core</h2>
      <ol class="preflight">
        ${model.steps
          .map((s) => {
            const ok = s.eval.enabled;
            return `<li class="${ok ? "ok" : s.eval.reasonKind === "ui-policy" ? "warn" : "bad"}"><code>${esc(s.step)}</code> — ${ok ? "ok" : `<code>${esc(s.eval.reason)}</code>`}</li>`;
          })
          .join("")}
      </ol>
      <p>
        <button type="button" id="signHa">Firmar HolderAuthorization</button>
        <button type="button" id="signPa">Firmar ProviderAgreement</button>
        <button type="button" id="send" ${model.sending || !model.coreActivate ? "disabled" : ""}>Relayer: activate (6 args)</button>
      </p>
      <dl class="eip712">
        <dt>holderSig</dt><dd><code>${model.holderSig ?? "—"}</code></dd>
        <dt>providerSig</dt><dd><code>${model.providerSig ?? "—"}</code></dd>
        <dt>controllerSig</dt><dd><code>0x</code> (dummy)</dd>
      </dl>
      ${
        inspect
          ? `<pre class="encode">overload ${inspect.overload} dummyCA=${inspect.dummyCA}\n${inspect.args.join("\n")}</pre>`
          : ""
      }
      ${model.sendError ? `<p class="bad">${esc(model.sendError)}</p>` : ""}
    </section>
  `;

  const read = (): ConsentDraft => ({
    p2p: root.querySelector<HTMLInputElement>("#p2p")?.checked ?? true,
    holder: val("holder"),
    controller: val("controller"),
    provider: val("provider"),
    token: val("token"),
    principal: val("principal"),
    fiatDuration: val("fiatDuration"),
    releaseDuration: val("releaseDuration"),
    disputeDuration: val("disputeDuration"),
    arbitrationDuration: val("arbitrationDuration"),
    holderNonce: val("holderNonce"),
    providerNonce: val("providerNonce"),
    deadline: val("deadline"),
  });
  function val(id: string): string {
    return root.querySelector<HTMLInputElement>(`#${id}`)?.value.trim() ?? "";
  }

  root.querySelector("#p2p")?.addEventListener("change", () => {
    const next = read();
    if (next.p2p) next.controller = next.holder;
    on.draft(next);
  });
  for (const id of [
    "holder",
    "controller",
    "provider",
    "token",
    "principal",
    "fiatDuration",
    "releaseDuration",
    "disputeDuration",
    "arbitrationDuration",
    "holderNonce",
    "providerNonce",
    "deadline",
  ]) {
    root.querySelector(`#${id}`)?.addEventListener("change", () => {
      const next = read();
      if (next.p2p) next.controller = next.holder;
      on.draft(next);
    });
  }
  root.querySelector("#flag")?.addEventListener("change", () => on.toggleFlag());
  root.querySelector("#fill")?.addEventListener("click", () => on.fillSeats());
  root.querySelector("#tok")?.addEventListener("click", () => on.useToken());
  root.querySelector("#refresh")?.addEventListener("click", () => on.refresh());
  root.querySelector("#signHa")?.addEventListener("click", () => on.signHa());
  root.querySelector("#signPa")?.addEventListener("click", () => on.signPa());
  root.querySelector("#send")?.addEventListener("click", () => on.send());
}

function esc(value: string): string {
  return value.replaceAll("&", "&amp;").replaceAll('"', "&quot;").replaceAll("<", "&lt;");
}
