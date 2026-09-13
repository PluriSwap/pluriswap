import { refreshPool, runPool, setDraft } from "../app/actions.ts";
import * as S from "../app/store.ts";
import { Addr, Badge, Button, Field, Help, Input, KV, Panel, Warn, fmtAmt } from "../ui/atoms.tsx";

export function PoolSpace() {
  const snap = S.poolSnap.value;
  const recinto = S.escrow.value;
  const mismatch = !!snap && !!recinto && snap.escrow.toLowerCase() !== recinto.toLowerCase();
  const f = S.poolForm.value;
  const busy = S.sending.value;
  return (
    <div>
      <header class="space-head">
        <h2>Pool</h2>
        <p>
          Un pool es un <strong>Holder contrato</strong>: firma los mismos <code>DealTerms</code> respondiendo EIP-1271 con bytes vacías. Su
          constitución (NAV, shares, idle/locked, agentes) vive acá, fuera de la vista kernel. El deal solo ve <code>holder = pool</code>.
        </p>
      </header>

      <Panel title="Pool en foco" kind="pool" right={S.suggestedPool() && <Button onClick={() => { S.poolPaste.value = S.suggestedPool()!; void refreshPool(); }}>usar pool del set</Button>}>
        <div class="row">
          <Input class="wide" value={S.poolPaste.value} onValue={(v) => (S.poolPaste.value = v.trim())} placeholder="pool 0x…" />
          <Button tone="primary" onClick={() => void refreshPool()}>
            leer
          </Button>
        </div>
        {S.poolError.value && <Warn tone="bad">{S.poolError.value}</Warn>}
        {mismatch && (
          <Warn tone="bad">
            Este pool firmó otro dominio: <code>pool.escrow()</code> = <Addr value={snap!.escrow} /> ≠ recinto en foco. <code>authorize</code> acá no sirve para este recinto.
          </Warn>
        )}
        {snap && (
          <KV
            rows={[
              ["life", <Badge tone={snap.lifeName === "ACTIVE" ? "ok" : "warn"}>{snap.lifeName}</Badge>],
              ["escrow apuntado", <span><Addr value={snap.escrow} full /> {!mismatch && <Badge tone="ok">= recinto</Badge>}</span>],
              ["token", <Addr value={snap.token} full />],
              ["idle / locked", <code>{fmtAmt(snap.idle)} / {fmtAmt(snap.locked)}</code>],
              ["credits / consumed", <code>{fmtAmt(snap.credits)} / {fmtAmt(snap.consumed)}</code>],
              ["nav / totalShares", <code>{fmtAmt(snap.nav)} / {fmtAmt(snap.totalShares)}</code>],
              ["controllerFeeBps", <code>{snap.controllerFeeBps}</code>],
              ["asiento activo es agente", snap.agent === null ? "—" : snap.agent ? <Badge tone="ok">sí</Badge> : <Badge tone="warn">no</Badge>],
            ]}
          />
        )}
      </Panel>

      <Panel title="Verbos de constitución" subtitle="Son del pool, no del deal. El asiento activo firma." kind="pool">
        <div class="row wrap">
          <Field label="deposit(amount)">
            <span class="row">
              <Input class="narrow" value={f.depositAmt} onValue={(v) => (S.poolForm.value = { ...f, depositAmt: v })} />
              <Button disabled={!!busy} busy={busy === "pool.deposit"} onClick={() => void runPool("deposit")}>
                deposit
              </Button>
            </span>
          </Field>
          <Field label="authorize(ha) — reserva idle para la HA del borrador" hint="Componé antes en Consentimiento con holder = pool y controller = agente.">
            <span class="row">
              <Button disabled={!!busy} busy={busy === "pool.authorize"} onClick={() => void runPool("authorize")}>
                authorize
              </Button>
              <Button onClick={() => { setDraft({ ...S.draft.value, holder: S.poolPaste.value, p2p: false }); S.holderIsPool.value = true; S.space.value = "consent"; }}>
                usar este pool como Holder →
              </Button>
            </span>
          </Field>
          <Field label="unlock(nonce) / reconcile(nonce, nonceP, nonceC)">
            <span class="row">
              <Input class="narrow" value={f.unlockNonce} onValue={(v) => (S.poolForm.value = { ...f, unlockNonce: v })} title="nonce de la HA" />
              <Input class="narrow" value={f.reconP} onValue={(v) => (S.poolForm.value = { ...f, reconP: v })} title="providerNonce" />
              <Input class="narrow" value={f.reconC} onValue={(v) => (S.poolForm.value = { ...f, reconC: v })} title="controllerNonce" />
              <Button disabled={!!busy} busy={busy === "pool.unlock"} onClick={() => void runPool("unlock")}>
                unlock
              </Button>
              <Button disabled={!!busy} busy={busy === "pool.reconcile"} onClick={() => void runPool("reconcile")}>
                reconcile
              </Button>
            </span>
          </Field>
        </div>
        <Help>
          <code>authorize</code> reserva <code>idle → locked</code> y habilita el <code>isValidSignature</code> del digest. Si el deal trae
          Reputation, el pool debe reservar también el <code>activationFee</code>. Kick de agente = <code>setController(addr, false)</code>,
          futuro-only: no silencia al Controller de un deal vivo.
        </Help>
      </Panel>
    </div>
  );
}
