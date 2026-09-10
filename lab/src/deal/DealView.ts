import type { DualSignForm } from "../session/DualSignDraft.ts";
import type { MatrixRow } from "../eligibility/matrix.ts";
import { renderDualSignComposer } from "./DualSignComposer.ts";
import { renderClocksPanel } from "./ClocksPanel.ts";
import { renderDriftPanel, type DriftRow } from "./DriftPanel.ts";
import { renderKindsPanel } from "./KindsPanel.ts";
import { renderMatrixPanel } from "./MatrixPanel.ts";
import { renderSettlementPanel } from "./SettlementPanel.ts";
import { renderSubjectsPanel } from "./SubjectsPanel.ts";
import { renderTermsPanel } from "./TermsPanel.ts";
import { statusName, type DealSnapshot, type ModuleBinding } from "./types.ts";

export function renderDealView(
  root: HTMLElement,
  deal: DealSnapshot,
  bindings: ModuleBinding[],
  matrix: MatrixRow[],
  senderLabel: string,
  opts: {
    coreWrites: boolean;
    nonce: string;
    writeError: string | null;
    dualSign: boolean;
    dualForm: DualSignForm;
    digestP: string | null;
    digestC: string | null;
    sending: boolean;
    zkArb: boolean;
    drift: DriftRow[];
  },
  on: {
    coreWrites: (on: boolean) => void;
    zkArb: (on: boolean) => void;
    nonce: (value: string) => void;
    send: (verb: string) => void;
    dualToggle: () => void;
    dualForm: (f: DualSignForm) => void;
    signP: () => void;
    signC: () => void;
    relay: () => void;
  },
): void {
  root.innerHTML = `
    <article class="deal">
      <header class="deal-id">
        <h1>Deal</h1>
        <p><code>${deal.dealId}</code></p>
        <p><span class="chip is-on"><code>${statusName(deal.status)}</code></span></p>
        ${opts.writeError ? `<p class="bad">${opts.writeError.replaceAll("<", "&lt;")}</p>` : ""}
      </header>
      ${renderMatrixPanel(matrix, senderLabel, { ...opts, dualSign: opts.dualSign, zkArb: opts.zkArb })}
      <div id="dual-sign-slot"></div>
      ${renderTermsPanel(deal)}
      ${renderClocksPanel(deal)}
      ${renderKindsPanel(deal, bindings)}
      ${renderDriftPanel(deal, opts.drift)}
      ${renderSubjectsPanel(deal)}
      ${renderSettlementPanel(deal)}
    </article>
  `;
  root.querySelector<HTMLInputElement>("#coreWrites")?.addEventListener("change", (e) => {
    on.coreWrites((e.target as HTMLInputElement).checked);
  });
  root.querySelector<HTMLInputElement>("#zkArb")?.addEventListener("change", (e) => {
    on.zkArb((e.target as HTMLInputElement).checked);
  });
  root.querySelector<HTMLInputElement>("#cancelNonce")?.addEventListener("change", (e) => {
    on.nonce((e.target as HTMLInputElement).value.trim());
  });
  root.querySelectorAll<HTMLButtonElement>("[data-verb]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const verb = btn.dataset.verb;
      if (verb) on.send(verb);
    });
  });
  const slot = root.querySelector<HTMLElement>("#dual-sign-slot");
  if (slot) {
    renderDualSignComposer(
      slot,
      {
        form: opts.dualForm,
        dualSign: opts.dualSign,
        digestP: opts.digestP,
        digestC: opts.digestC,
        sending: opts.sending,
      },
      {
        form: on.dualForm,
        toggle: on.dualToggle,
        signP: on.signP,
        signC: on.signC,
        relay: on.relay,
      },
    );
  }
}

export function renderDealEmpty(root: HTMLElement, message: string | null): void {
  root.innerHTML = message
    ? `<p class="${message.startsWith("NONE") ? "muted" : "bad"}">${escapeHtml(message)}</p>`
    : "";
}

function escapeHtml(value: string): string {
  return value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
}
