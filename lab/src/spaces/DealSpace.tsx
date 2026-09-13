import { useState } from "preact/hooks";
import { currentMatrix, driftForDeal, dualDigests, loadDeal, refreshExtras, reloadDeal, relayDual, sendVerb, setActiveRole, setDualForm, signDual } from "../app/actions.ts";
import * as S from "../app/store.ts";
import type { Role } from "../addressbook/types.ts";
import { revertDoc, shortReason } from "../content/reverts.ts";
import { stateDoc, TERMINAL } from "../content/states.ts";
import { verbDoc } from "../content/verbs.ts";
import { deriveClocks } from "../deal/clocks.ts";
import { decodeKinds } from "../deal/kinds.ts";
import { Machine, type EdgeState } from "../deal/Machine.tsx";
import { PKG, Status, isZeroAddress, statusName, type DealSnapshot } from "../deal/types.ts";
import type { MatrixRow } from "../eligibility/matrix.ts";
import { DUAL_SIGN_TYPES } from "../session/DualSignDraft.ts";
import { slotRows } from "../slots/resolve.ts";
import { Addr, Badge, Button, Field, Help, Hex32, Input, KV, Panel, Warn, fmtAmt, fmtDur, fmtTs, short } from "../ui/atoms.tsx";

export function DealSpace() {
  const d = S.deal.value;
  if (!d) {
    return (
      <div>
        <header class="space-head">
          <h2>Deal</h2>
          <p>No hay deal en foco. Un deal nace en <code>activate</code>; antes no existe (<code>Status.NONE</code>).</p>
        </header>
        <Panel title="Abrir un deal" kind="kernel">
          <div class="row">
            <Input class="wide" value={S.lookup.value.dealId} onValue={(v) => (S.lookup.value = { ...S.lookup.value, dealId: v.trim() })} placeholder="dealId 0x…" />
            <Button tone="primary" busy={S.dealLoading.value} onClick={() => void loadDeal()}>
              abrir
            </Button>
            <Button onClick={() => (S.space.value = "consent")}>componer uno nuevo →</Button>
          </div>
          {S.dealError.value && <Warn tone="bad">{S.dealError.value}</Warn>}
          {S.dealShortcuts().length > 0 && (
            <div class="chips">
              {S.dealShortcuts().map((s) => (
                <button type="button" class="chip" key={s.label} onClick={() => void loadDeal({ dealId: s.dealId, signer: "", nonce: "" })}>
                  {s.label}
                </button>
              ))}
            </div>
          )}
        </Panel>
      </div>
    );
  }
  const matrix = currentMatrix();
  const doc = stateDoc(d.status);
  const evalOf = (verb: string): EdgeState => {
    const row = matrix.find((r) => r.verb === verb);
    if (!row) return "neutral";
    if (row.eval.enabled) return "enabled";
    if (row.eval.reason.includes("EdgeOff") || row.eval.reason.includes("PackageNotSelected")) return "off";
    return "disabled";
  };
  const coreOnly = d.terms.packageIds.length === 0;
  const p2p = d.terms.holder === d.terms.controller;
  return (
    <div>
      <header class="space-head deal-head">
        <div>
          <h2>
            Deal <Hex32 value={d.dealId} />
          </h2>
          <p>
            <Badge tone={TERMINAL.has(d.status) ? "muted" : "ok"}>{statusName(d.status)}</Badge> {doc.meaning}
          </p>
          <p class="muted">
            <strong>Jugada:</strong> {doc.ball}
          </p>
        </div>
        <div class="row">
          {coreOnly ? <Badge tone="info">Core-only</Badge> : <Badge tone="info">empaquetado · kinds {d.kinds}</Badge>}
          {p2p ? <Badge>P2P (holder = controller)</Badge> : <Badge>Controller distinto</Badge>}
          <Button onClick={() => void reloadDeal()} busy={S.dealLoading.value}>
            ↻ releer
          </Button>
        </div>
      </header>

      <Panel title="Máquina" subtitle="Nodo actual y aristas de este deal, evaluadas para el asiento activo. Click en una arista lleva a su fila." kind="kernel">
        <Machine status={d.status} kinds={d.kinds} evalOf={evalOf} onVerb={(v) => document.getElementById(`row-${v}`)?.scrollIntoView({ behavior: "smooth", block: "center" })} />
      </Panel>

      <Matrix deal={d} rows={matrix} />

      <div class="cols2">
        <TermsPanel deal={d} />
        <ClocksPanel deal={d} />
      </div>
      <div class="cols2">
        <SettlementPanel deal={d} />
        <KindsPanel deal={d} />
      </div>
      <DualSignPanel deal={d} rows={matrix} />
    </div>
  );
}

