import { pasteRampSet, runRampQuote, runRampSend } from "../app/actions.ts";
import * as S from "../app/store.ts";
import { Badge, Button, Field, Help, Input, KV, Panel, Warn } from "../ui/atoms.tsx";

export function RampSpace() {
  const f = S.rampForm.value;
  const set = (patch: Partial<typeof f>) => (S.rampForm.value = { ...f, ...patch });
  const busy = S.sending.value;
  return (
    <div>
      <header class="space-head">
        <h2>Rampa</h2>
        <p>
          <code>StargateV2Ramp</code> es <strong>taxi-only</strong>: <code>quote(intent)</code> y <code>send(intent)</code> para sacar USDC de
          Arbitrum después de un deal. No escribe estado Core. <code>compose → activate</code> está en spec (RAMPS.md) y no está
          implementado; esta consola no lo presenta como verbo vivo.
        </p>
      </header>
      <Panel title="RampIntent" kind="kernel" right={<Button onClick={pasteRampSet}>pegar ramp/usdc/destEid del set</Button>}>
        {!S.flags.value.ramp && <Warn>flag ramp off.</Warn>}
        <div class="row wrap">
          <Field label="ramp">
            <Input value={f.ramp} onValue={(v) => set({ ramp: v })} placeholder="0x…" />
          </Field>
          <Field label="token (USDC, no TestToken)">
            <Input value={f.token} onValue={(v) => set({ token: v })} placeholder="0x…" />
          </Field>
          <Field label="amount">
            <Input class="narrow" value={f.amount} onValue={(v) => set({ amount: v })} />
          </Field>
          <Field label="minAmountOut">
            <Input class="narrow" value={f.minAmountOut} onValue={(v) => set({ minAmountOut: v })} />
          </Field>
          <Field label="dest (LayerZero eid)">
            <Input class="narrow" value={f.dest} onValue={(v) => set({ dest: v })} />
          </Field>
          <Field label="to">
            <Input value={f.to} onValue={(v) => set({ to: v })} placeholder="0x…" />
          </Field>
          <Field label="refund (default: to)">
            <Input value={f.refund} onValue={(v) => set({ refund: v })} placeholder="0x…" />
          </Field>
        </div>
        <div class="row">
          <Button onClick={() => void runRampQuote()}>quote</Button>
          <Button tone="primary" disabled={!S.rampQuote.value || !!busy || !S.seatPk(S.activeRole.value)} busy={busy === "ramp.send"} onClick={() => void runRampSend()}>
            send como {S.activeRole.value} (msg.value = nativeFee)
          </Button>
        </div>
        {S.rampError.value && <Warn tone="bad">{S.rampError.value}</Warn>}
        {S.rampQuote.value && (
          <KV rows={[["nativeFee (wei)", <code>{S.rampQuote.value.nativeFee}</code>], ["amountOut", <code>{S.rampQuote.value.amountOut}</code>]]} />
        )}
        <Help>
          Flujo v1: Holder ya tiene USDC en Arbitrum → deal Core → <code>withdraw</code> si quedó crédito → <code>send</code>. Sin estados{" "}
          <code>BRIDGING_*</code>. <Badge tone="muted">approve(ramp, amount) antes de send</Badge>
        </Help>
      </Panel>
    </div>
  );
}
