import { EDGES, TERMINAL, stateDoc } from "../content/states.ts";
import { PKG, Status } from "./types.ts";

type Pos = { x: number; y: number };

/** Layout fijo: activos en la fila del medio, terminales abajo. */
const POS: Record<number, Pos> = {
  [Status.NONE]: { x: 60, y: 120 },
  [Status.FUNDED]: { x: 240, y: 120 },
  [Status.FIAT_SENT]: { x: 460, y: 120 },
  [Status.DISPUTED]: { x: 690, y: 120 },
  [Status.ARBITRATION_ACTIVE]: { x: 940, y: 120 },
  [Status.CANCELLED]: { x: 120, y: 300 },
  [Status.RELEASED]: { x: 300, y: 300 },
  [Status.CLAIMED]: { x: 450, y: 300 },
  [Status.RESOLVED_SPLIT]: { x: 610, y: 300 },
  [Status.STALEMATE]: { x: 790, y: 300 },
  [Status.RESOLVED_BY_ARBITRATION]: { x: 980, y: 300 },
};

const SHORT: Record<number, string> = {
  [Status.NONE]: "NONE",
  [Status.FUNDED]: "FUNDED",
  [Status.FIAT_SENT]: "FIAT_SENT",
  [Status.DISPUTED]: "DISPUTED",
  [Status.ARBITRATION_ACTIVE]: "ARBITRATION_ACTIVE",
  [Status.CANCELLED]: "CANCELLED",
  [Status.RELEASED]: "RELEASED",
  [Status.CLAIMED]: "CLAIMED",
  [Status.RESOLVED_SPLIT]: "RESOLVED_SPLIT",
  [Status.STALEMATE]: "STALEMATE",
  [Status.RESOLVED_BY_ARBITRATION]: "RESOLVED_BY_ARB",
};

export type EdgeState = "enabled" | "disabled" | "off" | "neutral";