// --- matriz --------------------------------------------------------------------------------------------------------------------------

function Matrix(props: { deal: DealSnapshot; rows: MatrixRow[] }) {
  const sender = S.activeSender.value;
  const role = S.activeRole.value;
  const [open, setOpen] = useState<string | null>(null);
  const enabled = props.rows.filter((r) => r.eval.enabled);
  const otherSeat = props.rows.filter((r) => !r.eval.enabled && r.eval.reason === "Escrow.Unauthorized");
  const blocked = props.rows.filter((r) => !r.eval.enabled && r.eval.reason !== "Escrow.Unauthorized");
  const busy = S.sending.value;

  const Row = (r: MatrixRow) => {
    const vd = verbDoc(r.verb);
    const isOpen = open === r.verb;
    const canSend = r.eval.enabled && !!S.seatPk(role) && r.verb !== "activate";
    const dual = r.class === "dual-sign";
    return (
      <div class={`mrow ${r.eval.enabled ? "on" : "off"}`} id={`row-${r.verb}`} key={r.verb}>
        <div class="mrow-main" onClick={() => setOpen(isOpen ? null : r.verb)}>
          <code class="verb">{r.verb}</code>
          <span class="mrow-meta">
            <Badge tone={r.class === "rol" ? "info" : r.class === "dual-sign" ? "warn" : "muted"}>{r.class === "rol" ? r.senderSeat : r.class}</Badge>
            <span class="muted">{r.requiredStatus}</span>
            {r.kinds !== "n/a" && <span class="muted">{r.kinds}</span>}
            {r.clock !== "n/a" && <span class="muted">{r.clock}</span>}
          </span>
          <span class="mrow-state">
            {r.eval.enabled ? (
              <Badge tone="ok">ENABLED{r.eval.reason ? ` · ${r.eval.reason}` : ""}</Badge>
            ) : (
              <Badge tone={r.eval.reasonKind === "ui-policy" ? "muted" : "bad"} title={r.eval.reason}>
                {r.eval.reasonKind === "ui-policy" ? "ui: " : ""}
                {shortReason(r.eval.reason)}
              </Badge>
            )}
          </span>
          <span class="mrow-act">
            {dual ? (
              <Button tone="primary" disabled={!r.eval.enabled || !!busy} busy={busy === r.verb} onClick={() => void relayDual()}>
                relay
              </Button>
            ) : r.verb === "activate" ? (
              <Button onClick={() => (S.space.value = "consent")}>Consentimiento →</Button>
            ) : r.verb === "cancelNonce" ? (
              <span class="row">
                <Input class="narrow" value={S.cancelNonceInput.value} onValue={(v) => (S.cancelNonceInput.value = v)} />
                <Button tone="primary" disabled={!canSend || !!busy} busy={busy === r.verb} onClick={() => void sendVerb(r.verb)}>
                  enviar
                </Button>
              </span>
            ) : (
              <Button tone="primary" disabled={!canSend || !!busy} busy={busy === r.verb} onClick={() => void sendVerb(r.verb)} title={!S.seatPk(role) ? "el asiento activo no tiene pk" : ""}>
                enviar como {role}
              </Button>
            )}
          </span>
        </div>
        {isOpen && (
          <div class="mrow-doc">
            {!r.eval.enabled && <p class="reason">{revertDoc(r.eval.reason) || r.eval.reason}</p>}
            {vd && (
              <KV
                rows={[
                  ["quién", vd.who],
                  ["desde → hacia", <span><code>{vd.from}</code> → <code>{vd.to}</code></span>],
                  ...(vd.clock ? ([["reloj", vd.clock]] as [string, string][]) : []),
                  ["plata", vd.money],
                  ["para qué", vd.why],
                  ...(vd.packages ? ([["paquetes", vd.packages]] as [string, string][]) : []),
                ]}
              />
            )}
            {r.eval.reason === "Escrow.Unauthorized" && (
              <div class="row">
                <span class="muted">Cambiar al asiento que corresponde:</span>
                <Button onClick={() => setActiveRole(r.senderSeat as Role)}>activar {r.senderSeat}</Button>
              </div>
            )}
          </div>
        )}
      </div>
    );
  };

  return (
    <Panel
      title="Matriz de elegibilidad"
      subtitle={
        <>
          Todos los entrypoints de <code>Escrow.sol</code>, siempre visibles. Evaluados para <strong>{role}</strong>{" "}
          {sender ? <Addr value={sender} /> : <Badge tone="warn">sin address: pegá una en el asiento</Badge>}. Click en una fila para leer qué hace y por qué revertiría.
        </>
      }
      kind="kernel"
      right={
        <Button onClick={() => void refreshExtras()} title="releer crédito, ruling, policy">
          ↻
        </Button>
      }
    >
      {S.writeError.value && <Warn tone="bad">{S.writeError.value}</Warn>}
      <h4 class="mgroup">Legal ahora para {role} ({enabled.length})</h4>
      {enabled.length === 0 && <p class="muted">Nada. Cambiá de asiento o esperá un reloj.</p>}
      {enabled.map(Row)}
      {otherSeat.length > 0 && (
        <>
          <h4 class="mgroup">Legal, pero desde otro asiento ({otherSeat.length})</h4>
          {otherSeat.map(Row)}
        </>
      )}
      <h4 class="mgroup">Revertiría ({blocked.length})</h4>
      {blocked.map(Row)}
    </Panel>
  );
}

