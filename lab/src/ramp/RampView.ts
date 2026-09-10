export type RampForm = {
  ramp: string;
  token: string;
  amount: string;
  minAmountOut: string;
  dest: string;
  to: string;
  refund: string;
};

export const emptyRampForm = (): RampForm => ({
  ramp: "",
  token: "",
  amount: "1000000",
  minAmountOut: "0",
  dest: "40161",
  to: "",
  refund: "",
});

export function renderRampView(
  root: HTMLElement,
  model: {
    rampFlag: boolean;
    form: RampForm;
    quote: { nativeFee: string; amountOut: string } | null;
    error: string | null;
  },
  on: {
    toggle: () => void;
    form: (f: RampForm) => void;
    quote: () => void;
    send: () => void;
    pasteSet: () => void;
  },
): void {
  root.innerHTML = `
    <section class="panel ramp">
      <h1>Rampa taxi</h1>
      <p class="hint"><code>IRamp.quote</code> / <code>send</code>. <strong>Taxi-only: no hay compose</strong>. StargateV2Ramp no implementa compose (RAMPS.md lo permite; el bytecode no). Token del set ramp = USDC, no TestToken.</p>
      <p>
        <label class="inline"><input type="checkbox" id="rampFlag" ${model.rampFlag ? "checked" : ""}/> ramp</label>
        <button type="button" id="pasteSet">Pegar ramp/USDC/destEid del set</button>
      </p>
      <div class="form-grid">
        <label>ramp <input id="ramp" spellcheck="false" value="${esc(model.form.ramp)}" /></label>
        <label>token (USDC) <input id="token" spellcheck="false" value="${esc(model.form.token)}" /></label>
        <label>amount <input id="amount" value="${esc(model.form.amount)}" /></label>
        <label>minAmountOut <input id="minAmountOut" value="${esc(model.form.minAmountOut)}" /></label>
        <label>dest (eid) <input id="dest" value="${esc(model.form.dest)}" /></label>
        <label>to <input id="to" spellcheck="false" value="${esc(model.form.to)}" /></label>
        <label>refund <input id="refund" spellcheck="false" value="${esc(model.form.refund)}" /></label>
      </div>
      <p>
        <button type="button" id="quote" ${model.rampFlag ? "" : "disabled"}>quote</button>
        <button type="button" id="send" ${model.rampFlag ? "" : "disabled"}>send (taxi)</button>
      </p>
      ${
        model.quote
          ? `<p>nativeFee <code>${esc(model.quote.nativeFee)}</code> · amountOut <code>${esc(model.quote.amountOut)}</code></p>`
          : ""
      }
      ${model.error ? `<p class="bad">${esc(model.error)}</p>` : ""}
    </section>
  `;
  const read = (): RampForm => ({
    ramp: val("ramp"),
    token: val("token"),
    amount: val("amount"),
    minAmountOut: val("minAmountOut"),
    dest: val("dest"),
    to: val("to"),
    refund: val("refund"),
  });
  function val(id: string): string {
    return root.querySelector<HTMLInputElement>(`#${id}`)?.value.trim() ?? "";
  }
  root.querySelector("#rampFlag")?.addEventListener("change", () => on.toggle());
  for (const id of ["ramp", "token", "amount", "minAmountOut", "dest", "to", "refund"]) {
    root.querySelector(`#${id}`)?.addEventListener("change", () => on.form(read()));
  }
  root.querySelector("#quote")?.addEventListener("click", () => on.quote());
  root.querySelector("#send")?.addEventListener("click", () => on.send());
  root.querySelector("#pasteSet")?.addEventListener("click", () => on.pasteSet());
}

function esc(value: string): string {
  return value.replaceAll("&", "&amp;").replaceAll('"', "&quot;").replaceAll("<", "&lt;");
}
