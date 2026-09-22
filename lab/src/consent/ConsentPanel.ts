import type { Hex } from "viem";
import type { PreflightStep } from "./preflight.ts";
import { inspectActivate6 } from "../verbs/activateCore.ts";
import { inspectActivate7 } from "../verbs/activatePackaged.ts";
import { ZERO_ADDRESS, type PackageMods } from "../deal/types.ts";
import { modsEmpty } from "../slots/types.ts";
import type { Envelope } from "./eip712.ts";
import { hasDanger, reviewClocks, type ClockFinding } from "./termsReview.ts";

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
  controllerNonce: string;
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
  controllerNonce: "1",
  deadline: String(Math.floor(Date.now() / 1000) + 86_400),
});

export function renderConsentPanel(
  root: HTMLElement,
  model: {
    draft: ConsentDraft;
    coreActivate: boolean;
    distinctController: boolean;
    steps: PreflightStep[];
    holderSig: Hex | null;
    providerSig: Hex | null;
    controllerSig: Hex | null;
    ha: Envelope | null;
    pa: Envelope | null;
    ca: Envelope | null;
    mods: PackageMods | null;
    dealId: string | null;
    sending: boolean;
    sendError: string | null;
    suggestedToken: string | null;
    /** Explicit "yes, I read the danger" — the only way past a zero clock (§3.8). */
    clocksAcknowledged: boolean;
  },
  on: {
    draft: (d: ConsentDraft) => void;
    toggleFlag: () => void;
    toggleDistinct: () => void;
    fillSeats: () => void;
    useToken: () => void;
    signHa: () => void;
    signPa: () => void;
    signCa: () => void;
    send: () => void;
    refresh: () => void;
    acknowledgeClocks: () => void;
  },
): void {
  const d = model.draft;
  const p2p = d.p2p;
  const packaged = Boolean(model.mods && !modsEmpty(model.mods));
  // The clocks the parties are about to SIGN, reviewed before any signature exists. A zero clock is
  // not a short clock: it hands one side the whole principal or half of it, for free (§3.8).
  const clockFindings: ClockFinding[] = model.ha
    ? reviewClocks(model.ha.terms, {
        zk: Boolean(model.mods && model.mods.zk !== ZERO_ADDRESS),
        arbitration: Boolean(model.mods && model.mods.court !== ZERO_ADDRESS),
      })
    : [];
  const clocksBlocked = hasDanger(clockFindings) && !model.clocksAcknowledged;
  const inspect =
    model.ha && model.pa && model.holderSig && model.providerSig
      ? packaged && model.mods
        ? inspectActivate7(
            model.ha,
            model.holderSig,
            model.pa,
            model.providerSig,
            model.mods,
            p2p ? null : model.ca,
            p2p ? null : model.controllerSig,
          )
        : inspectActivate6(
            model.ha,
            model.holderSig,
            model.pa,
            model.providerSig,
            p2p ? null : model.ca,
            p2p ? null : model.controllerSig,
          )
      : null;

  root.innerHTML = `
    <section class="panel consent">
      <h1>Consentimiento <code>activate</code></h1>
      <p class="hint">P2P: dos firmas (HA + PA) y CA dummy. Controller distinto: tercer envelope hashed. Core-only = overload 6, <code>packageIds = []</code>. Con slots = overload 7, <code>PackageMods</code> en calldata (no entra al digest).</p>
      <p>
        <label class="inline"><input type="checkbox" id="flag" ${model.coreActivate ? "checked" : ""}/> coreActivate</label>
        <label class="inline"><input type="checkbox" id="distinct" ${model.distinctController ? "checked" : ""}/> distinctController</label>
        <button type="button" id="fill">Copiar asientos Holder/Provider/Controller</button>
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
        <label>controller nonce <input id="controllerNonce" value="${esc(d.controllerNonce)}" ${d.p2p ? "readonly" : ""} /></label>
        <label>deadline (unix) <input id="deadline" value="${esc(d.deadline)}" /></label>
        <label class="inline full"><input type="checkbox" id="p2p" ${d.p2p ? "checked" : ""}/> P2P holder == controller</label>
      </div>
      <p class="hint">0 en un reloj = due inmediato <strong>y</strong> strictly-before ya TooLate. CASE-CORE-01-P2P / CASE-CORE-01-CTRL usan (3600, 1800, 7200, 0). P2P ignora controllerNonce en <code>dealId</code>.</p>
      ${renderClockReview(clockFindings, model.clocksAcknowledged)}
      <p>packageIds.length = <code>${model.ha ? model.ha.terms.packageIds.length : 0}</code> · overload = <code>${packaged ? "7" : "6"}</code> · ${p2p ? "CA dummy." : "CA hashed."}</p>
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
        <button type="button" id="signHa" ${clocksBlocked ? "disabled" : ""}>Firmar HolderAuthorization</button>
        <button type="button" id="signPa" ${clocksBlocked ? "disabled" : ""}>Firmar ProviderAgreement</button>
        ${p2p ? "" : `<button type="button" id="signCa" ${clocksBlocked ? "disabled" : ""}>Firmar ControllerAcceptance</button>`}
        <button type="button" id="send" ${model.sending || !model.coreActivate || clocksBlocked ? "disabled" : ""}>Relayer: activate (${packaged ? "7" : "6"} args)</button>
      </p>
      <dl class="eip712">
        <dt>holderSig</dt><dd><code>${model.holderSig ?? "—"}</code></dd>
        <dt>providerSig</dt><dd><code>${model.providerSig ?? "—"}</code></dd>
        <dt>controllerSig</dt><dd><code>${p2p ? "0x (dummy)" : (model.controllerSig ?? "—")}</code></dd>
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
    controllerNonce: val("controllerNonce"),
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
    "controllerNonce",
    "deadline",
  ]) {
    root.querySelector(`#${id}`)?.addEventListener("change", () => {
      const next = read();
      if (next.p2p) next.controller = next.holder;
      on.draft(next);
    });
  }
  root.querySelector("#flag")?.addEventListener("change", () => on.toggleFlag());
  root.querySelector("#distinct")?.addEventListener("change", () => on.toggleDistinct());
  root.querySelector("#fill")?.addEventListener("click", () => on.fillSeats());
  root.querySelector("#tok")?.addEventListener("click", () => on.useToken());
  root.querySelector("#refresh")?.addEventListener("click", () => on.refresh());
  root.querySelector("#signHa")?.addEventListener("click", () => on.signHa());
  root.querySelector("#signPa")?.addEventListener("click", () => on.signPa());
  root.querySelector("#signCa")?.addEventListener("click", () => on.signCa());
  root.querySelector("#send")?.addEventListener("click", () => on.send());
  root.querySelector("#ackClocks")?.addEventListener("change", () => on.acknowledgeClocks());
}

