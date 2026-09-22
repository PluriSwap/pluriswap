import type { DealTerms } from "../deal/types.ts";

/**
 * Clock review for a deal about to be signed (PLURISWAP.md §3.8).
 *
 * The kernel's only bound on a duration is `>= 0`, on purpose: the clocks belong to the parties and
 * the signature covers them. That is the right place to draw the line — a kernel that imposed
 * minimums would be a kernel with an opinion about how long a bank transfer takes — but it leaves a
 * loaded gun on the table, because a zero clock is not a short clock. It hands one side a free win:
 *
 *   fiatDuration = 0        anyone can `timeoutFiat` in the activation block itself. A Provider who
 *                           already paid fiat has no deal to be paid from.
 *   releaseDuration = 0     the Provider can `markFiat` + `claim` in one block, proving nothing —
 *                           and `openDisputed` is already `TooLate`, so the Holder has no defence
 *                           at all, not even the freeze.
 *   disputeDuration = 0     the freeze is an instant forfeit. Abandoning a dispute loses it, and a
 *                           zero window means it is abandoned in the block it is opened, so the
 *                           Holder's only defensive move hands over the whole principal.
 *   arbitrationDuration = 0 `forceArbitrationTimeout` is eligible in the block the court opens, so
 *                           the tribunal never gets to rule and the court fee is spent for nothing.
 *
 * Each of those four is verified against the kernel in Solidity, not inferred from the spec.
 *
 * So the check lives client-side, which is where §3.8 says the protection belongs, and it is a pure
 * function over the terms so any client can run it — this lab is just the first consumer.
 *
 * Two severities, because they are different claims. `danger` is "the chain will do this to you",
 * and it is never an intentional setting. `warning` is "this is below a production floor", which is
 * a judgement, and one the lab's own catalog paths deliberately break: they run 1800/7200 so a human
 * can walk a whole path in one sitting. A warning in the lab is expected; a danger never is.
 */
export type ClockSeverity = "danger" | "warning" | "note";

export type ClockName = "fiatDuration" | "releaseDuration" | "disputeDuration" | "arbitrationDuration";

export type ClockFinding = {
  clock: ClockName;
  severity: ClockSeverity;
  /** What the chain does. */
  effect: string;
  /** Who loses, and why that is not recoverable. */
  detail: string;
};

/** Production floors. Judgement, not protocol — below these a clock is survivable but hostile. */
export const FLOORS: Record<ClockName, bigint> = {
  // A Provider has to see the deal, move fiat through a bank, and come back to mark it.
  fiatDuration: 30n * 60n,
  // A Holder has to see the fiat actually land — bank settlement is minutes to days — and then
  // decide between releasing and freezing. This is the clock that pays the Provider on silence.
  releaseDuration: 2n * 60n * 60n,
  // Long enough for two humans in different timezones to reach a split or a co-signed release.
  disputeDuration: 24n * 60n * 60n,
  // Kleros rounds, appeals included, run in days.
  arbitrationDuration: 7n * 24n * 60n * 60n,
};

/** Above this the principal is in custody for longer than most people plan anything. */
export const CEILING = 365n * 24n * 60n * 60n;

export type ReviewOptions = {
  /** PAYMENT_PROOF selected: the deal is proof-or-timeout and most clocks are inert (§3.12.1). */
  zk: boolean;
  /** ARBITRATION selected: `arbitrationDuration` stops being an ignored field (§3.13). */
  arbitration: boolean;
};

