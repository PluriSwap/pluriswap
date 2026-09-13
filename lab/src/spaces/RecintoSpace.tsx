import { focusRecinto, loadDeal } from "../app/actions.ts";
import * as S from "../app/store.ts";
import { Addr, Badge, Button, Field, Help, Hex32, Input, KV, Panel, Warn } from "../ui/atoms.tsx";

export function RecintoSpace() {
  const p = S.probe.value;
  const e = S.escrow.value;
  return (
    <div>
      <header class="space-head">
        <h2>Recinto</h2>
        <p>
          Un recinto es <code>(chainId, escrow)</code>. El dominio EIP-712 <code>PluriSwap / 1 / chainId / escrow</code> acota todas las
          firmas. Cambiar de recinto descarta borradores, firmas y el deal en foco.
        </p>
      </header>

      <Panel title="Identidad EIP-712" kind="kernel">
        {!e && <Warn>Pegá una address de escrow en la barra superior o elegí una del AddressBook.</Warn>}
        {e && (
          <KV
            rows={[
              ["name / version", <code>PluriSwap / 1</code>],
              ["chainId", <code>{S.effectiveChainId.value}</code>],
              ["verifyingContract", <Addr value={e} full />],
              ["domainSeparator() on-chain", p?.domainSeparator ? <Hex32 value={p.domainSeparator} /> : <span class="muted">{p?.error ?? "sin leer"}</span>],
              ["esperado (hashDomain local)", p?.expectedDomainSeparator ? <Hex32 value={p.expectedDomainSeparator} /> : "—"],
              [
                "match",
                p === null ? (
                  <Badge>—</Badge>
                ) : p.domainMatches ? (
                  <Badge tone="ok">sí: firmar acá es firmar para este escrow</Badge>
                ) : (
                  <Badge tone="bad">no: chain o address equivocada; no firmar</Badge>
                ),
              ],
              ["código en la address", p?.codePresent === null || p === null ? "—" : p.codePresent ? <Badge tone="ok">sí</Badge> : <Badge tone="bad">no (EOA o chain distinta)</Badge>],
            ]}
          />
        )}
        <Help>
          El escrow no tiene “modo”: Core-only vs empaquetado es <em>por deal</em>. El constructor está vacío; cualquier impl compatible se
          resuelve por hash en <code>activate</code>.
        </Help>
      </Panel>

      <Panel title="Recintos conocidos (AddressBook)" subtitle="Atajos. Pegar cualquier otro escrow vale igual.">
        <table class="doc-table">
          <thead>
            <tr>
              <th>chain</th>
              <th>escrow</th>
              <th>archivos</th>
              <th>testToken (por archivo)</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {S.recintos.map((r) => {
              const on = e === r.escrow && S.chainId.value === r.chainId;
              return (
                <tr key={`${r.chainId}-${r.escrow}`} class={on ? "is-on" : ""}>
                  <td>{r.chainId}</td>
                  <td>
                    <Addr value={r.escrow} full noLabel />
                  </td>
                  <td>{r.sources.join(", ")}</td>
                  <td>
                    {r.testTokens.map((t) => (
                      <div key={t.sourceFile}>
                        <Addr value={t.token} noLabel /> <span class="muted">{t.sourceFile}</span>
                      </div>
                    ))}
                  </td>
                  <td>{on ? <Badge tone="info">en foco</Badge> : <Button onClick={() => focusRecinto(r)}>enfocar</Button>}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </Panel>

      <Panel title="Abrir un deal" subtitle="Por dealId, o por (signer, nonce) → dealOf." kind="kernel">
        <div class="row">
          <Field label="dealId (bytes32)">
            <Input value={S.lookup.value.dealId} onValue={(v) => (S.lookup.value = { ...S.lookup.value, dealId: v.trim() })} placeholder="0x…" class="wide" />
          </Field>
          <span class="muted">o</span>
          <Field label="signer">
            <Input value={S.lookup.value.signer} onValue={(v) => (S.lookup.value = { ...S.lookup.value, signer: v.trim() })} placeholder="0x…" />
          </Field>
          <Field label="nonce">
            <Input value={S.lookup.value.nonce} onValue={(v) => (S.lookup.value = { ...S.lookup.value, nonce: v.trim() })} placeholder="1" class="narrow" />
          </Field>
          <Button
            tone="primary"
            busy={S.dealLoading.value}
            onClick={async () => {
              await loadDeal();
              if (S.deal.value) S.space.value = "deal";
            }}
          >
            abrir
          </Button>
        </div>
        {S.dealError.value && <Warn tone="bad">{S.dealError.value}</Warn>}
        {S.dealShortcuts().length > 0 && (
          <div class="chips">
            <span class="muted">atajos del set:</span>
            {S.dealShortcuts().map((s) => (
              <button
                type="button"
                class="chip"
                key={s.label}
                onClick={async () => {
                  await loadDeal({ dealId: s.dealId, signer: "", nonce: "" });
                  if (S.deal.value) S.space.value = "deal";
                }}
              >
                {s.label} <span class="muted">{s.sourceFile}</span>
              </button>
            ))}
          </div>
        )}
        {S.lastActivated.value && (
          <p>
            Último activate de la sesión: <Hex32 value={S.lastActivated.value.dealId} />{" "}
            <Button onClick={() => void loadDeal({ dealId: S.lastActivated.value!.dealId, signer: "", nonce: "" }).then(() => (S.space.value = "deal"))}>
              abrir
            </Button>
          </p>
        )}
      </Panel>

      <Panel title="Txs de esta sesión" collapsed={S.txLog.value.length === 0}>
        {S.txLog.value.length === 0 && <p class="muted">Todavía no enviaste nada.</p>}
        <table class="doc-table">
          <tbody>
            {S.txLog.value.map((t) => (
              <tr key={t.at} class={t.error ? "is-bad" : ""}>
                <td class="muted">{new Date(t.at).toLocaleTimeString()}</td>
                <td>
                  <code>{t.verb}</code>
                </td>
                <td>{t.seat}</td>
                <td>
                  <Addr value={t.sender} />
                </td>
                <td>{t.dealId ? <Hex32 value={t.dealId} /> : "—"}</td>
                <td>{t.hash ? <code>{t.hash.slice(0, 12)}…</code> : <span class="bad">{t.error}</span>}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </Panel>
    </div>
  );
}
