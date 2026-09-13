import { currentPackageIds, fillSeatsIntoDraft, refreshPreflight, sendActivate, setDraft, signEnvelope, tryParsed } from "../app/actions.ts";
import * as S from "../app/store.ts";
import { revertDoc, shortReason } from "../content/reverts.ts";
import { isZeroAddress } from "../deal/types.ts";
import { parseModsDraft } from "../slots/probe.ts";
import { Addr, Badge, Button, Field, Help, Hex32, Input, Panel, Warn, fmtDur, short } from "../ui/atoms.tsx";

export function ConsentSpace() {
  const d = S.draft.value;
  const parsed = tryParsed();
  const ids = currentPackageIds();
  const mods = parseModsDraft(S.modsDraft.value);
  const packaged = S.flags.value.packages && Object.values(mods).some((a) => !isZeroAddress(a));
  const distinct = !d.p2p;
  const steps = S.preflight.value;
  const firstBad = steps.find((s) => !s.eval.enabled);
  const allOk = steps.length > 0 && !firstBad;
  const set = (patch: Partial<typeof d>) => setDraft({ ...d, ...patch });
  const dur = (field: "fiatDuration" | "releaseDuration" | "disputeDuration" | "arbitrationDuration", label: string, strict: boolean) => (
    <Field
      label={label}
      hint={
        d[field] === "0" ? (
          strict ? (
            <span class="bad">0 = due inmediato y strictly-before ya TooLate</span>
          ) : (
            "0 = due inmediato"
          )
        ) : (
          fmtDur(Number(d[field] || 0))
        )
      }
    >
      <Input class="narrow" value={d[field]} onValue={(v) => set({ [field]: v } as Partial<typeof d>)} />
    </Field>
  );

  return (
    <div>
      <header class="space-head">
        <h2>Consentimiento</h2>
        <p>
          Componer <code>DealTerms</code> y los envelopes de activación. Todavía no hay deal: el <code>dealId</code> se proyecta. El
          preflight reproduce el orden exacto de <code>_activate</code> y muestra el primer revert.
        </p>
      </header>

      <Panel title="1. Roles" kind="kernel" right={<Button onClick={fillSeatsIntoDraft}>copiar de los asientos</Button>}>
        <div class="row wrap">
          <Field label="holder">
            <Input value={d.holder} onValue={(v) => set({ holder: v, ...(d.p2p ? { controller: v } : {}) })} placeholder="0x…" />
          </Field>
          <Field label="provider">
            <Input value={d.provider} onValue={(v) => set({ provider: v })} placeholder="0x…" />
          </Field>
          <Field label={<span>controller {d.p2p && <Badge>= holder</Badge>}</span>}>
            <Input value={d.p2p ? d.holder : d.controller} disabled={d.p2p} onValue={(v) => set({ controller: v })} placeholder="0x…" />
          </Field>
          <label class="check">
            <input type="checkbox" checked={d.p2p} onChange={(e) => set({ p2p: (e.currentTarget as HTMLInputElement).checked, controller: (e.currentTarget as HTMLInputElement).checked ? d.holder : d.controller })} />
            P2P (holder == controller): dos firmas, CA dummy
          </label>
          <label class="check">
            <input
              type="checkbox"
              checked={S.holderIsPool.value}
              onChange={(e) => {
                S.holderIsPool.value = (e.currentTarget as HTMLInputElement).checked;
                if (S.holderIsPool.value) set({ p2p: false, holder: S.suggestedPool() ?? d.holder });
                else void refreshPreflight();
              }}
            />
            Holder es un Pool (EIP-1271, holderSig = "")
          </label>
        </div>
        <Help>
          Mismo <code>DealTerms</code> en los tres casos. Lo que cambia es cuántos envelopes se firman (2 o 3) y las bytes de{" "}
          <code>holderSig</code> (ECDSA o vacías para un pool).
        </Help>
      </Panel>

      <Panel title="2. Token, principal y duraciones" kind="kernel">
        <div class="row wrap">
          <Field label="token" hint={S.suggestedToken() ? <button type="button" class="link" onClick={() => set({ token: S.suggestedToken()! })}>usar testToken del set ({short(S.suggestedToken())})</button> : "el AddressBook no trae testToken para este recinto"}>
            <Input value={d.token} onValue={(v) => set({ token: v })} placeholder="0x…" />
          </Field>
          <Field label="principal (unidades del token)">
            <Input value={d.principal} onValue={(v) => set({ principal: v })} />
          </Field>
        </div>
        <div class="row wrap">
          {dur("fiatDuration", "fiatDuration (FUNDED → timeoutFiat)", false)}
          {dur("releaseDuration", "releaseDuration (FIAT_SENT → claim | openDisputed)", true)}
          {dur("disputeDuration", "disputeDuration (DISPUTED → forceStalemate | openCourt)", true)}
          {dur("arbitrationDuration", "arbitrationDuration (solo con ARBITRATION)", false)}
        </div>
        <Help>
          Segundos. <code>requireDue</code> es <code>now ≥ origin + duration</code>; <code>requireStrictlyBefore</code> es{" "}
          <code>now &lt; origin + duration</code>. Un 0 en releaseDuration deja al Controller sin poder disputar.
        </Help>
      </Panel>

      <Panel title="3. Paquetes" subtitle="Default: cinco slots nulos, packageIds = [], overload de 6 args." kind="kernel">
        {ids.length === 0 ? (
          <p>
            <Badge tone="info">Core-only</Badge> <span class="muted">packageIds = []</span>{" "}
            <Button onClick={() => (S.space.value = "packages")}>elegir paquetes →</Button>
          </p>
        ) : (
          <div>
            <p>
              <Badge tone="info">empaquetado</Badge> overload 7 args · {ids.length} id(s):
            </p>
            {ids.map((id) => (
              <div key={id}>
                <Hex32 value={id} />
              </div>
            ))}
            <Button onClick={() => (S.space.value = "packages")}>editar slots →</Button>
          </div>
        )}
      </Panel>

      <Panel title="4. Nonces y deadline de autorización" kind="kernel">
        <div class="row wrap">
          <Field label="holderNonce">
            <Input class="narrow" value={d.holderNonce} onValue={(v) => set({ holderNonce: v })} />
          </Field>
          <Field label="providerNonce">
            <Input class="narrow" value={d.providerNonce} onValue={(v) => set({ providerNonce: v })} />
          </Field>
          {distinct && (
            <Field label="controllerNonce">
              <Input class="narrow" value={d.controllerNonce} onValue={(v) => set({ controllerNonce: v })} />
            </Field>
          )}
          <Field label="deadline (unix)" hint={d.deadline ? new Date(Number(d.deadline) * 1000).toLocaleString() : ""}>
            <Input value={d.deadline} onValue={(v) => set({ deadline: v })} />
          </Field>
          <Button onClick={() => set({ deadline: String(Math.floor(Date.now() / 1000) + 86_400) })}>+24 h</Button>
        </div>
        <Help>
          Nonces libres, no secuenciales: <code>used[signer][nonce]</code> se chequea en vivo (preflight). El deadline es <em>creation
          expiry</em> del envelope, no un reloj del deal.
        </Help>
      </Panel>

      <Panel title="5. Firmas" subtitle="Cada asiento firma su envelope en el dominio del recinto en foco." kind="kernel">
        {!parsed && <Warn>Completá addresses válidas para holder, provider, controller y token.</Warn>}
        <div class="cols3">
          <SigCard
            title="HolderAuthorization"
            who="Holder"
            sig={S.holderIsPool.value ? "0x" : S.holderSig.value}
            note={S.holderIsPool.value ? "Pool: bytes vacías; el kernel pregunta isValidSignature al pool. Hacé pool.authorize(ha) antes." : undefined}
            onSign={() => void signEnvelope("HA")}
            disabled={!parsed || S.holderIsPool.value || !S.seatPk("Holder")}
          />
          <SigCard title="ProviderAgreement" who="Provider" sig={S.providerSig.value} onSign={() => void signEnvelope("PA")} disabled={!parsed || !S.seatPk("Provider")} />
          <SigCard
            title="ControllerAcceptance"
            who="Controller"
            sig={distinct ? S.controllerSig.value : "dummy"}
            note={distinct ? "Real: se hashea, verifica y consume." : "P2P: struct en ceros + bytes(''); el kernel la ignora."}
            onSign={() => void signEnvelope("CA")}
            disabled={!parsed || !distinct || !S.seatPk("Controller")}
          />
        </div>
        {parsed && (
          <details>
            <summary>Typed data anidado (lo que se firma)</summary>
            <pre>{JSON.stringify(
              {
                domain: { name: "PluriSwap", version: "1", chainId: S.effectiveChainId.value, verifyingContract: S.escrow.value },
                terms: { ...parsed.terms, principal: parsed.terms.principal.toString(), fiatDuration: parsed.terms.fiatDuration.toString(), releaseDuration: parsed.terms.releaseDuration.toString(), disputeDuration: parsed.terms.disputeDuration.toString(), arbitrationDuration: parsed.terms.arbitrationDuration.toString() },
                ha: { nonce: parsed.ha.nonce.toString(), deadline: parsed.ha.deadline.toString() },
                pa: { nonce: parsed.pa.nonce.toString(), deadline: parsed.pa.deadline.toString() },
                ca: distinct ? { nonce: parsed.ca.nonce.toString(), deadline: parsed.ca.deadline.toString() } : "dummy",
              },
              null,
              2,
            )}</pre>
          </details>
        )}
      </Panel>

      <Panel
        title="6. Preflight de activate"
        subtitle="Los mismos predicados, en el mismo orden que _activate + _resolve + _engage. El primer rojo es lo que revertiría."
        kind="derived"
        right={<Button onClick={() => void refreshPreflight()}>↻</Button>}
      >
        {S.projectedDealId.value && (
          <p>
            dealId proyectado: <Hex32 value={S.projectedDealId.value} />
          </p>
        )}
        {steps.length === 0 && <p class="muted">Sin preflight: falta un recinto probado o términos válidos.</p>}
        <ol class="preflight">
          {steps.map((s, i) => {
            const bad = !s.eval.enabled;
            const first = firstBad === s;
            return (
              <li key={i} class={bad ? (first ? "first-bad" : "bad") : "ok"}>
                <span class="pf-step">{s.step}</span>
                {bad ? <Badge tone={s.eval.reasonKind === "ui-policy" ? "muted" : "bad"}>{shortReason(s.eval.reason)}</Badge> : <Badge tone="ok">ok</Badge>}
                {first && <span class="pf-doc">{revertDoc(s.eval.reason) || s.eval.reason}</span>}
              </li>
            );
          })}
        </ol>
        {steps.some((s) => s.step.startsWith("_engage") && !s.eval.enabled) && (
          <Help>
            El pull final exige <code>allowance(holder → escrow) ≥ principal + activationFee</code>. El approve no está en la firma: hacelo
            desde Laboratorio (approve) o con tu wallet.
          </Help>
        )}
      </Panel>

      <Panel title="7. Enviar (Relayer)" kind="kernel">
        {parsed && (
          <p>
            Overload: <Badge tone="info">{packaged ? "activate(ha, sig, pa, sig, ca, sig, mods) — 7 args" : "activate(ha, sig, pa, sig, ca, sig) — 6 args"}</Badge>{" "}
            {!distinct && <Badge>CA dummy + bytes("")</Badge>} · relayer <Addr value={S.seatAddress("Relayer")} />
          </p>
        )}
        {S.sendError.value && <Warn tone="bad">{S.sendError.value}</Warn>}
        <div class="row">
          <Button tone="primary" disabled={!allOk || !S.seatPk("Relayer") || !!S.sending.value} busy={S.sending.value === "activate"} onClick={() => void sendActivate()}>
            enviar activate
          </Button>
          {!allOk && steps.length > 0 && <span class="muted">el preflight tiene un rojo: el kernel revertiría con {firstBad ? shortReason(firstBad.eval.reason) : ""}</span>}
          <Button
            disabled={!S.seatPk("Relayer") || !!S.sending.value}
            onClick={() => void sendActivate()}
            title="Para Paths negativos: enviar aunque el preflight esté en rojo y ver el revert real."
          >
            forzar envío (test negativo)
          </Button>
        </div>
        {S.lastActivated.value && (
          <p>
            Último activate: <Hex32 value={S.lastActivated.value.dealId} /> tx <code>{short(S.lastActivated.value.hash, 10, 6)}</code>
          </p>
        )}
      </Panel>
    </div>
  );
}

function SigCard(props: { title: string; who: string; sig: string | null; note?: string; onSign: () => void; disabled: boolean }) {
  const dummy = props.sig === "dummy";
  return (
    <div class={`card${dummy ? " muted" : ""}`}>
      <h4>
        {props.title} <Badge tone="info">{props.who}</Badge>
      </h4>
      <p>
        {dummy ? <Badge>dummy (no se firma)</Badge> : props.sig === "0x" ? <Badge tone="info">bytes vacías (1271)</Badge> : props.sig ? <Badge tone="ok">{short(props.sig, 8, 6)}</Badge> : <Badge>pendiente</Badge>}
      </p>
      {props.note && <p class="muted">{props.note}</p>}
      {!dummy && props.sig !== "0x" && (
        <Button onClick={props.onSign} disabled={props.disabled} title={props.disabled ? "asiento sin pk o términos inválidos" : ""}>
          firmar como {props.who}
        </Button>
      )}
    </div>
  );
}