// --- términos ---------------------------------------------------------------------------------------------------------------------------

function TermsPanel(props: { deal: DealSnapshot }) {
  const t = props.deal.terms;
  return (
    <Panel title="Términos firmados" subtitle="DealTerms tal como los hashearon los envelopes. Snapshot: no hay términos vivos." kind="kernel">
      <KV
        rows={[
          ["holder", <Addr value={t.holder} full />],
          ["provider", <Addr value={t.provider} full />],
          ["controller", <span><Addr value={t.controller} full /> {t.controller === t.holder && <Badge>= holder (P2P)</Badge>}</span>],
          ["token", <Addr value={t.token} full />],
          ["principal", <code>{fmtAmt(t.principal)}</code>],
          ["fiatDuration", <code>{t.fiatDuration.toString()} ({fmtDur(t.fiatDuration)})</code>],
          ["releaseDuration", <code>{t.releaseDuration.toString()} ({fmtDur(t.releaseDuration)})</code>],
          ["disputeDuration", <code>{t.disputeDuration.toString()} ({fmtDur(t.disputeDuration)})</code>],
          ["arbitrationDuration", <code>{t.arbitrationDuration.toString()} ({fmtDur(t.arbitrationDuration)}){(props.deal.kinds & PKG.ARB) === 0 ? " — ignorada sin ARBITRATION" : ""}</code>],
          [
            "packageIds",
            t.packageIds.length === 0 ? (
              <Badge tone="info">[] Core-only</Badge>
            ) : (
              <div>
                {t.packageIds.map((id) => (
                  <div key={id}>
                    <Hex32 value={id} />
                  </div>
                ))}
              </div>
            ),
          ],
          ["subjects", <span><Hex32 value={props.deal.subjects.holderSubject} /> / <Hex32 value={props.deal.subjects.providerSubject} /> <span class="muted">(bytes32; 0x0 en Core-only; no son “humanos”)</span></span>],
        ]}
      />
    </Panel>
  );
}

// --- relojes ------------------------------------------------------------------------------------------------------------------------------

