import type { MatrixRow } from "../eligibility/matrix.ts";
import { renderClocksPanel } from "./ClocksPanel.ts";
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
): void {
  root.innerHTML = `
    <article class="deal">
      <header class="deal-id">
        <h1>Deal</h1>
        <p><code>${deal.dealId}</code></p>
        <p><span class="chip is-on"><code>${statusName(deal.status)}</code></span></p>
      </header>
      ${renderMatrixPanel(matrix, senderLabel)}
      ${renderTermsPanel(deal)}
      ${renderClocksPanel(deal)}
      ${renderKindsPanel(deal, bindings)}
      ${renderSubjectsPanel(deal)}
      ${renderSettlementPanel(deal)}
    </article>
  `;
}

export function renderDealEmpty(root: HTMLElement, message: string | null): void {
  root.innerHTML = message
    ? `<p class="${message.startsWith("NONE") ? "muted" : "bad"}">${escapeHtml(message)}</p>`
    : "";
}

function escapeHtml(value: string): string {
  return value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
}