export function Machine(props: {
  /** Status actual; undefined = grafo genérico (Guía). */
  status?: number;
  kinds?: number;
  /** Evaluación por verbo (de la matriz) para el asiento activo. */
  evalOf?: (verb: string) => EdgeState;
  onVerb?: (verb: string) => void;
  compact?: boolean;
}) {
  const zk = ((props.kinds ?? 0) & PKG.ZK) !== 0;
  const arb = ((props.kinds ?? 0) & PKG.ARB) !== 0;
  const generic = props.status === undefined;

  // Agrupar aristas por (from,to) para no dibujar 4 curvas iguales.
  const groups = new Map<string, { from: number; to: number; verbs: string[]; off: boolean }>();
  for (const e of EDGES) {
    const kindsKnown = props.kinds !== undefined;
    const off = kindsKnown && ((e.needs === "zk" && !zk) || (e.needs === "arb" && !arb) || (!!e.notZk && zk));
    const key = `${e.from}-${e.to}`;
    const g = groups.get(key) ?? { from: e.from, to: e.to, verbs: [], off: true };
    g.verbs.push(e.verb);
    g.off = g.off && off;
    groups.set(key, g);
  }

  const w = 1100;
  const h = props.compact ? 350 : 370;
  // Etiquetas inline solo donde no se pisan: aristas horizontales y las que salen del estado actual.
  // El resto lleva <title> (hover) y, en modo genérico, se lista debajo del grafo.
  const showLabel = (from: number, to: number) => POS[from]!.y === POS[to]!.y || (!generic && props.status === from);
  const legend = generic
    ? [...groups.values()].filter((g) => POS[g.from]!.y !== POS[g.to]!.y)
    : [];
  return (
    <div class="machine-wrap">
    <svg class={`machine${props.compact ? " compact" : ""}`} viewBox={`0 0 ${w} ${h}`} role="img" aria-label="Máquina de estados del deal">
      <defs>
        <marker id="arr" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
          <path d="M 0 0 L 10 5 L 0 10 z" fill="currentColor" />
        </marker>
      </defs>
      {[...groups.values()].map((g) => {
        const a = POS[g.from]!;
        const b = POS[g.to]!;
        const fromNow = !generic && props.status === g.from;
        let cls: EdgeState = "neutral";
        if (g.off) cls = "off";
        else if (fromNow && props.evalOf) {
          const states = g.verbs.map((v) => props.evalOf!(v));
          cls = states.includes("enabled") ? "enabled" : states.every((s) => s === "off") ? "off" : "disabled";
        } else if (!generic) cls = fromNow ? "disabled" : "neutral";
        const mid = { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 };
        const same = a.y === b.y;
        // Salida por abajo del nodo origen y llegada por arriba del destino, para que las curvas no crucen los rectángulos.
        const p0 = same ? { x: a.x + 40, y: a.y } : { x: a.x, y: a.y + 16 };
        const p1 = same ? { x: b.x - 40, y: b.y } : { x: b.x, y: b.y - 16 };
        const ctrl = same ? { x: mid.x, y: a.y - 50 } : { x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2 };
        const d = same ? `M ${p0.x} ${p0.y} Q ${ctrl.x} ${ctrl.y} ${p1.x} ${p1.y}` : `M ${p0.x} ${p0.y} C ${p0.x} ${mid.y} ${p1.x} ${mid.y} ${p1.x} ${p1.y}`;
        const label = g.verbs.filter((v, i, arr) => arr.indexOf(v) === i).join(" · ");
        // Para aristas verticales, la etiqueta va cerca del origen a una altura que depende del destino: no se pisan entre sí.
        const rank = [...groups.values()].filter((o) => o.from === g.from && POS[o.from]!.y !== POS[o.to]!.y).findIndex((o) => o === g);
        const labelPos = same ? { x: mid.x, y: a.y - 30 } : { x: p0.x + (p1.x - p0.x) * 0.22, y: a.y + 40 + rank * 14 };
        const strong = !generic && props.status === g.from;
        return (
          <g class={`edge edge-${cls}${strong ? " strong" : ""}`} key={`${g.from}-${g.to}`} onClick={() => props.onVerb?.(g.verbs[0]!)}>
            <title>{`${SHORT[g.from]} → ${SHORT[g.to]}: ${label}`}</title>
            <path d={d} marker-end="url(#arr)" />
            {showLabel(g.from, g.to) && (
              <text x={labelPos.x} y={labelPos.y} text-anchor={same ? "middle" : "start"}>
                {label}
              </text>
            )}
          </g>
        );
      })}
      {Object.entries(POS).map(([k, p]) => {
        const s = Number(k);
        const now = props.status === s;
        const term = TERMINAL.has(s);
        const doc = stateDoc(s);
        const rw = 8 + SHORT[s]!.length * 7.2;
        return (
          <g class={`node${now ? " now" : ""}${term ? " terminal" : ""}${s === Status.NONE ? " none" : ""}`} key={k}>
            <title>{doc.meaning}</title>
            <rect x={p.x - rw / 2} y={p.y - 16} width={rw} height={32} rx={term ? 4 : 16} />
            <text x={p.x} y={p.y + 5} text-anchor="middle">
              {SHORT[s]}
            </text>
          </g>
        );
      })}
      {!generic && (
        <g class="legend">
          <text x={20} y={h - 12}>
            verde: legal ahora para el asiento activo · rojo: existe pero revertiría · gris: apagada en este deal (kinds) · hover en una arista: sus verbos
          </text>
        </g>
      )}
    </svg>
    {legend.length > 0 && (
      <ul class="machine-legend">
        {legend.map((g) => (
          <li key={`${g.from}-${g.to}`}>
            <span class="muted">{SHORT[g.from]} → {SHORT[g.to]}</span> {g.verbs.filter((v, i, arr) => arr.indexOf(v) === i).join(" · ")}
          </li>
        ))}
      </ul>
    )}
    </div>
  );
}
