import { currentPackageIds, refreshSlots, setIdsOverride, setModsDraft } from "../app/actions.ts";
import * as S from "../app/store.ts";
import { revertDoc, shortReason } from "../content/reverts.ts";
import type { PackageMods } from "../deal/types.ts";
import { parseModsDraft } from "../slots/probe.ts";
import { firstEngageRevert, firstResolveRevert, slotRows } from "../slots/resolve.ts";
import { emptyModsDraft } from "../slots/types.ts";
import { Addr, Badge, Button, Field, Help, Hex32, Input, KV, Panel, Warn, fmtAmt } from "../ui/atoms.tsx";

const SLOT_DOC: Record<keyof PackageMods, { title: string; formula: string; needs?: string; iface: string }> = {
  passport: { title: "PASSPORT", formula: "keccak256(PASSPORT_KIND, adapter)", iface: "IPassport.identify(wallet) → bytes32" },
  reputation: { title: "REPUTATION", formula: "keccak256(REPUTATION_KIND, module, feeRecipient, activationFee, completionFee)", needs: "Passport", iface: "IReputation.admit / notifyTerminal" },
  bonds: { title: "BONDS", formula: "keccak256(BONDS_KIND, vault, sink, 1000)", needs: "Passport + Reputation", iface: "IBondVault.reserve / unlock / slash / burn" },
  zk: { title: "ZK", formula: "keccak256(ZK_KIND, module, verifier, feeRecipient, verifyFee)", needs: "¬ARBITRATION", iface: "IPaymentProof.verifyProof" },
  court: { title: "ARBITRATION", formula: "keccak256(ARBITRATION_KIND, adapter, partner, key)", needs: "¬ZK", iface: "ICourt.openCourt / readRuling" },
};

export function PackagesSpace() {
  const md = S.modsDraft.value;
  const mods = parseModsDraft(md);
  const ids = currentPackageIds();
  const pol = S.policy.value;
  const rows = slotRows(mods, ids, pol, S.escrowPaste.value);
  const resolve = firstResolveRevert(ids, mods, pol);
  const engage = firstEngageRevert(mods, pol);
  const trio = S.suggestedMods("trio");
  const zkSet = S.suggestedMods("zk");
  const arbSet = S.suggestedMods("arb");
  return (
    <div>
      <header class="space-head">
        <h2>Paquetes</h2>
        <p>
          Banco de resolución, no storefront. Pegás addresses; la consola lee la <em>policy</em> viva de cada módulo, recomputa el{" "}
          <code>PackageId</code> con la fórmula del kernel y te muestra si coincide con lo que se va a firmar. El kernel no confía en{" "}
          <code>module.packageId()</code>; esta consola tampoco.
        </p>
      </header>

      <Panel
        title="Slots (PackageMods)"
        subtitle="Calldata de activate; no se firma. Default: los cinco nulos = Core-only."
        kind="kernel"
        right={
          <span class="row">
            {trio && <Button onClick={() => setModsDraft(trio)}>set: trío P+R+B</Button>}
            {zkSet && <Button onClick={() => setModsDraft(zkSet)}>set: ZK</Button>}
            {arbSet && <Button onClick={() => setModsDraft(arbSet)}>set: court mock</Button>}
            <Button onClick={() => setModsDraft(emptyModsDraft())}>vaciar (Core-only)</Button>
            <Button onClick={() => void refreshSlots()}>↻ releer policy</Button>
          </span>
        }
      >
        <div class="slots">
          {(Object.keys(SLOT_DOC) as (keyof PackageMods)[]).map((slot) => {
            const row = rows.find((r) => r.slot === slot)!;
            const doc = SLOT_DOC[slot];
            return (
              <div class={`slot${row.address ? "" : " empty"}`} key={slot}>
                <div class="slot-head">
                  <strong>{doc.title}</strong>
                  <code class="muted">{slot}</code>
                  {row.lab && <Badge tone="lab">LAB</Badge>}
                  {doc.needs && <span class="muted">requiere {doc.needs}</span>}
                </div>
                <Input value={md[slot]} onValue={(v) => setModsDraft({ ...md, [slot]: v.trim() })} placeholder="0x… (vacío = slot nulo)" />
                {row.address && (
                  <KV
                    rows={[
                      ["id recomputeado", row.id ? <Hex32 value={row.id} /> : <span class="muted">policy sin leer</span>],
                      ["∈ packageIds", row.inIds === null ? "—" : row.inIds ? <Badge tone="ok">match</Badge> : <Badge tone="bad">miss → UnknownPackage</Badge>],
                      ...(slot === "reputation" || slot === "bonds"
                        ? ([["peer passport()", row.peerPassport ? <span><Addr value={row.peerPassport} /> {row.peerOk ? <Badge tone="ok">= slot passport</Badge> : <Badge tone="bad">PeerMismatch</Badge>}</span> : "—"]] as [string, preact.JSX.Element | string][])
                        : []),
                      [
                        "binding al recinto",
                        row.getter === "none" ? <span class="muted">sin getter (PassportMock)</span> : <span><code>{row.getter}()</code> = <Addr value={row.boundTo} /> {row.matchesRecinto ? <Badge tone="ok">= escrow</Badge> : <Badge tone="bad">≠ escrow: Unauthorized en el módulo</Badge>}</span>,
                      ],
                      ...policyRows(slot, pol),
                    ]}
                  />
                )}
                <p class="muted formula">{doc.formula}</p>
              </div>
            );
          })}
        </div>
      </Panel>

      <Panel title="packageIds que se van a firmar" subtitle="unique + sort ascendente (Terms._assertPackageIdsCanonical). El override existe para Paths negativos." kind="derived">
        {ids.length === 0 ? <Badge tone="info">[] Core-only</Badge> : ids.map((id) => <div key={id}><Hex32 value={id} /></div>)}
        <Field label="override manual (bytes32 separados por espacio o coma)" hint="Con override la consola firma exactamente eso, aunque no coincida con los slots.">
          <Input class="wide" value={S.idsOverride.value} onValue={setIdsOverride} placeholder="0x… 0x…" />
        </Field>
        <div class="row wrap">
          <span>
            _resolve: {resolve.enabled ? <Badge tone="ok">ok</Badge> : <Badge tone={resolve.reasonKind === "ui-policy" ? "muted" : "bad"}>{shortReason(resolve.reason)}</Badge>}{" "}
            <span class="muted">{revertDoc(resolve.reason)}</span>
          </span>
        </div>
        <div class="row wrap">
          <span>
            _engage (probes): {engage.enabled ? <Badge tone="ok">ok</Badge> : <Badge tone={engage.reasonKind === "ui-policy" ? "muted" : "bad"}>{shortReason(engage.reason)}</Badge>}{" "}
            <span class="muted">{revertDoc(engage.reason)}</span>
          </span>
        </div>
        {pol.identifyError && <Warn>identify: {pol.identifyError}. En Sepolia/Anvil el passport es un mock: corré <code>setHuman</code> en Laboratorio para las dos wallets.</Warn>}
        <Help>
          Orden del kernel: por slot (passport, reputation, bonds, zk, court) → PeerMismatch → UnknownPackage; después del conteo →
          IncompatiblePackages (ZK+ARB) → PackageRequired. Un módulo que “declara” otro packageId no importa: gana el recompute.
        </Help>
      </Panel>
    </div>
  );
}

