import type { PoolSnapshot } from "./probe.ts";

export function renderPoolView(
  root: HTMLElement,
  model: {
    poolFlag: boolean;
    poolPaste: string;
    snap: PoolSnapshot | null;
    recinto: string;
    holderIsPool: boolean;
    depositAmt: string;
    unlockNonce: string;
    error: string | null;
    suggested: string | null;
  },
  on: {
    toggle: () => void;
    poolPaste: (v: string) => void;
    holderIsPool: () => void;
    depositAmt: (v: string) => void;
    unlockNonce: (v: string) => void;
    probe: () => void;
    useSuggested: () => void;
    fillHolder: () => void;
    deposit: () => void;
    authorize: () => void;
    unlock: () => void;
    reconcile: () => void;
  },
): void {
  const mismatch =
    model.snap && model.recinto
      ? model.snap.escrow.toLowerCase() !== model.recinto.toLowerCase()
      : false;
  root.innerHTML = `
    <section class="panel pool">
      <h1>Pool</h1>
      <p class="hint">Constitución del vault <strong>fuera</strong> de la matriz del deal. Deal: <code>holder = pool</code>, <code>holderSig = bytes("")</code> (EIP-1271), <strong>CA hashed</strong> (dummy CA revierte). Kick es futuro-only: no se expone.</p>
      <p>
        <label class="inline"><input type="checkbox" id="poolFlag" ${model.poolFlag ? "checked" : ""}/> pool</label>
        <label class="inline"><input type="checkbox" id="holderIsPool" ${model.holderIsPool ? "checked" : ""}/> holderIsPool (EIP-1271)</label>
        ${model.suggested ? `<button type="button" id="usePool">Usar pool del set</button>` : ""}
      </p>
      <div class="bar">
        <label class="grow">pool
          <input id="poolPaste" spellcheck="false" value="${esc(model.poolPaste)}" />
        </label>
        <button type="button" id="probe">Leer pool</button>
        <button type="button" id="fillHolder">holder = pool en Consentimiento</button>
      </div>
      ${
        mismatch
          ? `<p class="bad">pool.escrow() = <code>${model.snap!.escrow}</code> ≠ Recinto <code>${esc(model.recinto)}</code>. No mezclar dominios.</p>`
          : ""
      }
      ${
        model.snap
          ? `<dl class="eip712">
        <dt>life</dt><dd><code>${model.snap.lifeName}</code></dd>
        <dt>token</dt><dd><code>${model.snap.token}</code></dd>
        <dt>escrow</dt><dd><code>${model.snap.escrow}</code></dd>
        <dt>idle</dt><dd><code>${model.snap.idle}</code></dd>
        <dt>locked</dt><dd><code>${model.snap.locked}</code></dd>
        <dt>credits</dt><dd><code>${model.snap.credits}</code></dd>
        <dt>consumed</dt><dd><code>${model.snap.consumed}</code></dd>
        <dt>nav</dt><dd><code>${model.snap.nav}</code></dd>
        <dt>totalShares</dt><dd><code>${model.snap.totalShares}</code></dd>
        <dt>controllerFeeBps</dt><dd><code>${model.snap.controllerFeeBps}</code></dd>
        <dt>reimburseContest</dt><dd><code>${model.snap.reimburseContest}</code></dd>
        <dt>payControllerOnFullReturn</dt><dd><code>${model.snap.payControllerOnFullReturn}</code></dd>
        <dt>isAgent(asiento)</dt><dd>${model.snap.agent === null ? "—" : model.snap.agent ? `<span class="ok">yes</span>` : `<span class="bad">no</span>`}</dd>
      </dl>`
          : ""
      }
      <div class="form-grid">
        <label>deposit amount <input id="depositAmt" value="${esc(model.depositAmt)}" /></label>
        <label>holder nonce (unlock / reconcile) <input id="unlockNonce" value="${esc(model.unlockNonce)}" /></label>
      </div>
      <p>
        <button type="button" id="deposit" ${model.poolFlag ? "" : "disabled"}>deposit</button>
        <button type="button" id="authorize" ${model.poolFlag ? "" : "disabled"}>authorize(ha, mods)</button>
        <button type="button" id="unlock" ${model.poolFlag ? "" : "disabled"}>unlock</button>
        <button type="button" id="reconcile" ${model.poolFlag ? "" : "disabled"}>reconcile</button>
      </p>
      ${model.error ? `<p class="bad">${esc(model.error)}</p>` : ""}
    </section>
  `;
  root.querySelector("#poolFlag")?.addEventListener("change", () => on.toggle());
  root.querySelector("#holderIsPool")?.addEventListener("change", () => on.holderIsPool());
  root.querySelector("#poolPaste")?.addEventListener("change", (e) => {
    on.poolPaste((e.target as HTMLInputElement).value.trim());
  });
  root.querySelector("#depositAmt")?.addEventListener("change", (e) => {
    on.depositAmt((e.target as HTMLInputElement).value.trim());
  });
  root.querySelector("#unlockNonce")?.addEventListener("change", (e) => {
    on.unlockNonce((e.target as HTMLInputElement).value.trim());
  });
  root.querySelector("#probe")?.addEventListener("click", () => on.probe());
  root.querySelector("#usePool")?.addEventListener("click", () => on.useSuggested());
  root.querySelector("#fillHolder")?.addEventListener("click", () => on.fillHolder());
  root.querySelector("#deposit")?.addEventListener("click", () => on.deposit());
  root.querySelector("#authorize")?.addEventListener("click", () => on.authorize());
  root.querySelector("#unlock")?.addEventListener("click", () => on.unlock());
  root.querySelector("#reconcile")?.addEventListener("click", () => on.reconcile());
}

function esc(value: string): string {
  return value.replaceAll("&", "&amp;").replaceAll('"', "&quot;").replaceAll("<", "&lt;");
}
