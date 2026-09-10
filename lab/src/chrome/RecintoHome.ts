import { EIP712_NAME, EIP712_VERSION } from "../addressbook/types.ts";
import type { RecintoProbe } from "../recinto/probe.ts";

export function renderRecintoHome(
  root: HTMLElement,
  model: {
    chainId: number;
    escrow: string;
    rpcUrl: string;
    probe: RecintoProbe | null;
  },
): void {
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
    <section class="soon">
      <h2>Lookup Deal</h2>
      <p class="muted">PR-2: <code>dealId</code> o <code>dealOf(signer, nonce)</code> → getters de <code>IEscrow</code>.</p>
      <label>dealId <input disabled placeholder="0x… bytes32" /></label>
      <label>signer <input disabled placeholder="0x…" /></label>
      <label>nonce <input disabled placeholder="uint256" /></label>
    </section>
    <section class="soon">
      <h2>Espacios</h2>
      <ul>
        <li>Deal / matriz — PR-2 / PR-3</li>
        <li>Consentimiento <code>activate</code> — PR-4</li>
        <li>Paquetes, Laboratorio, Pool, Rampa — más adelante</li>
      </ul>
    </section>
  `;
}
