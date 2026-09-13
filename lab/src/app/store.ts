import { computed, signal } from "@preact/signals";
import { getAddress, isAddress } from "viem";
import { loadBundledSets, recintosFromSets } from "../addressbook/load.ts";
import { DEFAULT_RPC, ROLES, type AddressSet, type HexAddress, type Role, type SeatState } from "../addressbook/types.ts";
import type { PathTemplate, SpaceId } from "../catalog/paths.ts";
import { defaultDraft, type ConsentDraft } from "../consent/draft.ts";
import type { PreflightStep } from "../consent/preflight.ts";
import type { CourtPref } from "../deal/courtPref.ts";
import type { DealSnapshot, ModuleBinding } from "../deal/types.ts";
import { emptyLabForm, type LabForm } from "../lab/form.ts";
import type { PoolSnapshot } from "../pool/probe.ts";
import { emptyRampForm, type RampForm } from "../ramp/form.ts";
import type { RecintoProbe } from "../recinto/probe.ts";
import { emptyDualSign, type DualSignForm } from "../session/DualSignDraft.ts";
import { emptyModsDraft, emptyPolicy, type LivePolicy, type ModsDraft } from "../slots/types.ts";

/** Sets del AddressBook: un JSON = un set. Nunca se mergean testTokens. */
export const sets: AddressSet[] = loadBundledSets();
export const recintos = recintosFromSets(sets);
const first = recintos.find((r) => r.chainId === 31337) ?? recintos.find((r) => r.chainId === 421614) ?? recintos[0];

// --- navegación --------------------------------------------------------------------------------------------------
export const space = signal<SpaceId>("guide");
export const bookOpen = signal(false);

// --- recinto ---------------------------------------------------------------------------------------------------------
export const chainId = signal<number>(first?.chainId ?? 421614);
export const rpcUrl = signal<string>(DEFAULT_RPC[first?.chainId ?? 421614] ?? "");
export const escrowPaste = signal<string>(first?.escrow ?? "");
export const probe = signal<RecintoProbe | null>(null);
export const probing = signal(false);
export const chainHead = signal<{ number: bigint; timestamp: bigint } | null>(null);

export const escrow = computed<HexAddress | null>(() =>
  isAddress(escrowPaste.value) ? (getAddress(escrowPaste.value) as HexAddress) : null,
);
export const effectiveChainId = computed(() => probe.value?.rpcChainId ?? chainId.value);
export const isAnvil = computed(() => effectiveChainId.value === 31337);

// --- asientos --------------------------------------------------------------------------------------------------------
export const seats = signal<SeatState[]>(ROLES.map((role) => ({ role, address: null, pk: null })));
export const activeRole = signal<Role>("Relayer");

export function seat(role: Role): SeatState {
  return seats.value.find((s) => s.role === role)!;
}
export function seatAddress(role: Role): HexAddress | null {
  const a = seat(role).address;
  return a && isAddress(a) ? (getAddress(a) as HexAddress) : null;
}
export function seatPk(role: Role): string | null {
  return seat(role).pk ?? null;
}
export const activeSender = computed<HexAddress | null>(() => {
  const s = seats.value.find((x) => x.role === activeRole.value);
  return s?.address && isAddress(s.address) ? (getAddress(s.address) as HexAddress) : null;
});
export const p2pSeats = computed(() => {
  const h = seatAddress("Holder");
  const c = seatAddress("Controller");
  return !!h && !!c && h === c;
});

// --- deal en foco -----------------------------------------------------------------------------------------------------
export const lookup = signal({ dealId: "", signer: "", nonce: "" });
export const deal = signal<DealSnapshot | null>(null);
export const bindings = signal<ModuleBinding[]>([]);
export const dealError = signal<string | null>(null);
export const dealLoading = signal(false);
export const credit = signal<bigint | null>(null);
export const ruling = signal<number | null>(null);
export const courtPref = signal<CourtPref | null>(null);
export const dealPolicy = signal<LivePolicy>(emptyPolicy());
export const writeError = signal<string | null>(null);
export const cancelNonceInput = signal("1");
export const sending = signal<string | null>(null);

// --- dual-sign (sesión) -------------------------------------------------------------------------------------------------
export const dualForm = signal<DualSignForm>(emptyDualSign());
export const dsUsedP = signal(false);
export const dsUsedC = signal(false);
export const recoveredP = signal<string | null>(null);
export const recoveredC = signal<string | null>(null);

// --- consentimiento -----------------------------------------------------------------------------------------------------
export const draft = signal<ConsentDraft>(defaultDraft(""));
export const holderSig = signal<`0x${string}` | null>(null);
export const providerSig = signal<`0x${string}` | null>(null);
export const controllerSig = signal<`0x${string}` | null>(null);
export const preflight = signal<PreflightStep[]>([]);
export const projectedDealId = signal<string | null>(null);
export const sendError = signal<string | null>(null);
export const holderIsPool = signal(false);
export const lastActivated = signal<{ dealId: string; hash: string } | null>(null);