/// The clock review, rendered where it is read: above the signature buttons, not in a tooltip.
/// A `danger` finding disables them until it is explicitly acknowledged — the kernel will not
/// stop any of this (§3.8: the clocks belong to the parties), so the client is the only place
/// between a person and a signature that gives away their principal.
function renderClockReview(findings: ClockFinding[], acknowledged: boolean): string {
  if (findings.length === 0) {
    return `<p class="ok">Relojes: sin hallazgos. Ninguno es cero y todos superan los pisos de producción.</p>`;
  }
  const danger = findings.some((f) => f.severity === "danger");
  const rows = findings
    .map(
      (f) =>
        `<li class="${f.severity === "danger" ? "bad" : f.severity === "warning" ? "warn" : "ok"}">
          <code>${esc(f.clock)}</code> — ${esc(f.effect)}<br /><span class="hint">${esc(f.detail)}</span>
        </li>`,
    )
    .join("");
  return `
    <section class="clock-review">
      <h2>Revisión de relojes${danger ? " — <strong>regalás el deal</strong>" : ""}</h2>
      ${
        danger
          ? `<p class="hint">Un reloj en cero no es un reloj corto: le da a una parte el principal entero o la mitad, gratis. El kernel no lo impide (§3.8, las duraciones son de las partes), así que se frena acá.</p>`
          : `<p class="hint">Pisos de producción, no del protocolo. Los paths del catálogo del lab los rompen a propósito para poder recorrerse en una sesión.</p>`
      }
      <ul class="findings">${rows}</ul>
      ${
        danger
          ? `<p><label class="inline"><input type="checkbox" id="ackClocks" ${acknowledged ? "checked" : ""}/> Entiendo lo de arriba y quiero firmar igual</label></p>`
          : ""
      }
    </section>
  `;
}

function esc(value: string): string {
  return value.replaceAll("&", "&amp;").replaceAll('"', "&quot;").replaceAll("<", "&lt;");
}
