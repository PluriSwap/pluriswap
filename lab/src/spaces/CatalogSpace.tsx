import { startPath } from "../app/actions.ts";
import * as S from "../app/store.ts";
import { PATHS, PATH_GROUPS, type PathNeed, type PathTemplate } from "../catalog/paths.ts";
import { Badge, Button, Help, Panel, Seat } from "../ui/atoms.tsx";

const FLAG_OF: Record<PathNeed, keyof typeof S.flags.value | null> = {
  core: null,
  packages: "packages",
  labVerbs: "labVerbs",
  zkArb: "zkArb",
  pool: "pool",
  ramp: "ramp",
};

export function CatalogSpace() {
  const flags = S.flags.value;
  const anvil = S.isAnvil.value;
  const disabledBy = (p: PathTemplate) => p.needs.map((n) => FLAG_OF[n]).filter((f): f is keyof typeof flags => !!f && !flags[f]);
  return (
    <div>
      <header class="space-head">
        <h2>Catálogo de Paths</h2>
        <p>
          Recetas que los scripts de Foundry recorren en lote (<code>script/Paths.s.sol</code>, <code>TrioDeal</code>, <code>CatalogDeals</code>…).
          Acá se recorren <strong>un verbo a la vez</strong>, con un humano mirando <code>status</code>, relojes y matriz entre txs.
          Arrancar un Path prellena Consentimiento y abre una bandeja de pasos; nunca reemplaza la matriz por un “Siguiente”.
        </p>
      </header>
      <Help>
        Duraciones = <code>(fiatDuration, releaseDuration, disputeDuration, arbitrationDuration)</code>. Un <code>0</code> aparece solo en el
        reloj que el Path quiere vencer sin esperar; strictly-before nunca usa 0.{" "}
        {anvil ? "En Anvil el reloj LAB permite avanzar el tiempo si hace falta." : "En Sepolia no hay warp: los timeouts usan duration = 0."}
      </Help>
      {PATH_GROUPS.map((g) => {
        const paths = PATHS.filter((p) => p.group === g.id);
        return (
          <Panel title={g.title} subtitle={g.blurb} key={g.id} kind={g.id === "paquetes" || g.id === "tribunal" ? "kernel" : "plain"}>
            <div class="paths">
              {paths.map((p) => {
                const off = disabledBy(p);
                return (
                  <article class={`path${off.length ? " off" : ""}`} key={p.id}>
                    <header>
                      <strong>{p.id}</strong>
                      <code class="muted">
                        ({p.fiatDuration}, {p.releaseDuration}, {p.disputeDuration}, {p.arbitrationDuration})
                      </code>
                      {p.p2p ? <Badge>P2P</Badge> : <Badge tone="info">Controller distinto</Badge>}
                      {p.needs.includes("labVerbs") && <Badge tone="lab">usa LAB</Badge>}
                    </header>
                    <p class="teaches">{p.teaches}</p>
                    <ol class="mini-steps">
                      {p.steps.map((s, i) => (
                        <li key={i}>
                          <Seat seat={s.seat} /> <code>{s.verb}</code>
                        </li>
                      ))}
                    </ol>
                    <footer>
                      <span class="muted">esperar: {p.assertion}</span>
                      <span class="muted">recinto: {p.recintoHint}</span>
                      {off.length ? (
                        <Badge tone="muted">flag {off.join(", ")} off</Badge>
                      ) : (
                        <Button tone="primary" onClick={() => startPath(p.id)}>
                          arrancar
                        </Button>
                      )}
                    </footer>
                  </article>
                );
              })}
            </div>
          </Panel>
        );
      })}
      <Panel title="Flags de app" subtitle="Nunca son gate on-chain. Apagar un flag deja las filas visibles y quita el botón de enviar." collapsed>
        <div class="chips">
          {(Object.keys(flags) as (keyof typeof flags)[]).map((k) => (
            <label class="check" key={k}>
              <input type="checkbox" checked={flags[k]} onChange={() => (S.flags.value = { ...flags, [k]: !flags[k] })} />
              {k}
            </label>
          ))}
        </div>
      </Panel>
    </div>
  );
}
