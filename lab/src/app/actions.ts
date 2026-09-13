import { createPublicClient, getAddress, http, isAddress, recoverTypedDataAddress, type Hex } from "viem";
import { DEFAULT_RPC, type AddressSet, type HexAddress, type HexBytes32, type RecintoRow, type Role } from "../addressbook/types.ts";
import { pathById } from "../catalog/paths.ts";
import { computeDealId, dualSignTypes, eip712Domain, hashDualSign } from "../consent/eip712.ts";
import { parseDraft, parseIdOverride } from "../consent/parse.ts";
import { preflightActivateCore } from "../consent/preflight.ts";
import {
  accountFromPk,
  signControllerAcceptance,
  signDualSign,
  signHolderAuthorization,
  signProviderAgreement,
} from "../consent/sign.ts";
import { fetchCourtPref } from "../deal/courtPref.ts";
import type { DriftRow } from "../deal/drift.ts";
import {
  fetchAllowance,
  fetchBindings,
  fetchCredit,
  fetchDeal,
  fetchRuling,
  fetchStatus,
  fetchUsed,
  isEmptyDealId,
  resolveDealId,
} from "../deal/fetch.ts";
import { ZERO_BYTES32, isHexBytes32, isZeroAddress } from "../deal/types.ts";
import { matrixForDeal } from "../eligibility/matrix.ts";
import { encodeMockProof } from "../lab/proof.ts";
import { anvilIncreaseTime, labApprove, labDeposit, labMint, labSetHuman, labSubmitRuling } from "../lab/verbs.ts";
import { probePool } from "../pool/probe.ts";
import { poolAuthorize, poolDeposit, poolReconcile, poolUnlock } from "../pool/verbs.ts";
import { rampQuote, rampSend } from "../ramp/verbs.ts";
import { probeRecinto } from "../recinto/probe.ts";
import { emptyDualSign, isDraftComplete, toMatrixDraft } from "../session/DualSignDraft.ts";
import { parseModsDraft, probeSlots } from "../slots/probe.ts";
import { computedIds, slotRows } from "../slots/resolve.ts";
import { emptyModsDraft, emptyPolicy } from "../slots/types.ts";
import { sendActivate6 } from "../verbs/activateCore.ts";
import { sendActivate7 } from "../verbs/activatePackaged.ts";
import { isCoreWrite, sendCoreWrite } from "../verbs/coreWrites.ts";
import { sendDualSign } from "../verbs/dualSign.ts";
import { isZkArb, sendZkArb } from "../verbs/zkArb.ts";
import * as S from "./store.ts";

const msg = (err: unknown) => (err instanceof Error ? err.message : String(err));

// --- recinto -------------------------------------------------------------------------------------------------------------

export async function refreshProbe(): Promise<void> {
  if (!S.escrowPaste.value) return;
  S.probing.value = true;
  S.probe.value = await probeRecinto(S.rpcUrl.value, S.escrowPaste.value);
  S.probing.value = false;
  void refreshHead();
}

export async function refreshHead(): Promise<void> {
  try {
    const client = createPublicClient({ transport: http(S.rpcUrl.value) });
    const b = await client.getBlock({ blockTag: "latest" });
    S.chainHead.value = { number: b.number, timestamp: b.timestamp };
  } catch {
    S.chainHead.value = null;
  }
}

export function focusRecinto(row: RecintoRow): void {
  S.chainId.value = row.chainId;
  S.escrowPaste.value = row.escrow;
  S.rpcUrl.value = DEFAULT_RPC[row.chainId] ?? S.rpcUrl.value;
  S.probe.value = null;
  clearDeal();
  clearConsentSigs();
  S.modsDraft.value = emptyModsDraft();
  S.idsOverride.value = "";
  S.policy.value = emptyPolicy();
  S.draft.value = { ...S.draft.value, token: S.suggestedToken() ?? S.draft.value.token };
  void refreshProbe();
  void refreshSlots();
}

export function focusSet(set: AddressSet): void {
  if (!set.escrow || set.chainId === null) return;
  focusRecinto({
    chainId: set.chainId,
    escrow: set.escrow,
    sources: [set.sourceFile],
    testTokens: set.testToken ? [{ sourceFile: set.sourceFile, token: set.testToken }] : [],
  });
}

export function setChain(id: number): void {
  S.chainId.value = id;
  S.rpcUrl.value = DEFAULT_RPC[id] ?? S.rpcUrl.value;
  S.probe.value = null;
  clearDeal();
  clearConsentSigs();
  void refreshPreflight();
}

export function setEscrowPaste(value: string): void {
  S.escrowPaste.value = value.trim();
  S.probe.value = null;
  clearDeal();
  clearConsentSigs();
  if (isAddress(S.escrowPaste.value)) void refreshProbe();
  void refreshPreflight();
}

// --- asientos ---------------------------------------------------------------------------------------------------------------

export function setSeatAddress(role: Role, value: string): void {
  const v = value.trim();
  S.seats.value = S.seats.value.map((s) =>
    s.role === role ? { ...s, address: !v ? null : isAddress(v) ? getAddress(v) : v } : s,
  );
  void refreshExtras();
}

