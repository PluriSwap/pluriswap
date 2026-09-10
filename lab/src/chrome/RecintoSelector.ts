import { DEFAULT_RPC, EIP712_NAME, EIP712_VERSION, type RecintoRow } from "../addressbook/types.ts";
import type { RecintoProbe } from "../recinto/probe.ts";

export type RecintoSelectorModel = {
  chainId: number;
  rpcUrl: string;
  escrowPaste: string;
  recintos: RecintoRow[];
  probe: RecintoProbe | null;
  probing: boolean;
};

export function renderRecintoSelector(
  root: HTMLElement,
  model: RecintoSelectorModel,
  on: {
    chainId: (id: number) => void;
    rpcUrl: (url: string) => void;
    escrow: (value: string) => void;
    pick: (row: RecintoRow) => void;
    probe: () => void;
  },
): void {
  const recintoButtons = model.recintos
    .map((row) => {
      const tokens = row.testTokens
        .map((t) => `${short(t.token)} <span class="muted">(${t.sourceFile})</span>`)
        .join("<br>");
      const selected =
        row.chainId === model.chainId &&
        row.escrow.toLowerCase() === model.escrowPaste.trim().toLowerCase();
      return `<button type="button" class="recinto-chip${selected ? " is-on" : ""}" data-escrow="${row.escrow}" data-chain="${row.chainId}">
        <span class="chip-id">chainId ${row.chainId}</span>
        <code>${row.escrow}</code>
        <span class="muted">${row.sources.join(" · ")}</span>
        <span class="chip-token">testToken por archivo:<br>${tokens || "—"}</span>
      </button>`;
    })
    .join("");

  const probe = model.probe;
  const mismatch =
    probe && probe.rpcChainId !== null && probe.rpcChainId !== model.chainId
      ? `<p class="warn">RPC chainId ${probe.rpcChainId} ≠ selector ${model.chainId}. Firmar quedará bloqueado.</p>`
      : "";
  const domainLine = probe?.domainSeparator
    ? `<code class="domain">${probe.domainSeparator}</code>`
    : `<span class="muted">${model.probing ? "leyendo…" : "sin lectura"}</span>`;
  const expectedLine = probe?.expectedDomainSeparator
    ? `<code>${probe.expectedDomainSeparator}</code>`
    : "—";
  const matchBadge =
    probe?.domainMatches === true
      ? `<span class="ok">match</span>`
      : probe?.domainMatches === false
        ? `<span class="bad">mismatch</span>`
        : "";

  root.innerHTML = `
    <header class="bar">
      <div class="brand">
        <strong>PluriSwap lab</strong>
        <span class="muted">consola del recinto · no es un marketplace</span>
      </div>
      <label>chainId
        <select id="chain">
          <option value="421614" ${model.chainId === 421614 ? "selected" : ""}>421614 Arbitrum Sepolia</option>
          <option value="31337" ${model.chainId === 31337 ? "selected" : ""}>31337 Anvil</option>
        </select>
      </label>
      <label class="grow">RPC
        <input id="rpc" spellcheck="false" value="${escapeAttr(model.rpcUrl)}" />
      </label>
      <label class="grow">escrow (pegar)
        <input id="escrow" spellcheck="false" placeholder="0x…" value="${escapeAttr(model.escrowPaste)}" />
      </label>
      <button type="button" id="probe" ${model.probing ? "disabled" : ""}>Leer domainSeparator</button>
    </header>
    <p class="hint">El JSON es un atajo. Pegar cualquier escrow compatible está al mismo nivel. AddressBook ≠ registry.</p>
    <div class="recinto-list">${recintoButtons || `<p class="muted">No hay JSON con campo escrow en deployments/.</p>`}</div>
    <dl class="eip712">
      <dt>name</dt><dd><code>${EIP712_NAME}</code></dd>
      <dt>version</dt><dd><code>${EIP712_VERSION}</code></dd>
      <dt>chainId</dt><dd><code>${model.chainId}</code></dd>
      <dt>verifyingContract</dt><dd><code>${model.escrowPaste || "—"}</code></dd>
      <dt>domainSeparator() vivo</dt><dd>${domainLine} ${matchBadge}</dd>
      <dt>esperado (name/version/chainId/verifyingContract)</dt><dd>${expectedLine}</dd>
      <dt>bytecode</dt><dd>${probe?.codePresent === true ? "presente" : probe?.codePresent === false ? "ausente" : "—"}</dd>
    </dl>
    ${probe?.error ? `<p class="bad">${escapeHtml(probe.error)}</p>` : ""}
    ${mismatch}
  `;

  root.querySelector<HTMLSelectElement>("#chain")?.addEventListener("change", (e) => {
    const id = Number((e.target as HTMLSelectElement).value);
    on.chainId(id);
    const rpc = DEFAULT_RPC[id];
    if (rpc) on.rpcUrl(rpc);
  });
  root.querySelector<HTMLInputElement>("#rpc")?.addEventListener("change", (e) => {
    on.rpcUrl((e.target as HTMLInputElement).value);
  });
  root.querySelector<HTMLInputElement>("#escrow")?.addEventListener("change", (e) => {
    on.escrow((e.target as HTMLInputElement).value.trim());
  });
  root.querySelector("#probe")?.addEventListener("click", () => on.probe());
  root.querySelectorAll<HTMLButtonElement>(".recinto-chip").forEach((btn) => {
    btn.addEventListener("click", () => {
      const escrow = btn.dataset.escrow;
      const chain = Number(btn.dataset.chain);
      const row = model.recintos.find((r) => r.escrow === escrow && r.chainId === chain);
      if (row) on.pick(row);
    });
  });
}

function short(addr: string): string {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

function escapeAttr(value: string): string {
  return value.replaceAll("&", "&amp;").replaceAll('"', "&quot;").replaceAll("<", "&lt;");
}

function escapeHtml(value: string): string {
  return value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
}