function ClocksPanel(props: { deal: DealSnapshot }) {
  const now = S.chainHead.value?.timestamp ?? props.deal.blockTimestamp;
  const rows = deriveClocks(props.deal.clocks, props.deal.terms, now);
  return (
    <Panel title="Relojes" subtitle={<>Derivados con la aritmética de <code>Clocks.sol</code>. now = block.timestamp del RPC ({fmtTs(now)}).</>} kind="derived">
      {rows.map((r) => {
        const started = r.origin !== 0n;
        const remaining = r.deadline !== null ? Number(r.deadline - now) : null;
        return (
          <div class={`clock${started ? "" : " muted"}`} key={r.name}>
            <div class="clock-head">
              <strong>{r.name}</strong>
              <code>
                {r.originName} + {r.durationField} = {r.deadline !== null ? r.deadline.toString() : r.overflow ? "overflow" : "no arrancó"}
              </code>
            </div>
            {started && r.deadline !== null && (
              <div class="clock-bar">
                <div class="clock-fill" style={{ width: `${Math.max(0, Math.min(100, (Number(now - r.origin) / Math.max(1, Number(r.duration))) * 100))}%` }} />
              </div>
            )}
            <div class="clock-preds">
              <span>
                due (<code>{r.dueVerb}</code>):{" "}
                {r.due === null ? <Badge>n/a</Badge> : r.due ? <Badge tone="ok">sí</Badge> : <Badge tone="warn">TooEarly · faltan {fmtDur(remaining ?? 0)}</Badge>}
              </span>
              {r.strictlyBeforeVerb !== "—" && (
                <span>
                  strictly-before (<code>{r.strictlyBeforeVerb}</code>):{" "}
                  {r.strictlyBefore === null ? <Badge>n/a</Badge> : r.strictlyBefore ? <Badge tone="ok">abierto · {fmtDur(remaining ?? 0)}</Badge> : <Badge tone="bad">TooLate</Badge>}
                </span>
              )}
              {r.duration === 0n && r.strictlyBeforeVerb !== "—" && <Badge tone="warn">duration = 0 cierra strictly-before para siempre</Badge>}
              {r.overflow && <Badge tone="bad">origin + duration desborda: timeout irllamable</Badge>}
            </div>
          </div>
        );
      })}
      {S.isAnvil.value && (
        <Help>
          En Anvil podés avanzar <code>block.timestamp</code> desde <button type="button" class="link" onClick={() => (S.space.value = "lab")}>Laboratorio</button> (reloj LAB).
        </Help>
      )}
    </Panel>
  );
}

// --- settlement -----------------------------------------------------------------------------------------------------------------------------

