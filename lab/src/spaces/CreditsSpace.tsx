import { useEffect } from "preact/hooks";
import { refreshCredits, withdrawFor } from "../app/actions.ts";
import * as S from "../app/store.ts";
import type { Role } from "../addressbook/types.ts";
import { Addr, Badge, Button, Field, Help, Input, Panel, Warn, fmtAmt } from "../ui/atoms.tsx";

export function CreditsSpace() {
  useEffect(() => {
    if (!S.creditToken.value) S.creditToken.value = S.deal.value?.terms.token ?? S.suggestedToken() ?? "";
    void refreshCredits();
  }, []);
  const busy = S.sending.value;
  return (
    <div>
      <header class="space-head">
        <h2>Créditos</h2>
        <p>
          Pasivo maduro del escrow tras un terminal (<em>credit-first</em>): el kernel acredita y luego intenta transferir; si el push
          falla, el saldo queda en <code>creditOf(token, beneficiary)</code> y se retira con <code>withdraw(token)</code>.
        </p>
      </header>
      <Panel title="creditOf por asiento" kind="kernel" right={<Button onClick={() => void refreshCredits()}>↻</Button>}>
        <div class="row wrap">
          <Field label="token">
            <Input class="wide" value={S.creditToken.value} onValue={(v) => (S.creditToken.value = v.trim())} placeholder="0x…" />
          </Field>
          <Field label="otra address (opcional)">
            <Input value={S.creditExtra.value} onValue={(v) => (S.creditExtra.value = v.trim())} placeholder="0x…" />
          </Field>
          <Button tone="primary" onClick={() => void refreshCredits()}>
            leer
          </Button>
        </div>
        {S.writeError.value && <Warn tone="bad">{S.writeError.value}</Warn>}
        <table class="doc-table">
          <thead>
            <tr>
              <th>quién</th>
              <th>address</th>
              <th>creditOf</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {S.creditRows.value.map((r) => (
              <tr key={`${r.who}-${r.address}`}>
                <td>{r.who}</td>
                <td>
                  <Addr value={r.address} full noLabel />
                </td>
                <td>
                  <code>{fmtAmt(r.amount)}</code>
                </td>
                <td>
                  {r.amount === 0n ? (
                    <Badge title="Settlement.withdraw retorna sin revertir con 0. Es política de UI no enviarlo.">no-op</Badge>
                  ) : (
                    <Button tone="primary" disabled={!!busy || !S.seatPk(r.who as Role)} busy={busy === `withdraw:${r.who}`} onClick={() => void withdrawFor(r.who as Role, r.token)}>
                      withdraw como {r.who}
                    </Button>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
        {S.creditRows.value.length === 0 && <p class="muted">Sin asientos con address, o sin token.</p>}
        <Help>
          Un crédito no es un deal: una address puede acumular créditos de varios deals en el mismo token. Después de retirar, la Rampa
          permite sacar USDC de Arbitrum (taxi).
        </Help>
      </Panel>
    </div>
  );
}
