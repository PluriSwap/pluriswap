import { encodeLabProof, runLab } from "../app/actions.ts";
import * as S from "../app/store.ts";
import { packageIdSubjectHint } from "../lab/subject.ts";
import { Addr, Badge, Button, Field, Help, Input, Panel, Warn, short } from "../ui/atoms.tsx";

export function LabSpace() {
  const f = S.labForm.value;
  const set = (patch: Partial<typeof f>) => (S.labForm.value = { ...f, ...patch });
  const busy = S.sending.value;
  const token = S.draft.value.token || S.suggestedToken() || "";
  const passport = S.modsDraft.value.passport || S.deal.value?.modules.passport || "";
  const court = S.modsDraft.value.court || S.deal.value?.modules.court || "";
  const role = S.activeRole.value;
  const hasPk = !!S.seatPk(role);
  return (
    <div class="lab">
      <header class="space-head">
        <h2>
          Laboratorio <Badge tone="lab">LAB</Badge>
        </h2>
        <p>
          Verbos de <strong>mocks y utilidades de prueba</strong>. Nada de esto es Passport, un circuito ZK, un tribunal ni un activo real.
          Se muestran con sus nombres on-chain crudos para que nadie los confunda con el kernel. Envía el asiento activo (<strong>{role}</strong>
          {hasPk ? "" : ", sin pk: no puede enviar"}).
        </p>
      </header>
      {S.labError.value && <Warn tone="bad">{S.labError.value}</Warn>}
      {!S.flags.value.labVerbs && <Warn>flag labVerbs off: los formularios se ven pero no envían.</Warn>}

      <div class="cols2">
        <Panel title="TestToken.mint / approve" subtitle="Faucet y allowance. El approve al escrow no está en la firma EIP-712." kind="lab">
          <p class="muted">
            token: <Addr value={token || null} /> {!token && "(elegí token en Consentimiento)"}
          </p>
          <div class="row wrap">
            <Field label="mint(to, amount)">
              <span class="row">
                <Input value={f.mintTo} onValue={(v) => set({ mintTo: v })} placeholder="to 0x…" />
                <Input class="narrow" value={f.mintAmount} onValue={(v) => set({ mintAmount: v })} />
                <Button tone="lab" disabled={!!busy || !hasPk} busy={busy === "mint"} onClick={() => void runLab("mint")}>
                  mint
                </Button>
              </span>
            </Field>
          </div>
          <div class="chips">
            <span class="muted">to:</span>
            {(["Holder", "Provider", "Controller"] as const).map((r) => S.seatAddress(r) && <button type="button" class="chip" key={r} onClick={() => set({ mintTo: S.seatAddress(r)! })}>{r}</button>)}
          </div>
          <div class="row wrap">
            <Field label={`approve(spender, amount) desde ${role}`}>
              <span class="row">
                <Input value={f.approveSpender} onValue={(v) => set({ approveSpender: v })} placeholder="spender 0x…" />
                <Input class="narrow" value={f.approveAmount} onValue={(v) => set({ approveAmount: v })} />
                <Button tone="lab" disabled={!!busy || !hasPk} busy={busy === "approve"} onClick={() => void runLab("approve")}>
                  approve
                </Button>
              </span>
            </Field>
          </div>
          <div class="chips">
            <span class="muted">spender:</span>
            {S.escrow.value && <button type="button" class="chip" onClick={() => set({ approveSpender: S.escrow.value! })}>escrow (principal + activationFee)</button>}
            {S.modsDraft.value.bonds && <button type="button" class="chip" onClick={() => set({ approveSpender: S.modsDraft.value.bonds })}>vault (bond)</button>}
            {court && <button type="button" class="chip" onClick={() => set({ approveSpender: court })}>court (courtFee, ArbitrationMock)</button>}
          </div>
        </Panel>

        <Panel title="PassportMock.setHuman(wallet, subject)" subtitle="Mapa wallet → bytes32 sin control de acceso. No verifica humanidad." kind="lab">
          <p class="muted">
            passport: <Addr value={passport || null} /> {!passport && "(pegá el slot passport en Paquetes)"}
          </p>
          <div class="row wrap">
            <Field label="wallet">
              <Input value={f.wallet} onValue={(v) => set({ wallet: v })} placeholder="0x…" />
            </Field>
            <Field label="subject (bytes32)" hint={<button type="button" class="link" onClick={() => set({ subject: packageIdSubjectHint(f.wallet) })}>derivar de la wallet (keccak)</button>}>
              <Input class="wide" value={f.subject} onValue={(v) => set({ subject: v })} placeholder="0x… 32 bytes" />
            </Field>
            <Button tone="lab" disabled={!!busy || !hasPk} busy={busy === "setHuman"} onClick={() => void runLab("setHuman")}>
              setHuman
            </Button>
          </div>
          <div class="chips">
            <span class="muted">wallet:</span>
            {(["Holder", "Provider"] as const).map((r) => S.seatAddress(r) && <button type="button" class="chip" key={r} onClick={() => set({ wallet: S.seatAddress(r)! })}>{r}</button>)}
          </div>
          <Help>
            En producción el adapter es <code>HumanPassport</code> (Human Passport, ex Gitcoin): responde si la wallet es humana; el subject es
            la wallet misma. El mock solo sirve para ejercitar <code>identify</code>, cap y bonds.
          </Help>
        </Panel>

        <Panel title="BondVault.deposit(subject, token, amount)" subtitle="Skin del sujeto. El kernel bloquea (principal + 9) / 10 por deal." kind="lab">
          <div class="row wrap">
            <Field label="vault">
              <Input value={f.vault} onValue={(v) => set({ vault: v })} placeholder="0x…" />
              {S.modsDraft.value.bonds && <button type="button" class="link" onClick={() => set({ vault: S.modsDraft.value.bonds })}>usar slot bonds</button>}
            </Field>
            <Field label="amount">
              <Input class="narrow" value={f.depositAmount} onValue={(v) => set({ depositAmount: v })} />
            </Field>
            <Button tone="lab" disabled={!!busy || !hasPk} busy={busy === "deposit"} onClick={() => void runLab("deposit")}>
              deposit
            </Button>
          </div>
          <Help>Usa el subject del formulario de arriba. Antes: approve(vault, amount). withdraw exige identify(msg.sender) == subject.</Help>
        </Panel>

        <Panel title="VerifierMock: proof = abi.encode(dealId, nullifier)" subtitle="El módulo hace abi.decode y compara dealId. No hay circuito." kind="lab">
          <div class="row wrap">
            <Field label="dealId" hint={S.deal.value ? <button type="button" class="link" onClick={() => set({ dealId: S.deal.value!.dealId })}>usar el deal en foco</button> : "abrí un deal ZK"}>
              <Input class="wide" value={f.dealId} onValue={(v) => set({ dealId: v })} placeholder="0x… (deal en foco si vacío)" />
            </Field>
            <Field label="nullifier (bytes32)" hint={<button type="button" class="link" onClick={() => set({ nullifier: packageIdSubjectHint(`nullifier-${Date.now()}`) })}>aleatorio</button>}>
              <Input class="wide" value={f.nullifier} onValue={(v) => set({ nullifier: v })} placeholder="0x…" />
            </Field>
            <Button tone="lab" onClick={encodeLabProof}>
              ensamblar payload
            </Button>
          </div>
          {S.labProof.value && (
            <p>
              payload listo: <code>{short(S.labProof.value, 14, 8)}</code> → la fila <code>verifyProof</code> de la matriz lo usa.
            </p>
          )}
        </Panel>

        <Panel title="ArbitrationMock.submitRuling(dealId, ruling)" subtitle="Escribe la sentencia sin auth. Después readRuling es legal." kind="lab">
          <p class="muted">
            court: <Addr value={court || null} /> {S.courtPref.value?.kind === "kleros" && <Badge tone="warn">este court es Kleros: submitRuling no existe</Badge>}
          </p>
          <div class="row wrap">
            <Field label="ruling">
              <select value={f.ruling} onChange={(e) => set({ ruling: (e.currentTarget as HTMLSelectElement).value })}>
                <option value="1">1 · HolderWin (refund, bond Provider → Holder)</option>
                <option value="2">2 · ProviderWin (payout, bond Holder → Provider)</option>
                <option value="3">3 · Stalemate (50/50, bonds unlock)</option>
              </select>
            </Field>
            <Button tone="lab" disabled={!!busy || !hasPk || S.courtPref.value?.kind === "kleros"} busy={busy === "submitRuling"} onClick={() => void runLab("submitRuling")}>
              submitRuling
            </Button>
          </div>
          <Help>
            <code>ArbitrationMock.open()</code> no se expone: un extraño puede llamarlo y dejar <code>AlreadyOpen</code> (grief documentado).
          </Help>
        </Panel>

        <Panel title="Reloj Anvil: evm_increaseTime" subtitle="Avanza block.timestamp en 31337 y mina un bloque. No es un verbo kernel." kind="lab">
          {!S.isAnvil.value ? (
            <Warn>Solo en Anvil (31337). En Sepolia no hay warp: los Paths usan duration = 0 en el reloj que quieren vencer.</Warn>
          ) : (
            <div class="row wrap">
              <Field label="segundos">
                <Input class="narrow" value={f.warp} onValue={(v) => set({ warp: v })} />
              </Field>
              <Button tone="lab" disabled={!!busy} busy={busy === "warp"} onClick={() => void runLab("warp")}>
                avanzar
              </Button>
              {[100, 1800, 3600, 7200, 86_400].map((s) => (
                <button type="button" class="chip" key={s} onClick={() => set({ warp: String(s) })}>
                  +{s}s
                </button>
              ))}
            </div>
          )}
        </Panel>
      </div>

      <Panel title="Registro LAB" collapsed={S.labLog.value.length === 0}>
        {S.labLog.value.length === 0 && <p class="muted">Nada todavía.</p>}
        <ul>
          {S.labLog.value.map((l, i) => (
            <li key={i}>
              <code>{l.verb}</code> {l.hash && <span class="muted">{short(l.hash, 10, 6)}</span>} — {l.note}
            </li>
          ))}
        </ul>
      </Panel>
    </div>
  );
}