function policyRows(slot: keyof PackageMods, pol: ReturnType<typeof S.policy.peek>): [string, preact.JSX.Element | string][] {
  if (slot === "reputation" && pol.reputation) {
    return [
      ["activationFee (en activate)", <code>{fmtAmt(pol.reputation.activationFee)}</code>],
      ["completionFee (en cualquier payout al Provider)", <code>{fmtAmt(pol.reputation.completionFee)}</code>],
      ["feeRecipient", <Addr value={pol.reputation.feeRecipient} />],
    ];
  }
  if (slot === "bonds" && pol.bonds) return [["sink (burn)", <Addr value={pol.bonds.sink} />], ["lock por deal", "(principal + 9) / 10 por sujeto"]];
  if (slot === "zk" && pol.zk) return [["verifier", <Addr value={pol.zk.verifier} />], ["verifyFee", <code>{fmtAmt(pol.zk.verifyFee)}</code>]];
  if (slot === "court" && pol.court) {
    return pol.court.extraData !== null
      ? [["kleros arbitrator (partner)", <Addr value={pol.court.partner} />], ["extraData", <code>{pol.court.extraData}</code>]]
      : [["partner (tribunal / feeToken)", <Addr value={pol.court.partner} />], ["key (courtFee)", <code>{pol.court.key?.toString() ?? "—"}</code>]];
  }
  if (slot === "passport" && pol.passport) {
    return [
      ["identify(holder)", pol.identifyHolder ? <Hex32 value={pol.identifyHolder} /> : <Badge tone="warn">NoPassport</Badge>],
      ["identify(provider)", pol.identifyProvider ? <Hex32 value={pol.identifyProvider} /> : <Badge tone="warn">NoPassport</Badge>],
    ];
  }
  return [];
}