export function setSeatPk(role: Role, value: string): void {
  const v = value.trim();
  let address: string | null | undefined;
  if (v) {
    try {
      address = accountFromPk(v).address;
    } catch {
      address = undefined;
    }
  }
  S.seats.value = S.seats.value.map((s) =>
    s.role === role ? { ...s, pk: v || null, address: address === undefined ? s.address : address } : s,
  );
  void refreshExtras();
}

export function setActiveRole(role: Role): void {
  S.activeRole.value = role;
  void refreshExtras();
}

export function fillSeatsIntoDraft(): void {
  const h = S.seat("Holder").address ?? "";
  const p = S.seat("Provider").address ?? "";
  const c = S.seat("Controller").address ?? "";
  S.draft.value = { ...S.draft.value, holder: h, provider: p, controller: S.draft.value.p2p ? h : c };
  clearConsentSigs();
  void refreshPreflight();
}

// --- deal -----------------------------------------------------------------------------------------------------------------------

export function clearDeal(): void {
  S.deal.value = null;
  S.bindings.value = [];
  S.dealError.value = null;
  S.lookup.value = { dealId: "", signer: "", nonce: "" };
  S.credit.value = null;
  S.ruling.value = null;
  S.courtPref.value = null;
  S.dualForm.value = emptyDualSign();
  S.recoveredP.value = null;
  S.recoveredC.value = null;
  S.writeError.value = null;
}

export async function loadDeal(input?: { dealId?: string; signer?: string; nonce?: string }): Promise<void> {
  const escrow = S.escrow.value;
  if (!escrow) {
    S.dealError.value = "escrow inválido";
    S.deal.value = null;
    return;
  }
  const req = { ...S.lookup.value, ...(input ?? {}) };
  S.lookup.value = req;
  S.dealLoading.value = true;
  S.dealError.value = null;
  try {
    const dealId = await resolveDealId(S.rpcUrl.value, escrow, req);
    if (isEmptyDealId(dealId) || dealId === ZERO_BYTES32) {
      S.deal.value = null;
      S.dealError.value = "NONE: dealOf vacío o dealId 0x0. No hay Deal.";
      return;
    }
    const d = await fetchDeal(S.rpcUrl.value, escrow, dealId);
    if (d.status === 0 && d.clocks.activatedAt === 0n) {
      S.deal.value = null;
      S.bindings.value = [];
      S.dealError.value = "NONE: IEscrow.status = 0. No hay Deal en este recinto (¿recinto correcto?).";
      return;
    }
    const previousId = S.deal.value?.dealId;
    S.deal.value = d;
    S.lookup.value = { ...req, dealId: d.dealId };
    S.chainHead.value = { number: d.blockNumber, timestamp: d.blockTimestamp };
    S.bindings.value = await fetchBindings(S.rpcUrl.value, escrow, d.modules);
    if (previousId !== d.dealId) {
      S.dualForm.value = { ...emptyDualSign(d.dealId), deadline: String(d.blockTimestamp + 86_400n), type: S.dualForm.value.type };
      S.recoveredP.value = null;
      S.recoveredC.value = null;
    }
    await refreshExtras();
  } catch (err) {
    S.deal.value = null;
    S.bindings.value = [];
    S.dealError.value = msg(err);
  } finally {
    S.dealLoading.value = false;
  }
}

export async function reloadDeal(): Promise<void> {
  if (!S.deal.value) return;
  await loadDeal({ dealId: S.deal.value.dealId, signer: "", nonce: "" });
}

export async function refreshExtras(): Promise<void> {
  const d = S.deal.value;
  const escrow = S.escrow.value;
  if (!d || !escrow) return;
  const sender = S.activeSender.value;
  try {
    S.credit.value = sender ? await fetchCredit(S.rpcUrl.value, escrow, d.terms.token, sender) : null;
  } catch {
    S.credit.value = null;
  }
  if (!isZeroAddress(d.modules.court)) {
    S.ruling.value = await fetchRuling(S.rpcUrl.value, d.modules.court, d.dealId);
    try {
      S.courtPref.value = await fetchCourtPref(S.rpcUrl.value, d.modules.court, d.terms.controller);
    } catch {
      S.courtPref.value = null;
    }
  } else {
    S.ruling.value = null;
    S.courtPref.value = null;
  }
  try {
    S.dealPolicy.value = await probeSlots(S.rpcUrl.value, d.modules, d.terms.holder, d.terms.provider);
  } catch {
    S.dealPolicy.value = emptyPolicy();
  }
  await refreshDualUsed();
}

export async function refreshDualUsed(): Promise<void> {
  const d = S.deal.value;
  const escrow = S.escrow.value;
  if (!d || !escrow) return;
  try {
    S.dsUsedP.value = await fetchUsed(S.rpcUrl.value, escrow, d.terms.provider, BigInt(S.dualForm.value.nonceP || "0"));
    S.dsUsedC.value = await fetchUsed(S.rpcUrl.value, escrow, d.terms.controller, BigInt(S.dualForm.value.nonceC || "0"));
  } catch {
    S.dsUsedP.value = false;
    S.dsUsedC.value = false;
  }
}

export function driftForDeal(): DriftRow[] {
  const d = S.deal.value;
  if (!d) return [];
  return slotRows(d.modules, d.terms.packageIds, S.dealPolicy.value, S.escrowPaste.value)
    .filter((r) => r.address)
    .map((r) => ({ slot: r.slot, liveId: r.id, inSigned: r.inIds === true }));
}