function SettlementPanel(props: { deal: DealSnapshot }) {
  const d = props.deal;
  const s = d.settlement;
  const terminal = TERMINAL.has(d.status);
  const rep = (d.kinds & PKG.REP) !== 0;
  const fee = S.dealPolicy.value.reputation?.completionFee ?? null;
  const p = d.terms.principal;
  const proj = (bps: number, invoiced: boolean) => {
    const f = invoiced && fee !== null && fee <= p ? fee : 0n;
    const pot = p - f;
    const prov = (pot * BigInt(bps)) / 10000n;
    return { fee: f, prov, hold: pot - prov };
  };
  return (
    <Panel title="Settlement" subtitle={terminal ? "Observado: settlementOf on-chain." : "Proyectado: qué pagaría cada cierre posible desde acá."} kind={terminal ? "kernel" : "derived"}>
      {terminal ? (
        <KV
          rows={[
            ["status", <code>{statusName(s.status)}</code>],
            ["holderAmt", <code>{fmtAmt(s.holderAmt)}</code>],
            ["providerAmt", <code>{fmtAmt(s.providerAmt)}</code>],
            ["invoice (derivado)", <code>{fmtAmt(p - s.holderAmt - s.providerAmt)}</code>],
          ]}
        />
      ) : (
        <table class="doc-table">
          <thead>
            <tr>
              <th>cierre</th>
              <th>fee</th>
              <th>Holder</th>
              <th>Provider</th>
            </tr>
          </thead>
          <tbody>
            {[
              ["release / coSignedRelease / claim", proj(10000, rep)],
              ["mutualSplit (bps del composer)", proj(Number(S.dualForm.value.providerBps || "0"), rep)],
              ["cancel / timeoutFiat / mutualCancel", proj(0, false)],
              ["forceStalemate / arb 3 / arb timeout", proj(5000, rep)],
            ].map(([k, v]) => {
              const r = v as { fee: bigint; prov: bigint; hold: bigint };
              return (
                <tr key={k as string}>
                  <td>{k as string}</td>
                  <td>
                    <code>{fmtAmt(r.fee)}</code>
                  </td>
                  <td>
                    <code>{fmtAmt(r.hold)}</code>
                  </td>
                  <td>
                    <code>{fmtAmt(r.prov)}</code>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      )}
      <Help>
        {rep
          ? `Reputation activo: completionFee = ${fee === null ? "?" : fmtAmt(fee)} se cobra sobre el total siempre que el Provider reciba algo (KERNEL-04: si no entra, se omite).`
          : "Sin Reputation no hay completion fee: el principal se reparte entero."}{" "}
        Credit-first: si el push falla, queda en <code>creditOf</code> (Créditos).
      </Help>
      {S.credit.value !== null && (
        <p>
          creditOf({short(d.terms.token)}, {S.activeRole.value}) = <code>{fmtAmt(S.credit.value)}</code>
        </p>
      )}
    </Panel>
  );
}

// --- kinds / módulos -----------------------------------------------------------------------------------------------------------------------

function KindsPanel(props: { deal: DealSnapshot }) {
  const d = props.deal;
  const flags = decodeKinds(d.kinds);
  const rows = slotRows(d.modules, d.terms.packageIds, S.dealPolicy.value, S.escrowPaste.value).filter((r) => r.address);
  const drift = driftForDeal().filter((r) => r.liveId !== null && !r.inSigned);
  return (
    <Panel
      title="Kinds y módulos"
      subtitle="Bitmap kinds + snapshot modules + recompute vivo del PackageId contra los ids firmados."
      kind="kernel"
      right={drift.length > 0 ? <Badge tone="warn">DRIFT ×{drift.length}</Badge> : undefined}
    >
      <div class="chips">
        {flags.map((f) => (
          <Badge key={f.name} tone={f.on ? "ok" : "muted"}>
            {f.bit} {f.name}
          </Badge>
        ))}
        <span class="muted">= {d.kinds}</span>
      </div>
      {rows.length === 0 ? (
        <Help>Core-only: los cinco slots son nulos. No es que “falten” paquetes; es un modo.</Help>
      ) : (
        <table class="doc-table">
          <thead>
            <tr>
              <th>slot</th>
              <th>impl</th>
              <th>id vivo ∈ firmados</th>
              <th>binding</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.slot}>
                <td>
                  <code>{r.slot}</code>
                </td>
                <td>
                  <Addr value={r.address} />
                </td>
                <td>{r.id === null ? <Badge>sin leer</Badge> : r.inIds ? <Badge tone="ok">match</Badge> : <Badge tone="warn">DRIFT</Badge>}</td>
                <td>
                  {r.getter === "none" ? (
                    <span class="muted">sin getter</span>
                  ) : (
                    <span>
                      <code>{r.getter}()</code> {r.matchesRecinto === null ? "—" : r.matchesRecinto ? <Badge tone="ok">= recinto</Badge> : <Badge tone="bad">≠ recinto</Badge>}
                    </span>
                  )}
                </td>
                <td>{r.lab && <Badge tone="lab">LAB</Badge>}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      {drift.length > 0 && (
        <Warn>
          Un módulo cambió su policy después de activate. El kernel omite su fee y hace fail-open en bonds; las salidas Core siguen. La matriz
          marca <code>PackageDrift</code> solo en verifyProof / openCourt.
        </Warn>
      )}
      {S.courtPref.value && (
        <KV
          rows={[
            ["tribunal", S.courtPref.value.kind === "kleros" ? "KlerosAdapter (Kleros V2)" : S.courtPref.value.kind === "mock" ? "ArbitrationMock (LAB)" : "desconocido"],
            ...(S.courtPref.value.kind === "kleros"
              ? ([["msg.value exacto = arbitrationCost(extraData)", <code>{fmtAmt(S.courtPref.value.cost)} wei</code>]] as [string, preact.JSX.Element][])
              : ([
                  ["courtFee (ERC-20 al court)", <code>{fmtAmt(S.courtPref.value.courtFee)}</code>],
                  ["allowance(controller → court)", <code>{fmtAmt(S.courtPref.value.allowance)}</code>],
                ] as [string, preact.JSX.Element][])),
            ["ruling en el módulo", <code>{S.ruling.value ?? "—"}</code>],
          ]}
        />
      )}
      {!isZeroAddress(d.modules.court) && S.courtPref.value?.kind === "kleros" && d.status === Status.ARBITRATION_ACTIVE && (
        <Help>
          Caso abierto en Kleros. La evidencia y la votación ocurren en la dapp de Kleros (court.kleros.io). Acá solo queda esperar y luego{" "}
          <code>readRuling</code>.
        </Help>
      )}
    </Panel>
  );
}

// --- dual-sign -------------------------------------------------------------------------------------------------------------------------------

function DualSignPanel(props: { deal: DealSnapshot; rows: MatrixRow[] }) {
  const f = S.dualForm.value;
  const dg = dualDigests();
  const rows = props.rows.filter((r) => r.class === "dual-sign");
  const verbOf = f.type ? `${f.type[0]!.toLowerCase()}${f.type.slice(1)}` : null;
  const row = rows.find((r) => r.verb === verbOf);
  const dead = f.deadline ? Number(f.deadline) : 0;
  return (
    <Panel
      title="Composer dual-sign"
      subtitle="Objeto de sesión (DualSignDraft). Dos envelopes (Provider y Controller) sobre el mismo dealId y deadline; el Relayer envía una tx. La matriz lee este borrador."
      kind="kernel"
      collapsed={TERMINAL.has(props.deal.status)}
    >
      <div class="row wrap">
        <Field label="type">
          <select value={f.type} onChange={(e) => setDualForm({ ...f, type: (e.currentTarget as HTMLSelectElement).value as typeof f.type, providerSig: null, controllerSig: null })}>
            <option value="">— elegir —</option>
            {DUAL_SIGN_TYPES.map((t) => (
              <option key={t} value={t}>
                {t}
              </option>
            ))}
          </select>
        </Field>
        <Field label="deadline (unix)" hint={dead ? new Date(dead * 1000).toLocaleString() : "expiry del payload, no un reloj del deal"}>
          <Input value={f.deadline} onValue={(v) => setDualForm({ ...f, deadline: v, providerSig: null, controllerSig: null })} />
        </Field>
        <Field label="nonceP" hint={S.dsUsedP.value ? "usado" : "libre"}>
          <Input class="narrow" value={f.nonceP} onValue={(v) => setDualForm({ ...f, nonceP: v, providerSig: null })} />
        </Field>
        <Field label="nonceC" hint={S.dsUsedC.value ? "usado" : "libre"}>
          <Input class="narrow" value={f.nonceC} onValue={(v) => setDualForm({ ...f, nonceC: v, controllerSig: null })} />
        </Field>
        {f.type === "MutualSplit" && (
          <Field label="providerBps" hint="idéntico en ambas copias; 10000 sigue siendo split">
            <Input class="narrow" value={f.providerBps} onValue={(v) => setDualForm({ ...f, providerBps: v, providerSig: null, controllerSig: null })} />
          </Field>
        )}
      </div>
      <div class="cols2">
        <div class="card">
          <h4>Envelope Provider</h4>
          <p class="muted">digest: {dg.p ? <Hex32 value={dg.p} /> : "—"}</p>
          <p>
            firma: {f.providerSig ? <Badge tone="ok">{short(f.providerSig, 8, 6)}</Badge> : <Badge>pendiente</Badge>}{" "}
            {S.recoveredP.value && (S.recoveredP.value.toLowerCase() === props.deal.terms.provider.toLowerCase() ? <Badge tone="ok">recupera al Provider</Badge> : <Badge tone="bad">recupera otra address</Badge>)}
          </p>
          <Button onClick={() => void signDual("P")} disabled={!f.type || !S.seatPk("Provider")} title={!S.seatPk("Provider") ? "asiento Provider sin pk" : ""}>
            firmar como Provider
          </Button>
        </div>
        <div class="card">
          <h4>Envelope Controller</h4>
          <p class="muted">digest: {dg.c ? <Hex32 value={dg.c} /> : "—"}</p>
          <p>
            firma: {f.controllerSig ? <Badge tone="ok">{short(f.controllerSig, 8, 6)}</Badge> : <Badge>pendiente</Badge>}{" "}
            {S.recoveredC.value && (S.recoveredC.value.toLowerCase() === props.deal.terms.controller.toLowerCase() ? <Badge tone="ok">recupera al Controller</Badge> : <Badge tone="bad">recupera otra address</Badge>)}
          </p>
          <Button onClick={() => void signDual("C")} disabled={!f.type || (!S.seatPk("Controller") && !(S.p2pSeats.value && S.seatPk("Holder")))}>
            firmar como Controller{props.deal.terms.holder === props.deal.terms.controller ? " (= Holder)" : ""}
          </Button>
        </div>
      </div>
      <div class="row">
        <Button tone="primary" disabled={!row?.eval.enabled || !!S.sending.value} busy={S.sending.value === verbOf} onClick={() => void relayDual()}>
          relay {verbOf ?? "…"} como Relayer
        </Button>
        {row && !row.eval.enabled && (
          <span>
            <Badge tone={row.eval.reasonKind === "ui-policy" ? "muted" : "bad"}>{shortReason(row.eval.reason)}</Badge> <span class="muted">{revertDoc(row.eval.reason)}</span>
          </span>
        )}
      </div>
      <Help>
        Orden de checks del kernel con draft completo: DealIdMismatch → DeadlineMismatch → DeadlinePassed → (BpsMismatch) → WrongStatus →
        Invalid*Signature → NonceUsed. Si el relay revierte no se consume ningún nonce. Cambiar de recinto descarta el draft.
      </Help>
    </Panel>
  );
}
