import { EIP712_NAME, EIP712_VERSION } from "../addressbook/types.ts";
import type { RecintoProbe } from "../recinto/probe.ts";

export type DealShortcut = { sourceFile: string; label: string; dealId: string };

export function renderRecintoHome(
  root: HTMLElement,
  model: {
    chainId: number;
    escrow: string;
    rpcUrl: string;
    probe: RecintoProbe | null;
    dealId: string;
    signer: string;
    nonce: string;
    shortcuts: DealShortcut[];
    loading: boolean;
  },
  on: {
    dealId: (value: string) => void;
    signer: (value: string) => void;
    nonce: (value: string) => void;
    load: () => void;
    shortcut: (dealId: string) => void;
  },
): void {
  const shortcuts = model.shortcuts
    .map(
      (s) =>
        `<button type="button" class="recinto-chip" data-deal="${s.dealId}">
          <span class="chip-id">${escapeHtml(s.label)}</span>
          <code>${s.dealId}</code>
          <span class="muted">${escapeHtml(s.sourceFile)}</span>
        </button>`,
    )
    .join("");

  root.innerHTML = `
    <h1>Recinto</h1>
    <p>Una chain y un deployment de <code>Escrow</code>. El constructor no bindea paquetes. Core-only vs packaged es <strong>por deal</strong>, no un modo del contrato.</p>
    <dl class="eip712">
      <dt>EIP712Domain.name</dt><dd><code>${EIP712_NAME}</code></dd>
      <dt>EIP712Domain.version</dt><dd><code>${EIP712_VERSION}</code></dd>
      <dt>EIP712Domain.chainId</dt><dd><code>${model.chainId}</code></dd>
      <dt>EIP712Domain.verifyingContract</dt><dd><code>${model.escrow || "—"}</code></dd>
      <dt>RPC</dt><dd><code>${model.rpcUrl || "—"}</code></dd>
      <dt>RPC chainId</dt><dd><code>${model.probe?.rpcChainId ?? "—"}</code></dd>
      <dt>domainSeparator</dt><dd><code>${model.probe?.domainSeparator ?? "—"}</code></dd>
    </dl>
    <section>
      <h2>Lookup Deal</h2>
      <p class="hint"><code>IEscrow.status/terms/clocks/subjects/modules/kinds/settlementOf</code>. Atajos del JSON de <em>este</em> escrow; no mezclar recintos.</p>
      <div class="bar">
        <label class="grow">dealId
          <input id="dealId" spellcheck="false" placeholder="0x… bytes32" value="${escapeAttr(model.dealId)}" />
        </label>
        <label class="grow">signer
          <input id="signer" spellcheck="false" placeholder="dealOf(signer, nonce)" value="${escapeAttr(model.signer)}" />
        </label>
        <label>nonce
          <input id="nonce" spellcheck="false" placeholder="uint256" value="${escapeAttr(model.nonce)}" />
        </label>
        <button type="button" id="load" ${model.loading ? "disabled" : ""}>Leer IEscrow</button>
      </div>
      ${shortcuts ? `<div class="recinto-list">${shortcuts}</div>` : `<p class="muted">Este set no trae *DealId.</p>`}
    </section>
  `;

  root.querySelector<HTMLInputElement>("#dealId")?.addEventListener("change", (e) => {
    on.dealId((e.target as HTMLInputElement).value.trim());
  });
  root.querySelector<HTMLInputElement>("#signer")?.addEventListener("change", (e) => {
    on.signer((e.target as HTMLInputElement).value.trim());
  });
  root.querySelector<HTMLInputElement>("#nonce")?.addEventListener("change", (e) => {
    on.nonce((e.target as HTMLInputElement).value.trim());
  });
  root.querySelector("#load")?.addEventListener("click", () => {
    on.dealId(root.querySelector<HTMLInputElement>("#dealId")?.value.trim() ?? "");
    on.signer(root.querySelector<HTMLInputElement>("#signer")?.value.trim() ?? "");
    on.nonce(root.querySelector<HTMLInputElement>("#nonce")?.value.trim() ?? "");
    on.load();
  });
  root.querySelectorAll<HTMLButtonElement>("[data-deal]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const id = btn.dataset.deal;
      if (id) on.shortcut(id);
    });
  });
}

function escapeAttr(value: string): string {
  return value.replaceAll("&", "&amp;").replaceAll('"', "&quot;").replaceAll("<", "&lt;");
}

function escapeHtml(value: string): string {
  return value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
}
