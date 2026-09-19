import { startPath } from "../app/actions.ts";
import * as S from "../app/store.ts";
import { STATE_DOCS } from "../content/states.ts";
import { VERB_DOCS } from "../content/verbs.ts";
import { Machine } from "../deal/Machine.tsx";
import { Status } from "../deal/types.ts";
import { Badge, Button, Help, Panel, Warn } from "../ui/atoms.tsx";

export function GuideSpace() {
  return (
    <div class="guide">
      <header class="space-head">
        <h2>Cómo funciona PluriSwap (y cómo se opera desde acá)</h2>
        <p>
          PluriSwap es un escrow de <strong>principal cripto contra fiat offchain</strong>. El kernel (<code>Escrow.sol</code>) es una máquina
          cerrada de tres roles. Todo lo demás —passport, reputación, bonds, ZK, tribunal, pool, rampa— es opcional y vive afuera. Esta
          consola es una <em>vista</em> de esa máquina: cada widget mapea a un getter, evento o entrypoint on-chain. No inventa estado.
        </p>
      </header>

      <Panel title="1. Tres roles, un deal" kind="plain">
        <div class="cols3">
          <div>
            <h4>Holder</h4>
            <p>Deposita el principal (ERC-20). Quiere recibir fiat afuera. Si nadie lo confirma, lo recupera por timeout.</p>
          </div>
          <div>
            <h4>Provider</h4>
            <p>Paga el fiat offchain y lo declara con <code>markFiat</code>. Si el Controller no responde, cobra por <code>claim</code>.</p>
          </div>
          <div>
            <h4>Controller</h4>
            <p>
              Juzga si el fiat llegó: <code>release</code> o <code>openDisputed</code>. Desde <code>DISPUTED</code> puede abrir
              tribunal con <code>openCourt</code>. En un deal P2P es el mismo Holder; en un deal con agente es otra address y firma un
              tercer envelope.
            </p>
          </div>
        </div>
        <Help>
          Un cuarto asiento, <strong>Relayer</strong>, no es un rol del kernel: es quien paga el gas de las txs que llevan firmas
          (<code>activate</code>, dual-sign) y de los verbos permissionless (timeouts, <code>claim</code>, <code>readRuling</code>). Puede ser
          cualquiera, incluso el Holder.
        </Help>
      </Panel>

      <Panel title="2. La máquina de estados" subtitle="Cada flecha es un entrypoint de Escrow.sol. Pasá el mouse por un estado para leer qué significa." kind="plain">
        <Machine />
        <table class="doc-table">
          <thead>
            <tr>
              <th>Estado</th>
              <th>Qué significa</th>
              <th>Reloj</th>
              <th>Quién tiene la jugada</th>
            </tr>
          </thead>
          <tbody>
            {[Status.FUNDED, Status.FIAT_SENT, Status.DISPUTED, Status.ARBITRATION_ACTIVE].map((s) => {
              const d = STATE_DOCS[s]!;
              return (
                <tr key={s}>
                  <td>
                    <code>{d.name}</code>
                  </td>
                  <td>{d.meaning}</td>
                  <td class="muted">{d.clock}</td>
                  <td>{d.ball}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
        <details>
          <summary>Terminales (seis)</summary>
          <ul>
            {[Status.RELEASED, Status.CLAIMED, Status.RESOLVED_SPLIT, Status.CANCELLED, Status.STALEMATE, Status.RESOLVED_BY_ARBITRATION].map((s) => (
              <li key={s}>
                <code>{STATE_DOCS[s]!.name}</code> — {STATE_DOCS[s]!.meaning}
              </li>
            ))}
          </ul>
        </details>
      </Panel>

      <Panel title="3. Cuatro relojes, dos predicados" kind="plain">
        <p>
          Los <code>DealTerms</code> firmados traen cuatro duraciones. Cada estado activo escribe un origen (<code>activatedAt</code>,{" "}
          <code>fiatSentAt</code>, <code>disputedAt</code>, <code>arbitrationOpenedAt</code>). El kernel solo pregunta dos cosas:
        </p>
        <div class="cols2">
          <div class="card">
            <h4>
              <code>requireDue</code>: <code>now ≥ origin + duration</code>
            </h4>
            <p>
              Habilita las salidas por inacción: <code>timeoutFiat</code>, <code>claim</code>, <code>forceStalemate</code>,{" "}
              <code>forceArbitrationTimeout</code>. Con <code>duration = 0</code> están habilitadas en el mismo bloque.
            </p>
          </div>
          <div class="card">
            <h4>
              <code>requireStrictlyBefore</code>: <code>now &lt; origin + duration</code>
            </h4>
            <p>
              Protege las ventanas de reacción: <code>openDisputed</code> y <code>openCourt</code>. Con <code>duration = 0</code> la ventana
              nace cerrada: <code>TooLate</code> desde el primer bloque.
            </p>
          </div>
        </div>
        <Warn tone="info">
          Por eso los Paths del catálogo usan <code>0</code> solo en el reloj que quieren vencer, y <code>releaseDuration = 100</code> cuando
          quieren disputar. Un deal con <code>releaseDuration = 0</code> es un deal donde el Controller <em>no puede</em> disputar.
        </Warn>
      </Panel>

      <Panel title="4. Consentimiento: firmas EIP-712, un Relayer, un pull" kind="plain">
        <ol class="steps">
          <li>
            Holder y Provider firman <strong>los mismos</strong> <code>DealTerms</code> (roles, token, principal, duraciones,{" "}
            <code>packageIds</code>) cada uno con su <code>nonce</code> y un <code>deadline</code> de autorización.
          </li>
          <li>
            Si <code>holder ≠ controller</code>, el Controller firma un tercer envelope (<code>ControllerAcceptance</code>). Si es P2P, el
            kernel recibe una CA vacía: <strong>siempre es el overload de 6 args</strong>; el de 7 agrega <code>PackageMods</code>.
          </li>
          <li>
            El Holder hace <code>approve(escrow, principal + activationFee)</code>. El approve no está en la firma.
          </li>
          <li>
            El Relayer envía <code>activate</code>. El kernel valida en un orden fijo (Terms → mismatch → deadlines → firmas → nonces →
            paquetes → DealExists → engage → pull). El preflight de Consentimiento reproduce <em>ese</em> orden y muestra el primer revert.
          </li>
        </ol>
        <p>
          <code>dealId = keccak256(domainSeparator, hash(terms), holderNonce, providerNonce, controllerNonce | 0)</code>. Se conoce antes de
          enviar: la consola lo proyecta.
        </p>
      </Panel>

      <Panel title="5. Dual-sign: dos envelopes, una tx" kind="plain">
        <p>
          Provider y Controller pueden cerrar el deal de común acuerdo desde cualquier estado activo: <code>mutualCancel</code> (todo al
          Holder), <code>coSignedRelease</code> (todo al Provider) o <code>mutualSplit</code> (<code>providerBps</code>). Cada uno firma su
          copia del mensaje (mismo <code>dealId</code>, mismo <code>deadline</code>, nonces propios); el Relayer manda una tx con las dos
          firmas. Se compone en el espacio Deal, no en Consentimiento.
        </p>
      </Panel>

      <Panel title="6. Qué pasa con la plata al cerrar" kind="plain">
        <table class="doc-table">
          <thead>
            <tr>
              <th>Cierre</th>
              <th>Principal</th>
              <th>Completion fee (si hay Reputation)</th>
              <th>Bonds (si hay)</th>
              <th>Score</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <td>
                <code>release</code>, <code>coSignedRelease</code>, <code>verifyProof</code>, <code>claim</code>
              </td>
              <td>100% al Provider</td>
              <td>Sí, sobre el total, antes de pagar</td>
              <td>unlock</td>
              <td>Peaceful / Peaceful (claim: Holder Silent)</td>
            </tr>
            <tr>
              <td>
                <code>mutualSplit</code>
              </td>
              <td>fee primero; luego <code>providerBps</code> del resto</td>
              <td>Sí</td>
              <td>unlock</td>
              <td>Peaceful</td>
            </tr>
            <tr>
              <td>
                <code>cancelByProvider</code>, <code>timeoutFiat</code>, <code>mutualCancel</code>
              </td>
              <td>100% al Holder</td>
              <td>No (un refund nunca se factura)</td>
              <td>unlock</td>
              <td>Silent</td>
            </tr>
            <tr>
              <td>
                <code>forceStalemate</code>
              </td>
              <td>50 / 50</td>
              <td>Sí (el Provider recibe algo)</td>
              <td>
                <strong>burn</strong> ambos
              </td>
              <td>Stalemate</td>
            </tr>
            <tr>
              <td>
                <code>readRuling</code> 1 | 2
              </td>
              <td>100% al ganador</td>
              <td>Solo si gana el Provider</td>
              <td>bond del perdedor → al ganador</td>
              <td>ArbWin / ArbLoss</td>
            </tr>
            <tr>
              <td>
                <code>readRuling</code> 3, <code>forceArbitrationTimeout</code>
              </td>
              <td>50 / 50 — <code>RESOLVED_BY_ARBITRATION</code></td>
              <td>Sí</td>
              <td>unlock</td>
              <td>Stalemate / Silent</td>
            </tr>
          </tbody>
        </table>
        <Help>
          El pago es <em>credit-first</em>: el kernel acredita y luego intenta transferir. Si la transferencia falla, el terminal igual
          queda escrito y el beneficiario retira con <code>withdraw(token)</code> en Créditos.
        </Help>
      </Panel>

      <Panel title="7. Paquetes: opt-in, permissionless, verificados por hash" kind="plain">
        <p>
          El constructor del escrow no conoce ningún módulo. Al firmar, las partes ponen en <code>packageIds</code> los hashes de la{" "}
          <em>policy</em> de cada módulo (<code>PackageId.sol</code>). En <code>activate</code> el Relayer pasa las addresses (
          <code>PackageMods</code>); el kernel recomputa cada id y exige que esté firmado. Si el módulo cambia su policy después, el id vivo
          deja de coincidir: <Badge tone="warn">DRIFT</Badge>, el fee se omite y las salidas Core siguen funcionando (KERNEL-04).
        </p>
        <div class="cols2">
          <div class="card">
            <h4>Passport → Reputation → Bonds</h4>
            <p>
              Passport identifica la wallet (en producción: Human Passport; en Sepolia: <code>PassportMock</code>). Reputation exige Passport
              y cobra activationFee + completionFee. Bonds exige ambos y bloquea el 10% del principal como skin de cada sujeto.
            </p>
          </div>
          <div class="card">
            <h4>ZK o Tribunal (nunca ambos)</h4>
            <p>
              ZK apaga <code>markFiat</code>/<code>claim</code>/<code>openDisputed</code>: el pago se demuestra con <code>verifyProof</code>.
              Tribunal: siempre <code>openDisputed</code> y después <code>openCourt</code> (mock o Kleros V2). El jurado cierra en{" "}
              <code>RESOLVED_BY_ARBITRATION</code> (Holder, Provider o ninguno). Con Kleros, PluriSwap abre el caso y lee la sentencia;
              la evidencia se sube en la dapp de Kleros.
            </p>
          </div>
        </div>
      </Panel>

      <Panel title="8. Cómo usar esta consola" kind="plain">
        <ol class="steps">
          <li>
            <strong>Recinto.</strong> Arriba: chain + RPC + escrow. Un recinto = un <code>domainSeparator</code>. Varios escrows conviven;
            mezclar firmas entre ellos es el error que la barra hace visible.
          </li>
          <li>
            <strong>Asientos.</strong> Pegá una address por rol (y una pk de sesión si vas a enviar). El asiento activo es{" "}
            <code>msg.sender</code>. En Anvil hay un atajo para cargar las cuentas por defecto.
          </li>
          <li>
            <strong>Catálogo.</strong> Elegí un Path. Prellena Consentimiento con las duraciones correctas y muestra una bandeja con los
            pasos. La bandeja resalta; nunca esconde la matriz.
          </li>
          <li>
            <strong>Consentimiento.</strong> Completá roles, token, principal, nonces. El preflight te dice el primer revert antes de
            gastar gas. Firmá con cada asiento y enviá con el Relayer.
          </li>
          <li>
            <strong>Deal.</strong> Grafo vivo + matriz de elegibilidad: todos los verbos, siempre visibles; los ilegales dicen con qué
            selector revertirían para <em>este</em> asiento. Cambiá de asiento y mirá cómo cambia.
          </li>
          <li>
            <strong>Laboratorio</strong> (jaula LAB): mocks de passport, proof y tribunal, faucet y reloj de Anvil. Nada de eso es real ni
            se presenta como tal.
          </li>
        </ol>
        <div class="row">
          <Button tone="primary" onClick={() => startPath("CASE-CORE-06")}>
            Empezar con CASE-CORE-06 (camino feliz)
          </Button>
          <Button onClick={() => (S.space.value = "catalog")}>Ver el catálogo</Button>
        </div>
      </Panel>

      <Panel title="Referencia rápida de verbos" kind="plain" collapsed>
        <table class="doc-table">
          <thead>
            <tr>
              <th>Verbo</th>
              <th>Quién</th>
              <th>Desde → hacia</th>
              <th>Plata</th>
              <th>Para qué</th>
            </tr>
          </thead>
          <tbody>
            {Object.values(VERB_DOCS).map((v) => (
              <tr key={v.verb}>
                <td>
                  <code>{v.verb}</code>
                </td>
                <td>{v.who}</td>
                <td>
                  <code>{v.from}</code> → <code>{v.to}</code>
                  {v.clock && <div class="muted">{v.clock}</div>}
                </td>
                <td>{v.money}</td>
                <td>{v.why}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </Panel>
    </div>
  );
}