// --- paquetes (slots del borrador) ------------------------------------------------------------------------------------
export const modsDraft = signal<ModsDraft>(emptyModsDraft());
export const idsOverride = signal("");
export const policy = signal<LivePolicy>(emptyPolicy());

// --- flags de app (no de kernel) ------------------------------------------------------------------------------------------
export const flags = signal({
  coreActivate: true,
  coreWrites: true,
  dualSign: true,
  distinctController: true,
  packages: true,
  labVerbs: true,
  zkArb: true,
  pool: true,
  ramp: true,
});

// --- laboratorio --------------------------------------------------------------------------------------------------------
export const labForm = signal<LabForm>(emptyLabForm());
export const labProof = signal<string | null>(null);
export const labError = signal<string | null>(null);
export const labLog = signal<{ verb: string; hash?: string; note: string }[]>([]);

// --- pool -----------------------------------------------------------------------------------------------------------------
export const poolPaste = signal("");
export const poolSnap = signal<PoolSnapshot | null>(null);
export const poolError = signal<string | null>(null);
export const poolForm = signal({ depositAmt: "1000000", unlockNonce: "1", reconP: "1", reconC: "1" });

// --- rampa ---------------------------------------------------------------------------------------------------------------
export const rampForm = signal<RampForm>(emptyRampForm());
export const rampQuote = signal<{ nativeFee: string; amountOut: string } | null>(null);
export const rampError = signal<string | null>(null);

// --- créditos ------------------------------------------------------------------------------------------------------------
export const creditRows = signal<{ who: string; address: HexAddress; token: HexAddress; amount: bigint }[]>([]);
export const creditToken = signal("");
export const creditExtra = signal("");

// --- path activo (sesión) -----------------------------------------------------------------------------------------------
export const activePath = signal<PathTemplate | null>(null);
export const pathStep = signal(0);

// --- log de txs ------------------------------------------------------------------------------------------------------------
export type TxLog = { at: number; verb: string; seat: string; sender: string | null; dealId: string | null; hash?: string; error?: string };
export const txLog = signal<TxLog[]>([]);
export function logTx(entry: Omit<TxLog, "at">): void {
  txLog.value = [{ at: Date.now(), ...entry }, ...txLog.value].slice(0, 50);
}

// --- helpers de AddressBook ------------------------------------------------------------------------------------------------
export function setsForRecinto(): AddressSet[] {
  const e = escrow.value;
  if (!e) return [];
  return sets.filter((s) => s.chainId === chainId.value && s.escrow === e);
}
export function suggestedToken(): HexAddress | null {
  return setsForRecinto().find((s) => s.testToken)?.testToken ?? null;
}
export type ModsPreset = "trio" | "zk" | "arb";
/** Atajo desde el set del recinto en foco. Nunca los cinco juntos: ZK+ARB es IncompatiblePackages por diseño. */
export function suggestedMods(preset: ModsPreset = "trio"): ModsDraft | null {
  for (const set of setsForRecinto()) {
    const passport = set.labels.passport ?? "";
    const reputation = set.labels.reputation ?? "";
    const bonds = set.labels.bondVault ?? set.labels.bonds ?? "";
    const zk = set.labels.zk ?? "";
    const court = set.labels.arbitration ?? set.labels.court ?? set.labels.klerosAdapter ?? "";
    if (preset === "trio" && passport && reputation && bonds) return { passport, reputation, bonds, zk: "", court: "" };
    if (preset === "zk" && zk) return { passport: "", reputation: "", bonds: "", zk, court: "" };
    if (preset === "arb" && court) return { passport: "", reputation: "", bonds: "", zk: "", court };
  }
  return null;
}
export function suggestedPool(): string | null {
  return setsForRecinto().find((s) => s.labels.pool)?.labels.pool ?? null;
}
export function labelFor(address: string | null | undefined): string | null {
  if (!address || !isAddress(address)) return null;
  const want = getAddress(address);
  for (const s of seats.value) {
    if (s.address && isAddress(s.address) && getAddress(s.address) === want) return s.role;
  }
  for (const set of sets) {
    if (set.chainId !== chainId.value) continue;
    if (set.escrow === want) return "escrow";
    for (const [k, v] of Object.entries(set.labels)) {
      if (isAddress(v) && getAddress(v) === want) return k;
    }
  }
  return null;
}
export function rampSetField(key: string): string | null {
  for (const set of sets) {
    if (set.chainId === chainId.value && set.labels[key]) return set.labels[key] ?? null;
  }
  for (const set of sets) {
    if (set.sourceFile.includes("ramp") && set.labels[key]) return set.labels[key] ?? null;
  }
  return null;
}
export type DealShortcut = { sourceFile: string; label: string; dealId: string };
export function dealShortcuts(): DealShortcut[] {
  const out: DealShortcut[] = [];
  for (const set of setsForRecinto()) {
    for (const [label, value] of Object.entries(set.labels)) {
      if (!/dealid$/i.test(label) && label !== "dealId") continue;
      if (!/^0x[0-9a-fA-F]{64}$/.test(value)) continue;
      out.push({ sourceFile: set.sourceFile, label, dealId: value });
    }
  }
  return out;
}