export function currentMatrix() {
  const d = S.deal.value;
  if (!d) return [];
  const drift = driftForDeal();
  const cp = S.courtPref.value;
  return matrixForDeal(d, S.activeSender.value, {
    credit: S.credit.value,
    ruling: S.ruling.value,
    dualSign: toMatrixDraft(S.dualForm.value, {
      now: S.chainHead.value?.timestamp ?? d.blockTimestamp,
      usedP: S.dsUsedP.value,
      usedC: S.dsUsedC.value,
      provider: d.terms.provider,
      controller: d.terms.controller,
      recoveredP: S.recoveredP.value,
      recoveredC: S.recoveredC.value,
    }),
    driftZk: drift.some((r) => r.slot === "zk" && r.liveId !== null && !r.inSigned),
    driftArb: drift.some((r) => r.slot === "court" && r.liveId !== null && !r.inSigned),
    proof: S.labProof.value,
    courtPref: cp
      ? { kind: cp.kind, courtFee: cp.courtFee, allowance: cp.allowance, cost: cp.cost, msgValue: cp.kind === "kleros" ? cp.cost : 0n }
      : null,
  });
}

// --- verbos del deal ---------------------------------------------------------------------------------------------------------------

export async function sendVerb(verb: string): Promise<void> {
  const d = S.deal.value;
  const escrow = S.escrow.value;
  if (!d || !escrow) return;
  if (verb === "mutualCancel" || verb === "coSignedRelease" || verb === "mutualSplit") return relayDual();
  const role = S.activeRole.value;
  const pk = S.seatPk(role);
  const sender = S.activeSender.value;
  if (!pk) {
    S.writeError.value = `El asiento ${role} no tiene pk de sesión: no puede enviar.`;
    return;
  }
  S.sending.value = verb;
  S.writeError.value = null;
  try {
    let hash: Hex;
    if (isZkArb(verb)) {
      if (!S.flags.value.zkArb) throw new Error("flag zkArb off");
      hash = await sendZkArb({
        rpcUrl: S.rpcUrl.value,
        chainId: S.effectiveChainId.value,
        escrow,
        pk,
        verb,
        dealId: d.dealId,
        proof: (S.labProof.value as Hex | null) ?? "0x",
        value: S.courtPref.value?.kind === "kleros" ? (S.courtPref.value.cost ?? 0n) : 0n,
      });
    } else if (isCoreWrite(verb)) {
      if (!S.flags.value.coreWrites) throw new Error("flag coreWrites off");
      hash = await sendCoreWrite({
        rpcUrl: S.rpcUrl.value,
        chainId: S.effectiveChainId.value,
        escrow,
        pk,
        verb,
        dealId: d.dealId,
        token: d.terms.token,
        nonce: BigInt(S.cancelNonceInput.value || "0"),
      });
    } else throw new Error(`verbo desconocido: ${verb}`);
    S.logTx({ verb, seat: role, sender, dealId: d.dealId, hash });
    advancePathIfMatches(verb);
    await reloadDeal();
  } catch (err) {
    S.writeError.value = msg(err);
    S.logTx({ verb, seat: role, sender, dealId: d.dealId, error: msg(err) });
  } finally {
    S.sending.value = null;
  }
}

// --- dual-sign -------------------------------------------------------------------------------------------------------------------------

export function dualDigests(): { p: string | null; c: string | null } {
  const f = S.dualForm.value;
  const escrow = S.escrow.value;
  if (!f.type || !f.dealId || !f.deadline || f.deadline === "0" || !escrow) return { p: null, c: null };
  const base = {
    dealId: f.dealId as Hex,
    deadline: BigInt(f.deadline),
    providerBps: f.type === "MutualSplit" ? Number(f.providerBps || "0") : undefined,
  };
  try {
    return {
      p: hashDualSign(f.type, S.effectiveChainId.value, escrow, { ...base, nonce: BigInt(f.nonceP || "0") }),
      c: hashDualSign(f.type, S.effectiveChainId.value, escrow, { ...base, nonce: BigInt(f.nonceC || "0") }),
    };
  } catch {
    return { p: null, c: null };
  }
}