export function reviewClocks(terms: DealTerms, opts: ReviewOptions): ClockFinding[] {
  const out: ClockFinding[] = [];
  const { zk, arbitration } = opts;

  if (terms.fiatDuration === 0n) {
    out.push({
      clock: "fiatDuration",
      severity: "danger",
      effect: "timeoutFiat es elegible en el bloque de la activación",
      detail:
        "Cualquiera cancela el deal al instante y el principal vuelve al Holder. Un Provider que ya " +
        "mandó el fiat se queda sin contraparte y sin escrow.",
    });
  } else if (terms.fiatDuration < FLOORS.fiatDuration) {
    out.push({
      clock: "fiatDuration",
      severity: "warning",
      effect: `menos de ${human(FLOORS.fiatDuration)} para pagar y marcar el fiat`,
      detail: "El Provider compite contra el reloj de una transferencia bancaria que no controla.",
    });
  }

  if (zk) {
    out.push({
      clock: "releaseDuration",
      severity: "note",
      effect: "deal PAYMENT_PROOF: release, claim y DISPUTED están apagados (EdgeOff)",
      detail:
        "Sólo corre fiatDuration. releaseDuration, disputeDuration y arbitrationDuration son inertes " +
        "en este deal: proof o timeout.",
    });
  } else {
    if (terms.releaseDuration === 0n) {
      out.push({
        clock: "releaseDuration",
        severity: "danger",
        effect: "el Provider puede markFiat y claim en el mismo bloque",
        detail:
          "Se lleva el principal entero sin probar ningún pago, y openDisputed ya es TooLate: el " +
          "Holder no tiene ni siquiera el freeze.",
      });
    } else if (terms.releaseDuration < FLOORS.releaseDuration) {
      out.push({
        clock: "releaseDuration",
        severity: "warning",
        effect: `menos de ${human(FLOORS.releaseDuration)} para verificar el fiat antes del claim`,
        detail:
          "Este es el reloj que le paga al Provider por silencio. Si el Holder no mira a tiempo, " +
          "paga aunque el fiat nunca haya llegado.",
      });
    }

    if (terms.disputeDuration === 0n) {
      out.push({
        clock: "disputeDuration",
        severity: "danger",
        effect: "abrir DISPUTED es un forfeit inmediato del principal entero",
        detail:
          "Abandonar una disputa la pierde (§3.11 OUT-14), y con ventana cero se abandona en el " +
          "mismo bloque en que se abre: la única defensa del Holder le entrega todo al Provider.",
      });
    } else if (terms.disputeDuration < FLOORS.disputeDuration) {
      out.push({
        clock: "disputeDuration",
        severity: "warning",
        effect: `menos de ${human(FLOORS.disputeDuration)} para acordar o escalar antes de perder`,
        detail:
          "Abandonar la disputa la pierde. El split, el co-signed release o abrir corte necesitan " +
          "que haya alguien despierto de este lado.",
      });
    }
  }

  if (arbitration && !zk) {
    if (terms.arbitrationDuration === 0n) {
      out.push({
        clock: "arbitrationDuration",
        severity: "danger",
        effect: "forceArbitrationTimeout es elegible en el bloque en que se abre la corte",
        detail:
          "El tribunal no llega a fallar: el deal termina 50/50 y el fee de corte ya se pagó de la " +
          "wallet del que abrió.",
      });
    } else if (terms.arbitrationDuration < FLOORS.arbitrationDuration) {
      out.push({
        clock: "arbitrationDuration",
        severity: "warning",
        effect: `menos de ${human(FLOORS.arbitrationDuration)} para que Kleros falle`,
        detail: "Rondas y apelaciones tardan días. Un timeout temprano tira el veredicto y el fee.",
      });
    }
  }

  for (const [clock, value] of clocksOf(terms, opts)) {
    if (value > CEILING) {
      out.push({
        clock,
        severity: "warning",
        effect: `${human(value)} es más de un año`,
        detail: "El principal queda en custodia hasta que ese reloj venza. Nadie lo puede acortar.",
      });
    }
  }

  return out;
}

/** True when signing these terms hands one side a free win. */
export function hasDanger(findings: ClockFinding[]): boolean {
  return findings.some((f) => f.severity === "danger");
}

function clocksOf(terms: DealTerms, opts: ReviewOptions): [ClockName, bigint][] {
  const live: [ClockName, bigint][] = [["fiatDuration", terms.fiatDuration]];
  if (!opts.zk) {
    live.push(["releaseDuration", terms.releaseDuration], ["disputeDuration", terms.disputeDuration]);
    if (opts.arbitration) live.push(["arbitrationDuration", terms.arbitrationDuration]);
  }
  return live;
}

export function human(seconds: bigint): string {
  if (seconds === 0n) return "0";
  const units: [bigint, string][] = [
    [86_400n, "d"],
    [3_600n, "h"],
    [60n, "min"],
    [1n, "s"],
  ];
  for (const [size, label] of units) {
    if (seconds >= size) {
      const whole = seconds / size;
      const rest = seconds % size;
      return rest === 0n ? `${whole}${label}` : `${whole}${label}+`;
    }
  }
  return `${seconds}s`;
}
