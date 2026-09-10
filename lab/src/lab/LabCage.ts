export type LabForm = {
  wallet: string;
  subject: string;
  nullifier: string;
  dealId: string;
  ruling: string;
  mintTo: string;
  mintAmount: string;
  approveSpender: string;
  approveAmount: string;
  vault: string;
  depositAmount: string;
  warp: string;
};

export const emptyLabForm = (): LabForm => ({
  wallet: "",
  subject: "",
  nullifier: "",
  dealId: "",
  ruling: "1",
  mintTo: "",
  mintAmount: "1000000",
  approveSpender: "",
  approveAmount: "1000000",
  vault: "",
  depositAmount: "100000",
  warp: "100",
});

export function renderLabCage(
  root: HTMLElement,
  model: {
    labVerbs: boolean;
    form: LabForm;
    proof: string | null;
    anvil: boolean;
    error: string | null;
    passport: string;
    court: string;
    token: string;
  },
  on: {
    toggle: () => void;
    form: (f: LabForm) => void;
    setHuman: () => void;
    encodeProof: () => void;
    submitRuling: () => void;
    mint: () => void;
    approve: () => void;
    deposit: () => void;
    warp: () => void;
  },
): void {
  root.innerHTML = `
    <section class="panel lab-cage">
      <h1>Laboratorio (jaula LAB)</h1>
      <p class="hint"><strong>No es humanidad ni un proof de circuito.</strong> <code>PassportMock.setHuman</code> escribe un subject de laboratorio. El payload ZK es <code>abi.encode(dealId, nullifier)</code> para <code>VerifierMock</code>. <code>submitRuling</code> habla con <code>ArbitrationMock</code>, no con un tribunal. <code>ArbitrationMock.open()</code> no se expone (grief <code>AlreadyOpen</code>).</p>
      <p>
        <label class="inline"><input type="checkbox" id="labVerbs" ${model.labVerbs ? "checked" : ""}/> labVerbs</label>
      </p>
      <h2>PassportMock.setHuman</h2>
      <p class="muted">passport = <code>${esc(model.passport || "—")}</code>. No hay CTA “Verify humanity”.</p>
      <div class="form-grid">
        <label>wallet <input id="wallet" spellcheck="false" value="${esc(model.form.wallet)}" /></label>
        <label>subject (bytes32) <input id="subject" spellcheck="false" value="${esc(model.form.subject)}" /></label>
      </div>
      <p><button type="button" id="setHuman" ${model.labVerbs ? "" : "disabled"}>LAB setHuman</button></p>
      <h2>VerifierMock payload</h2>
      <div class="form-grid">
        <label>dealId <input id="dealId" spellcheck="false" value="${esc(model.form.dealId)}" /></label>
        <label>nullifier <input id="nullifier" spellcheck="false" value="${esc(model.form.nullifier)}" /></label>
      </div>
      <p><button type="button" id="encodeProof">Ensamblar proof mock</button></p>
      ${model.proof ? `<pre class="encode">LAB proof (no circuito)\n${esc(model.proof)}</pre>` : ""}
      <h2>ArbitrationMock.submitRuling</h2>
      <p class="muted">court = <code>${esc(model.court || "—")}</code>. 1 HolderWin · 2 ProviderWin · 3 Stalemate. No <code>open()</code>.</p>
      <div class="form-grid">
        <label>ruling <input id="ruling" value="${esc(model.form.ruling)}" /></label>
      </div>
      <p><button type="button" id="submitRuling" ${model.labVerbs ? "" : "disabled"}>LAB submitRuling</button></p>
      <h2>TestToken.mint / approve / BondVault.deposit</h2>
      <p class="muted">token = <code>${esc(model.token || "—")}</code>. PATH-TRIO: mint, approve vault, deposit lock, approve escrow.</p>
      <div class="form-grid">
        <label>mint to <input id="mintTo" spellcheck="false" value="${esc(model.form.mintTo)}" /></label>
        <label>mint amount <input id="mintAmount" value="${esc(model.form.mintAmount)}" /></label>
        <label>approve spender <input id="approveSpender" spellcheck="false" value="${esc(model.form.approveSpender)}" /></label>
        <label>approve amount <input id="approveAmount" value="${esc(model.form.approveAmount)}" /></label>
        <label>vault <input id="vault" spellcheck="false" value="${esc(model.form.vault)}" /></label>
        <label>deposit amount <input id="depositAmount" value="${esc(model.form.depositAmount)}" /></label>
      </div>
      <p>
        <button type="button" id="mint" ${model.labVerbs ? "" : "disabled"}>LAB mint</button>
        <button type="button" id="approve" ${model.labVerbs ? "" : "disabled"}>LAB approve</button>
        <button type="button" id="deposit" ${model.labVerbs ? "" : "disabled"}>LAB vault.deposit</button>
      </p>
      ${
        model.anvil
          ? `<h2>Reloj Anvil</h2>
      <p class="hint">Solo <code>chainId == 31337</code>. <code>evm_increaseTime</code> + <code>evm_mine</code>. CASE-CORE-11: 100s para <code>releaseDuration=100</code>.</p>
      <label>seconds <input id="warp" value="${esc(model.form.warp)}" /></label>
      <p><button type="button" id="warpBtn" ${model.labVerbs ? "" : "disabled"}>LAB warp</button></p>`
          : ""
      }
      ${model.error ? `<p class="bad">${esc(model.error)}</p>` : ""}
    </section>
  `;

  const read = (): LabForm => ({
    wallet: val("wallet"),
    subject: val("subject"),
    nullifier: val("nullifier"),
    dealId: val("dealId"),
    ruling: val("ruling"),
    mintTo: val("mintTo"),
    mintAmount: val("mintAmount"),
    approveSpender: val("approveSpender"),
    approveAmount: val("approveAmount"),
    vault: val("vault"),
    depositAmount: val("depositAmount"),
    warp: val("warp") || model.form.warp,
  });
  function val(id: string): string {
    return root.querySelector<HTMLInputElement>(`#${id}`)?.value.trim() ?? "";
  }
  root.querySelector("#labVerbs")?.addEventListener("change", () => on.toggle());
  for (const id of [
    "wallet",
    "subject",
    "nullifier",
    "dealId",
    "ruling",
    "mintTo",
    "mintAmount",
    "approveSpender",
    "approveAmount",
    "vault",
    "depositAmount",
    "warp",
  ]) {
    root.querySelector(`#${id}`)?.addEventListener("change", () => on.form(read()));
  }
  root.querySelector("#setHuman")?.addEventListener("click", () => on.setHuman());
  root.querySelector("#encodeProof")?.addEventListener("click", () => on.encodeProof());
  root.querySelector("#submitRuling")?.addEventListener("click", () => on.submitRuling());
  root.querySelector("#mint")?.addEventListener("click", () => on.mint());
  root.querySelector("#approve")?.addEventListener("click", () => on.approve());
  root.querySelector("#deposit")?.addEventListener("click", () => on.deposit());
  root.querySelector("#warpBtn")?.addEventListener("click", () => on.warp());
}

function esc(value: string): string {
  return value.replaceAll("&", "&amp;").replaceAll('"', "&quot;").replaceAll("<", "&lt;");
}