export async function signDual(who: "P" | "C"): Promise<void> {
  const f = S.dualForm.value;
  const escrow = S.escrow.value;
  if (!f.type || !escrow) {
    S.writeError.value = "Elegí el type y un Recinto.";
    return;
  }
  const role: Role = who === "P" ? "Provider" : "Controller";
  const pk = S.seatPk(role) ?? (role === "Controller" && S.p2pSeats.value ? S.seatPk("Holder") : null);
  if (!pk) {
    S.writeError.value = `${role} sin pk de sesión.`;
    return;
  }
  const chainId = S.effectiveChainId.value;
  const m = {
    dealId: f.dealId as Hex,
    nonce: BigInt(who === "P" ? f.nonceP || "0" : f.nonceC || "0"),
    deadline: BigInt(f.deadline || "0"),
    providerBps: f.type === "MutualSplit" ? Number(f.providerBps || "0") : undefined,
  };
  try {
    const sig = await signDualSign(pk, chainId, escrow, f.type, m);
    const recovered =
      f.type === "MutualSplit"
        ? await recoverTypedDataAddress({
            domain: eip712Domain(chainId, escrow),
            types: dualSignTypes,
            primaryType: "MutualSplit",
            message: { dealId: m.dealId, providerBps: m.providerBps ?? 0, nonce: m.nonce, deadline: m.deadline },
            signature: sig,
          })
        : await recoverTypedDataAddress({
            domain: eip712Domain(chainId, escrow),
            types: dualSignTypes,
            primaryType: f.type,
            message: { dealId: m.dealId, nonce: m.nonce, deadline: m.deadline },
            signature: sig,
          });
    if (who === "P") {
      S.dualForm.value = { ...S.dualForm.value, providerSig: sig };
      S.recoveredP.value = recovered;
    } else {
      S.dualForm.value = { ...S.dualForm.value, controllerSig: sig };
      S.recoveredC.value = recovered;
    }
    S.writeError.value = null;
    advancePathIfMatches(`sign ${f.type} (${who})`);
  } catch (err) {
    S.writeError.value = msg(err);
  }
}

export async function relayDual(): Promise<void> {
  const f = S.dualForm.value;
  const d = S.deal.value;
  const escrow = S.escrow.value;
  if (!S.flags.value.dualSign || !f.type || !isDraftComplete(f) || !d || !escrow) {
    S.writeError.value = "Draft dual-sign incompleto (type, deadline, nonces y las dos firmas).";
    return;
  }
  const pk = S.seatPk("Relayer") ?? S.seatPk(S.activeRole.value);
  if (!pk) {
    S.writeError.value = "Relayer sin pk de sesión.";
    return;
  }
  const verb = `${f.type[0]!.toLowerCase()}${f.type.slice(1)}`;
  S.sending.value = verb;
  try {
    const hash = await sendDualSign({
      rpcUrl: S.rpcUrl.value,
      chainId: S.effectiveChainId.value,
      escrow,
      pk,
      type: f.type,
      dealId: f.dealId as Hex,
      deadline: BigInt(f.deadline),
      nonceP: BigInt(f.nonceP || "0"),
      nonceC: BigInt(f.nonceC || "0"),
      providerBps: Number(f.providerBps || "0"),
      providerSig: f.providerSig!,
      controllerSig: f.controllerSig!,
    });
    S.logTx({ verb, seat: "Relayer", sender: S.seatAddress("Relayer"), dealId: d.dealId, hash });
    S.writeError.value = null;
    advancePathIfMatches(`relay ${verb}`);
    await reloadDeal();
  } catch (err) {
    S.writeError.value = msg(err);
    S.logTx({ verb, seat: "Relayer", sender: S.seatAddress("Relayer"), dealId: d.dealId, error: msg(err) });
  } finally {
    S.sending.value = null;
  }
}

export function setDualForm(next: typeof S.dualForm.value): void {
  S.dualForm.value = next;
  S.recoveredP.value = null;
  S.recoveredC.value = null;
  void refreshDualUsed();
}

// --- consentimiento ------------------------------------------------------------------------------------------------------------------

export function currentPackageIds(): HexBytes32[] {
  if (!S.flags.value.packages) return [];
  try {
    const override = parseIdOverride(S.idsOverride.value);
    if (override) return override;
  } catch {
    return [];
  }
  return computedIds(parseModsDraft(S.modsDraft.value), S.policy.value);
}

export function tryParsed() {
  try {
    return parseDraft(S.draft.value, currentPackageIds());
  } catch {
    return null;
  }
}

export function clearConsentSigs(): void {
  S.holderSig.value = null;
  S.providerSig.value = null;
  S.controllerSig.value = null;
  S.preflight.value = [];
  S.projectedDealId.value = null;
  S.sendError.value = null;
}

export function setDraft(next: typeof S.draft.value): void {
  S.draft.value = next;
  clearConsentSigs();
  void refreshPreflight();
}

export function setModsDraft(next: typeof S.modsDraft.value): void {
  S.modsDraft.value = next;
  clearConsentSigs();
  void refreshSlots();
}

export function setIdsOverride(value: string): void {
  S.idsOverride.value = value;
  clearConsentSigs();
  void refreshPreflight();
}

export async function refreshSlots(): Promise<void> {
  const mods = parseModsDraft(S.modsDraft.value);
  const parsed = tryParsed();
  try {
    S.policy.value = await probeSlots(S.rpcUrl.value, mods, parsed?.terms.holder ?? null, parsed?.terms.provider ?? null);
  } catch {
    S.policy.value = emptyPolicy();
  }
  await refreshPreflight();
}

