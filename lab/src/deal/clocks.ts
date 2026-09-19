import type { ClockRow, DealClocks, DealTerms } from "./types.ts";

const MAX_U256 = (1n << 256n) - 1n;

/** Clocks.sol: origin 0 means the clock has not started. Do not invent a deadline. */
export function addDuration(
  origin: bigint,
  duration: bigint,
): { deadline: bigint | null; overflow: boolean } {
  if (origin === 0n) return { deadline: null, overflow: false };
  if (duration > MAX_U256 - origin) return { deadline: null, overflow: true };
  return { deadline: origin + duration, overflow: false };
}

/** requireDue: timestamp >= origin + duration */
export function isDue(now: bigint, deadline: bigint | null, overflow: boolean): boolean | null {
  if (overflow || deadline === null) return null;
  return now >= deadline;
}

/** requireStrictlyBefore: timestamp < origin + duration. duration=0 is already TooLate once origin is written. */
export function isStrictlyBefore(
  now: bigint,
  deadline: bigint | null,
  overflow: boolean,
): boolean | null {
  if (overflow || deadline === null) return null;
  return now < deadline;
}

export function deriveClocks(clocks: DealClocks, terms: DealTerms, now: bigint): ClockRow[] {
  const specs: Omit<ClockRow, "deadline" | "overflow" | "due" | "strictlyBefore">[] = [
    {
      name: "fiatDeadline",
      originName: "activatedAt",
      origin: clocks.activatedAt,
      duration: terms.fiatDuration,
      durationField: "fiatDuration",
      dueVerb: "timeoutFiat",
      strictlyBeforeVerb: "—",
    },
    {
      name: "releaseDeadline",
      originName: "fiatSentAt",
      origin: clocks.fiatSentAt,
      duration: terms.releaseDuration,
      durationField: "releaseDuration",
      dueVerb: "claim",
      strictlyBeforeVerb: "openDisputed",
    },
    {
      name: "disputeDeadline",
      originName: "disputedAt",
      origin: clocks.disputedAt,
      duration: terms.disputeDuration,
      durationField: "disputeDuration",
      dueVerb: "forceStalemate",
      strictlyBeforeVerb: "openCourt from DISPUTED",
    },
    {
      name: "arbitrationDeadline",
      originName: "arbitrationOpenedAt",
      origin: clocks.arbitrationOpenedAt,
      duration: terms.arbitrationDuration,
      durationField: "arbitrationDuration",
      dueVerb: "forceArbitrationTimeout",
      strictlyBeforeVerb: "—",
    },
  ];
  return specs.map((row) => {
    const { deadline, overflow } = addDuration(row.origin, row.duration);
    return {
      ...row,
      deadline,
      overflow,
      due: isDue(now, deadline, overflow),
      strictlyBefore: isStrictlyBefore(now, deadline, overflow),
    };
  });
}
