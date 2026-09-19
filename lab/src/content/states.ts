import { Status } from "../deal/types.ts";

export type StateDoc = {
  name: string;
  kind: "none" | "active" | "terminal";
  /** Qué significa que el deal esté acá. */
  meaning: string;
  /** Qué reloj corre, si alguno. */
  clock?: string;
  /** Quién tiene la próxima jugada. */
  ball: string;
};

export const STATE_DOCS: Record<number, StateDoc> = {
  [Status.NONE]: {
    name: "NONE",
    kind: "none",
    meaning: "No existe. Un dealId sin activate. Nada que operar: ir a Consentimiento.",
    ball: "Holder + Provider (+ Controller) firman; Relayer envía activate.",
  },
  [Status.FUNDED]: {
    name: "FUNDED",
    kind: "active",
    meaning: "El principal está en el escrow. El Provider todavía no declaró el pago fiat.",
    clock: "fiatDuration desde activatedAt → timeoutFiat",
    ball: "Provider: markFiat o cancelByProvider. Si se vence, cualquiera: timeoutFiat.",
  },
  [Status.FIAT_SENT]: {
    name: "FIAT_SENT",
    kind: "active",
    meaning: "El Provider dice que pagó. El Controller debe confirmar (release) o negar (openDisputed).",
    clock: "releaseDuration desde fiatSentAt → claim (due) / openDisputed (strictly-before)",
    ball: "Controller. Si se vence, cualquiera: claim (paga al Provider).",
  },
  [Status.DISPUTED]: {
    name: "DISPUTED",
    kind: "active",
    meaning: "El Controller negó el pago. Ventana para acordar por dual-sign o, si hay ARB, abrir el jurado.",
    clock: "disputeDuration desde disputedAt → forceStalemate (due) / openCourt (strictly-before)",
    ball: "Provider + Controller (dual-sign) o Controller (openCourt). Si se vence sin corte: forceStalemate, 50/50 y bonds quemados.",
  },
  [Status.ARBITRATION_ACTIVE]: {
    name: "ARBITRATION_ACTIVE",
    kind: "active",
    meaning: "Caso abierto en el tribunal. PluriSwap no hace nada más que esperar la sentencia (o un dual-sign).",
    clock: "arbitrationDuration desde arbitrationOpenedAt → forceArbitrationTimeout",
    ball: "Tribunal. Cualquiera trae la sentencia con readRuling.",
  },
  [Status.RELEASED]: {
    name: "RELEASED",
    kind: "terminal",
    meaning: "El Provider cobró porque alguien lo confirmó: release, coSignedRelease o verifyProof.",
    ball: "Nadie. Solo withdraw si quedó crédito.",
  },
  [Status.CLAIMED]: {
    name: "CLAIMED",
    kind: "terminal",
    meaning: "El Provider cobró por timeout: marcó fiat y el Controller no respondió. Distinto de RELEASED en el Status y en el score del Holder (Silent).",
    ball: "Nadie.",
  },
  [Status.RESOLVED_SPLIT]: {
    name: "RESOLVED_SPLIT",
    kind: "terminal",
    meaning: "Acuerdo parcial firmado por Provider y Controller (mutualSplit).",
    ball: "Nadie.",
  },
  [Status.STALEMATE]: {
    name: "STALEMATE",
    kind: "terminal",
    meaning: "50/50 del kernel: disputa vencida sin abrir corte. Bonds quemados. El jurado nunca cierra acá.",
    ball: "Nadie.",
  },
  [Status.CANCELLED]: {
    name: "CANCELLED",
    kind: "terminal",
    meaning: "El Holder recuperó todo: cancelByProvider, timeoutFiat o mutualCancel. Nunca hay fee.",
    ball: "Nadie.",
  },
  [Status.RESOLVED_BY_ARBITRATION]: {
    name: "RESOLVED_BY_ARBITRATION",
    kind: "terminal",
    meaning: "Cierre del jurado: gana Holder, gana Provider, o no gana ninguno (50/50 + completion fee). Incluye el timeout si el tribunal no contestó.",
    ball: "Nadie.",
  },
};

export function stateDoc(status: number): StateDoc {
  return (
    STATE_DOCS[status] ?? {
      name: `unknown(${status})`,
      kind: "none",
      meaning: "Status fuera del enum conocido: ABI distinta al recinto.",
      ball: "—",
    }
  );
}

export const TERMINAL: ReadonlySet<number> = new Set([
  Status.RELEASED,
  Status.CLAIMED,
  Status.RESOLVED_SPLIT,
  Status.STALEMATE,
  Status.CANCELLED,
  Status.RESOLVED_BY_ARBITRATION,
]);

export const ACTIVE: ReadonlySet<number> = new Set([
  Status.FUNDED,
  Status.FIAT_SENT,
  Status.DISPUTED,
  Status.ARBITRATION_ACTIVE,
]);

/** Aristas del grafo (STATE_MACHINE.md). `needs` = kind requerido; `notZk` = apagada en deals ZK. */
export type Edge = { verb: string; from: number; to: number; needs?: "zk" | "arb"; notZk?: boolean };

export const EDGES: Edge[] = [
  { verb: "activate", from: Status.NONE, to: Status.FUNDED },
  { verb: "markFiat", from: Status.FUNDED, to: Status.FIAT_SENT, notZk: true },
  { verb: "cancelByProvider", from: Status.FUNDED, to: Status.CANCELLED },
  { verb: "timeoutFiat", from: Status.FUNDED, to: Status.CANCELLED },
  { verb: "mutualCancel", from: Status.FUNDED, to: Status.CANCELLED },
  { verb: "verifyProof", from: Status.FUNDED, to: Status.RELEASED, needs: "zk" },
  { verb: "release", from: Status.FIAT_SENT, to: Status.RELEASED },
  { verb: "claim", from: Status.FIAT_SENT, to: Status.CLAIMED, notZk: true },
  { verb: "openDisputed", from: Status.FIAT_SENT, to: Status.DISPUTED, notZk: true },
  { verb: "mutualCancel", from: Status.FIAT_SENT, to: Status.CANCELLED },
  { verb: "coSignedRelease", from: Status.FIAT_SENT, to: Status.RELEASED },
  { verb: "mutualSplit", from: Status.FIAT_SENT, to: Status.RESOLVED_SPLIT },
  { verb: "forceStalemate", from: Status.DISPUTED, to: Status.STALEMATE },
  { verb: "mutualCancel", from: Status.DISPUTED, to: Status.CANCELLED },
  { verb: "coSignedRelease", from: Status.DISPUTED, to: Status.RELEASED },
  { verb: "mutualSplit", from: Status.DISPUTED, to: Status.RESOLVED_SPLIT },
  { verb: "openCourt", from: Status.DISPUTED, to: Status.ARBITRATION_ACTIVE, needs: "arb", notZk: true },
  { verb: "readRuling", from: Status.ARBITRATION_ACTIVE, to: Status.RESOLVED_BY_ARBITRATION, needs: "arb" },
  { verb: "forceArbitrationTimeout", from: Status.ARBITRATION_ACTIVE, to: Status.RESOLVED_BY_ARBITRATION, needs: "arb" },
  { verb: "mutualCancel", from: Status.ARBITRATION_ACTIVE, to: Status.CANCELLED, needs: "arb" },
  { verb: "coSignedRelease", from: Status.ARBITRATION_ACTIVE, to: Status.RELEASED, needs: "arb" },
  { verb: "mutualSplit", from: Status.ARBITRATION_ACTIVE, to: Status.RESOLVED_SPLIT, needs: "arb" },
];