export async function refreshPreflight(): Promise<void> {
  const parsed = tryParsed();
  const escrow = S.escrow.value;
  if (!parsed || !escrow) {
    S.preflight.value = [];
    S.projectedDealId.value = null;
    return;
  }
  const chainId = S.effectiveChainId.value;
  const now = S.chainHead.value?.timestamp ?? BigInt(Math.floor(Date.now() / 1000));
  let usedHolder = false;
  let usedProvider = false;
  let usedController = false;
  let allowance: bigint | null = null;
  let dealStatus: number | null = null;
  try {
    [usedHolder, usedProvider, usedController] = await Promise.all([
      fetchUsed(S.rpcUrl.value, escrow, parsed.terms.holder, parsed.ha.nonce),
      fetchUsed(S.rpcUrl.value, escrow, parsed.terms.provider, parsed.pa.nonce),
      fetchUsed(S.rpcUrl.value, escrow, parsed.terms.controller, parsed.ca.nonce),
    ]);
  } catch {
    /* offline */
  }
  try {
    allowance = await fetchAllowance(S.rpcUrl.value, parsed.terms.token, parsed.terms.holder, escrow);
  } catch {
    allowance = null;
  }
  const domain = S.probe.value?.domainSeparator ?? null;
  if (domain) {
    const id = computeDealId(domain, parsed.terms, parsed.ha.nonce, parsed.pa.nonce, parsed.ca.nonce);
    S.projectedDealId.value = id;
    try {
      dealStatus = await fetchStatus(S.rpcUrl.value, escrow, id);
    } catch {
      dealStatus = null;
    }
  }
  S.preflight.value = await preflightActivateCore({
    terms: parsed.terms,
    ha: parsed.ha,
    pa: parsed.pa,
    ca: parsed.ca,
    holderSig: S.holderIsPool.value ? ("0x" as Hex) : S.holderSig.value,
    providerSig: S.providerSig.value,
    controllerSig: S.controllerSig.value,
    chainId,
    escrow,
    now,
    usedHolder,
    usedProvider,
    usedController,
    allowance,
    dealStatus,
    coreActivate: S.flags.value.coreActivate,
    distinctController: S.flags.value.distinctController,
    packages: S.flags.value.packages,
    mods: parseModsDraft(S.modsDraft.value),
    policy: S.policy.value,
    holderIsPool: S.holderIsPool.value,
  });
}

export async function signEnvelope(which: "HA" | "PA" | "CA"): Promise<void> {
  const parsed = tryParsed();
  const escrow = S.escrow.value;
  const role: Role = which === "HA" ? "Holder" : which === "PA" ? "Provider" : "Controller";
  const pk = S.seatPk(role);
  if (!parsed || !escrow) {
    S.sendError.value = "DealTerms inválidos (addresses, principal).";
    return;
  }
  if (!pk) {
    S.sendError.value = `El asiento ${role} no tiene pk de sesión.`;
    return;
  }
  if (which === "CA" && parsed.terms.holder === parsed.terms.controller) {
    S.sendError.value = "P2P: la CA es dummy, no se firma.";
    return;
  }
  const chainId = S.effectiveChainId.value;
  try {
    if (which === "HA") S.holderSig.value = await signHolderAuthorization(pk, chainId, escrow, parsed.ha);
    else if (which === "PA") S.providerSig.value = await signProviderAgreement(pk, chainId, escrow, parsed.pa);
    else S.controllerSig.value = await signControllerAcceptance(pk, chainId, escrow, parsed.ca);
    S.sendError.value = null;
    advancePathIfMatches(which === "HA" ? "sign HolderAuthorization" : which === "PA" ? "sign ProviderAgreement" : "sign ControllerAcceptance");
    if (which === "HA" || which === "PA") advancePathIfMatches("sign HA + PA");
  } catch (err) {
    S.sendError.value = msg(err);
  }
  void refreshPreflight();
}

export async function sendActivate(): Promise<void> {
  const parsed = tryParsed();
  const escrow = S.escrow.value;
  const pk = S.seatPk("Relayer");
  if (!parsed || !escrow) {
    S.sendError.value = "DealTerms inválidos.";
    return;
  }
  if (!pk) {
    S.sendError.value = "Relayer sin pk de sesión.";
    return;
  }
  if (!S.flags.value.coreActivate) {
    S.sendError.value = "flag coreActivate off";
    return;
  }
  const hSig = S.holderIsPool.value ? ("0x" as Hex) : S.holderSig.value;
  if (!hSig || !S.providerSig.value) {
    S.sendError.value = "Faltan firmas HA / PA.";
    return;
  }
  const distinct = parsed.terms.holder !== parsed.terms.controller;
  if (distinct && !S.controllerSig.value) {
    S.sendError.value = "Controller distinto: falta la CA firmada.";
    return;
  }
  const mods = parseModsDraft(S.modsDraft.value);
  const packaged = S.flags.value.packages && Object.values(mods).some((a) => !isZeroAddress(a));
  S.sending.value = "activate";
  try {
    const common = {
      rpcUrl: S.rpcUrl.value,
      chainId: S.effectiveChainId.value,
      escrow,
      relayerPk: pk as Hex,
      ha: parsed.ha,
      holderSig: hSig,
      pa: parsed.pa,
      providerSig: S.providerSig.value,
      ca: distinct ? parsed.ca : null,
      controllerSig: distinct ? S.controllerSig.value : null,
    };
    const hash = packaged ? await sendActivate7({ ...common, mods }) : await sendActivate6(common);
    const dealId = S.projectedDealId.value;
    S.lastActivated.value = { dealId: dealId ?? "", hash };
    S.logTx({ verb: packaged ? "activate(7)" : "activate(6)", seat: "Relayer", sender: S.seatAddress("Relayer"), dealId, hash });
    S.sendError.value = null;
    advancePathIfMatches("activate");
    if (dealId) {
      S.space.value = "deal";
      await loadDeal({ dealId, signer: "", nonce: "" });
    }
    clearConsentSigs();
    void refreshPreflight();
  } catch (err) {
    S.sendError.value = msg(err);
    S.logTx({ verb: "activate", seat: "Relayer", sender: S.seatAddress("Relayer"), dealId: S.projectedDealId.value, error: msg(err) });
  } finally {
    S.sending.value = null;
  }
}

// --- paths ------------------------------------------------------------------------------------------------------------------------------------

export function startPath(id: string): void {
  const p = pathById(id);
  if (!p) return;
  S.activePath.value = p;
  S.pathStep.value = 0;
  const token = id === "PATH-RAMP-TAXI" ? (S.rampSetField("usdc") ?? S.draft.value.token) : (S.suggestedToken() ?? S.draft.value.token);
  const h = S.seat("Holder").address ?? S.draft.value.holder;
  const c = S.seat("Controller").address ?? S.draft.value.controller;
  S.draft.value = {
    ...S.draft.value,
    p2p: p.p2p,
    holder: h,
    provider: S.seat("Provider").address ?? S.draft.value.provider,
    controller: p.p2p ? h : c,
    token,
    fiatDuration: p.fiatDuration,
    releaseDuration: p.releaseDuration,
    disputeDuration: p.disputeDuration,
    arbitrationDuration: p.arbitrationDuration,
    deadline: String(Math.floor(Date.now() / 1000) + 86_400),
  };
  S.holderIsPool.value = id === "PATH-POOL-HOLDER";
  if (id === "PATH-POOL-HOLDER") S.draft.value = { ...S.draft.value, holder: S.suggestedPool() ?? S.draft.value.holder, p2p: false };
  if (!p.needs.includes("packages")) {
    S.modsDraft.value = emptyModsDraft();
    S.idsOverride.value = "";
  }
  if (S.dualForm.value.type && /MutualCancel|CoSignedRelease|MutualSplit/.test(p.sequence) === false) {
    /* keep */
  }
  const dsType = /mutualCancel/i.test(p.sequence) ? "MutualCancel" : /coSigned/i.test(p.sequence) ? "CoSignedRelease" : /split/i.test(p.sequence) ? "MutualSplit" : null;
  const bps = /bps=(\d+)/.exec(p.sequence)?.[1];
  if (dsType) S.dualForm.value = { ...S.dualForm.value, type: dsType, providerBps: bps ?? S.dualForm.value.providerBps };
  clearConsentSigs();
  S.space.value = p.steps[0]?.space ?? "consent";
  void refreshPreflight();
}

export function stopPath(): void {
  S.activePath.value = null;
  S.pathStep.value = 0;
}

export function gotoPathStep(i: number): void {
  const p = S.activePath.value;
  if (!p) return;
  S.pathStep.value = Math.max(0, Math.min(i, p.steps.length - 1));
  const step = p.steps[S.pathStep.value];
  if (step) S.space.value = step.space;
}

/** Si el verbo enviado coincide con el paso actual del Path, avanza. Nunca oculta nada. */
function advancePathIfMatches(verb: string): void {
  const p = S.activePath.value;
  if (!p) return;
  const step = p.steps[S.pathStep.value];
  if (!step) return;
  const head = step.verb.split(/[\s({]/)[0]!;
  const v = verb.split(/[\s({]/)[0]!;
  if (head.toLowerCase() === v.toLowerCase() || step.verb.startsWith(verb) || verb.startsWith(step.verb)) {
    if (S.pathStep.value < p.steps.length - 1) S.pathStep.value += 1;
  }
}

export function markPathStepDone(): void {
  const p = S.activePath.value;
  if (!p) return;
  if (S.pathStep.value < p.steps.length - 1) gotoPathStep(S.pathStep.value + 1);
}

// --- laboratorio ---------------------------------------------------------------------------------------------------------------------------------

export function encodeLabProof(): void {
  const f = S.labForm.value;
  const dealId = f.dealId || S.deal.value?.dealId || "";
  if (!isHexBytes32(dealId) || !isHexBytes32(f.nullifier)) {
    S.labError.value = "dealId y nullifier deben ser bytes32.";
    return;
  }
  S.labProof.value = encodeMockProof(dealId, f.nullifier);
  S.labError.value = null;
  S.labLog.value = [{ verb: "abi.encode(dealId, nullifier)", note: "payload mock listo para verifyProof" }, ...S.labLog.value];
  advancePathIfMatches("ensamblar abi.encode(dealId, nullifier)");
}

export async function runLab(kind: "setHuman" | "submitRuling" | "mint" | "approve" | "deposit" | "warp"): Promise<void> {
  if (!S.flags.value.labVerbs) {
    S.labError.value = "flag labVerbs off";
    return;
  }
  const role = S.activeRole.value;
  const pk = S.seatPk(role);
  const chainId = S.effectiveChainId.value;
  const f = S.labForm.value;
  const token = S.draft.value.token || S.suggestedToken() || "";
  S.sending.value = kind;
  try {
    if (kind === "warp") {
      if (chainId !== 31337) throw new Error("El reloj LAB solo existe en Anvil (31337).");
      await anvilIncreaseTime(S.rpcUrl.value, Number(f.warp || "0"));
      S.labLog.value = [{ verb: `evm_increaseTime(${f.warp})`, note: "block.timestamp avanzado; nuevo bloque minado" }, ...S.labLog.value];
      await refreshHead();
      if (S.deal.value) await reloadDeal();
      S.labError.value = null;
      return;
    }
    if (!pk) throw new Error(`El asiento activo (${role}) no tiene pk de sesión.`);
    const common = { rpcUrl: S.rpcUrl.value, chainId, pk };
    let hash: Hex;
    let note = "";
    if (kind === "setHuman") {
      const passport = S.modsDraft.value.passport || S.deal.value?.modules.passport || "";
      if (!isAddress(passport) || isZeroAddress(passport) || !isAddress(f.wallet) || !isHexBytes32(f.subject)) {
        throw new Error("Hace falta el slot passport (Paquetes), una wallet y un subject bytes32.");
      }
      hash = await labSetHuman({ ...common, passport: getAddress(passport) as HexAddress, wallet: getAddress(f.wallet) as HexAddress, subject: f.subject });
      note = `PassportMock.setHuman(${f.wallet.slice(0, 8)}…) — mapa wallet→subject, sin auth`;
    } else if (kind === "submitRuling") {
      const court = S.modsDraft.value.court || S.deal.value?.modules.court || "";
      const dealId = f.dealId || S.deal.value?.dealId || "";
      if (!isAddress(court) || !isHexBytes32(dealId)) throw new Error("Hace falta el slot court y un dealId.");
      hash = await labSubmitRuling({ ...common, court: getAddress(court) as HexAddress, dealId: dealId as HexBytes32, ruling: Number(f.ruling || "0") });
      note = `ArbitrationMock.submitRuling(ruling=${f.ruling}) — sin auth; ahora readRuling es legal`;
      if (S.deal.value) await reloadDeal();
    } else if (kind === "mint") {
      if (!isAddress(token) || !isAddress(f.mintTo)) throw new Error("token (Consentimiento) y destinatario.");
      hash = await labMint({ ...common, token: getAddress(token) as HexAddress, to: getAddress(f.mintTo) as HexAddress, amount: BigInt(f.mintAmount || "0") });
      note = `TestToken.mint(${f.mintAmount}) — faucet de lab`;
    } else if (kind === "approve") {
      if (!isAddress(token) || !isAddress(f.approveSpender)) throw new Error("token y spender.");
      hash = await labApprove({ ...common, token: getAddress(token) as HexAddress, spender: getAddress(f.approveSpender) as HexAddress, amount: BigInt(f.approveAmount || "0") });
      note = `approve(${f.approveSpender.slice(0, 8)}…, ${f.approveAmount}) desde ${role}`;
      advancePathIfMatches("approve");
    } else {
      if (!isAddress(f.vault) || !isHexBytes32(f.subject) || !isAddress(token)) throw new Error("vault, subject bytes32 y token.");
      hash = await labDeposit({ ...common, vault: getAddress(f.vault) as HexAddress, subject: f.subject, token: getAddress(token) as HexAddress, amount: BigInt(f.depositAmount || "0") });
      note = `BondVault.deposit(subject, ${f.depositAmount})`;
      advancePathIfMatches("vault.deposit");
    }
    S.labLog.value = [{ verb: kind, hash, note }, ...S.labLog.value];
    S.logTx({ verb: `LAB ${kind}`, seat: role, sender: S.activeSender.value, dealId: S.deal.value?.dealId ?? null, hash });
    if (kind === "setHuman") advancePathIfMatches("PassportMock.setHuman");
    if (kind === "mint") advancePathIfMatches("mint + approve(vault)");
    if (kind === "submitRuling") advancePathIfMatches("ArbitrationMock.submitRuling");
    S.labError.value = null;
    void refreshSlots();
  } catch (err) {
    S.labError.value = msg(err);
  } finally {
    S.sending.value = null;
  }
}

// --- pool --------------------------------------------------------------------------------------------------------------------------------------

export async function refreshPool(): Promise<void> {
  if (!isAddress(S.poolPaste.value)) {
    S.poolError.value = "address de pool inválida";
    return;
  }
  try {
    S.poolSnap.value = await probePool(S.rpcUrl.value, getAddress(S.poolPaste.value) as HexAddress, S.activeSender.value);
    S.poolError.value = null;
  } catch (err) {
    S.poolSnap.value = null;
    S.poolError.value = msg(err);
  }
}

export async function runPool(kind: "deposit" | "authorize" | "unlock" | "reconcile"): Promise<void> {
  if (!S.flags.value.pool) {
    S.poolError.value = "flag pool off";
    return;
  }
  const role = S.activeRole.value;
  const pk = S.seatPk(role);
  if (!pk || !isAddress(S.poolPaste.value)) {
    S.poolError.value = `Asiento ${role} sin pk, o pool inválido.`;
    return;
  }
  const f = S.poolForm.value;
  const common = { rpcUrl: S.rpcUrl.value, chainId: S.effectiveChainId.value, pool: getAddress(S.poolPaste.value) as HexAddress, pk };
  S.sending.value = `pool.${kind}`;
  try {
    let hash: Hex;
    if (kind === "deposit") hash = await poolDeposit({ ...common, amount: BigInt(f.depositAmt || "0") });
    else if (kind === "authorize") {
      const parsed = tryParsed();
      if (!parsed) throw new Error("DealTerms inválidos en Consentimiento.");
      hash = await poolAuthorize({ ...common, ha: parsed.ha });
    } else if (kind === "unlock") hash = await poolUnlock({ ...common, nonce: BigInt(f.unlockNonce || "0") });
    else
      hash = await poolReconcile({
        ...common,
        nonce: BigInt(f.unlockNonce || "0"),
        providerNonce: BigInt(f.reconP || "0"),
        controllerNonce: BigInt(f.reconC || "0"),
      });
    S.logTx({ verb: `pool.${kind}`, seat: role, sender: S.activeSender.value, dealId: null, hash });
    advancePathIfMatches(`pool.${kind}`);
    S.poolError.value = null;
    await refreshPool();
  } catch (err) {
    S.poolError.value = msg(err);
  } finally {
    S.sending.value = null;
  }
}

// --- rampa --------------------------------------------------------------------------------------------------------------------------------------

function rampIntent() {
  const f = S.rampForm.value;
  if (!isAddress(f.ramp) || !isAddress(f.token) || !isAddress(f.to)) throw new Error("ramp, token y to deben ser addresses.");
  return {
    token: getAddress(f.token) as HexAddress,
    amount: BigInt(f.amount || "0"),
    minAmountOut: BigInt(f.minAmountOut || "0"),
    dest: Number(f.dest || "0"),
    to: getAddress(f.to) as HexAddress,
    refund: isAddress(f.refund) ? (getAddress(f.refund) as HexAddress) : (getAddress(f.to) as HexAddress),
  };
}

export async function runRampQuote(): Promise<void> {
  try {
    const q = await rampQuote(S.rpcUrl.value, getAddress(S.rampForm.value.ramp) as HexAddress, rampIntent());
    S.rampQuote.value = { nativeFee: String(q.nativeFee), amountOut: String(q.amountOut) };
    S.rampError.value = null;
  } catch (err) {
    S.rampError.value = msg(err);
  }
}

export async function runRampSend(): Promise<void> {
  const role = S.activeRole.value;
  const pk = S.seatPk(role);
  if (!S.flags.value.ramp || !pk) {
    S.rampError.value = "flag ramp off o asiento sin pk.";
    return;
  }
  S.sending.value = "ramp.send";
  try {
    const hash = await rampSend({
      rpcUrl: S.rpcUrl.value,
      chainId: S.effectiveChainId.value,
      ramp: getAddress(S.rampForm.value.ramp) as HexAddress,
      pk,
      intent: rampIntent(),
      value: S.rampQuote.value ? BigInt(S.rampQuote.value.nativeFee) : 0n,
    });
    S.logTx({ verb: "ramp.send", seat: role, sender: S.activeSender.value, dealId: null, hash });
    S.rampError.value = null;
  } catch (err) {
    S.rampError.value = msg(err);
  } finally {
    S.sending.value = null;
  }
}

export function pasteRampSet(): void {
  S.rampForm.value = {
    ...S.rampForm.value,
    ramp: S.rampSetField("ramp") ?? S.rampForm.value.ramp,
    token: S.rampSetField("usdc") ?? S.rampForm.value.token,
    dest: S.rampSetField("destEid") ?? S.rampForm.value.dest,
  };
}

// --- créditos --------------------------------------------------------------------------------------------------------------------------------------

export async function refreshCredits(): Promise<void> {
  const escrow = S.escrow.value;
  const token = S.creditToken.value || S.deal.value?.terms.token || S.suggestedToken() || "";
  if (!escrow || !isAddress(token)) {
    S.creditRows.value = [];
    return;
  }
  const who: { who: string; address: HexAddress }[] = [];
  for (const s of S.seats.value) {
    const a = S.seatAddress(s.role);
    if (a && !who.some((w) => w.address === a)) who.push({ who: s.role, address: a });
  }
  if (isAddress(S.creditExtra.value)) who.push({ who: "pegada", address: getAddress(S.creditExtra.value) as HexAddress });
  const rows = await Promise.all(
    who.map(async (w) => ({
      ...w,
      token: getAddress(token) as HexAddress,
      amount: await fetchCredit(S.rpcUrl.value, escrow, getAddress(token) as HexAddress, w.address).catch(() => 0n),
    })),
  );
  S.creditRows.value = rows;
}

export async function withdrawFor(role: Role, token: HexAddress): Promise<void> {
  const escrow = S.escrow.value;
  const pk = S.seatPk(role);
  if (!escrow || !pk) {
    S.writeError.value = `Asiento ${role} sin pk.`;
    return;
  }
  S.sending.value = `withdraw:${role}`;
  try {
    const hash = await sendCoreWrite({
      rpcUrl: S.rpcUrl.value,
      chainId: S.effectiveChainId.value,
      escrow,
      pk,
      verb: "withdraw",
      dealId: ZERO_BYTES32,
      token,
      nonce: 0n,
    });
    S.logTx({ verb: "withdraw", seat: role, sender: S.seatAddress(role), dealId: null, hash });
    advancePathIfMatches("withdraw");
    await refreshCredits();
  } catch (err) {
    S.writeError.value = msg(err);
  } finally {
    S.sending.value = null;
  }
}
