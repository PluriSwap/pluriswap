import { getAddress, isAddress, recoverTypedDataAddress, type Hex } from "viem";
import { loadBundledSets, recintosFromSets } from "./addressbook/load.ts";
import {
  DEFAULT_RPC,
  ROLES,
  type AddressSet,
  type HexAddress,
  type HexBytes32,
  type RecintoRow,
  type Role,
  type SeatState,
} from "./addressbook/types.ts";
import { renderAddressBook } from "./chrome/AddressBookDrawer.ts";
import { renderConsentPanel, defaultDraft, type ConsentDraft } from "./consent/ConsentPanel.ts";
import { computeDealId } from "./consent/eip712.ts";
import { parseDraft, parseIdOverride } from "./consent/parse.ts";
import { preflightActivateCore, type PreflightStep } from "./consent/preflight.ts";
import { dualSignTypes, eip712Domain, hashDualSign } from "./consent/eip712.ts";
import {
  accountFromPk,
  signControllerAcceptance,
  signDualSign,
  signHolderAuthorization,
  signProviderAgreement,
} from "./consent/sign.ts";
import { renderRecintoHome, type DealShortcut } from "./chrome/RecintoHome.ts";
import { renderRecintoSelector } from "./chrome/RecintoSelector.ts";
import { renderRoleStrip } from "./chrome/RoleStrip.ts";
import { renderDealEmpty, renderDealView } from "./deal/DealView.ts";
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
} from "./deal/fetch.ts";
import { ZERO_BYTES32, isHexBytes32, isZeroAddress, type DealSnapshot, type ModuleBinding } from "./deal/types.ts";
import { matrixForDeal } from "./eligibility/matrix.ts";
import { emptyDualSign, isDraftComplete, toMatrixDraft, type DualSignForm } from "./session/DualSignDraft.ts";
import { probeRecinto, type RecintoProbe } from "./recinto/probe.ts";
import { emptyLabForm, renderLabCage, type LabForm } from "./lab/LabCage.ts";
import { encodeMockProof } from "./lab/proof.ts";
import {
  anvilIncreaseTime,
  labApprove,
  labDeposit,
  labMint,
  labSetHuman,
  labSubmitRuling,
} from "./lab/verbs.ts";
import { sendActivate6 } from "./verbs/activateCore.ts";
import { fetchCourtPref, type CourtPref } from "./deal/courtPref.ts";
import type { DriftRow } from "./deal/DriftPanel.ts";
import { isZkArb, sendZkArb } from "./verbs/zkArb.ts";
import { renderPoolView } from "./pool/PoolView.ts";
import { probePool, type PoolSnapshot } from "./pool/probe.ts";
import { poolAuthorize, poolDeposit, poolReconcile, poolUnlock } from "./pool/verbs.ts";
import { PATHS, pathById } from "./catalog/paths.ts";
import { renderCatalogSpace } from "./catalog/CatalogSpace.ts";
import { emptyRampForm, renderRampView, type RampForm } from "./ramp/RampView.ts";
import { rampQuote, rampSend } from "./ramp/verbs.ts";
import { sendActivate7 } from "./verbs/activatePackaged.ts";
import { renderPackageModsPanel } from "./slots/PackageModsPanel.ts";
import { contestDue } from "./packageid/hash.ts";
import { computedIds, slotRows } from "./slots/resolve.ts";
import { parseModsDraft, probeSlots } from "./slots/probe.ts";
import {
  emptyModsDraft,
  emptyPolicy,
  modsEmpty,
  type LivePolicy,
  type ModsDraft,
} from "./slots/types.ts";
import { isCoreWrite, sendCoreWrite } from "./verbs/coreWrites.ts";
import { sendDualSign } from "./verbs/dualSign.ts";
import "./style.css";

const sets = loadBundledSets();
const recintos = recintosFromSets(sets);

const first = recintos.find((r) => r.chainId === 421614) ?? recintos[0];

const state = {
  chainId: first?.chainId ?? 421614,
  rpcUrl: DEFAULT_RPC[first?.chainId ?? 421614] ?? "",
  escrowPaste: (first?.escrow ?? "") as string,
  seats: ROLES.map((role): SeatState => ({ role, address: null, pk: null })),
  activeRole: "Relayer" as Role,
  probe: null as RecintoProbe | null,
  probing: false,
  lookupDealId: "",
  lookupSigner: "",
  lookupNonce: "",
  deal: null as DealSnapshot | null,
  bindings: [] as ModuleBinding[],
  dealError: null as string | null,
  dealLoading: false,
  credit: null as bigint | null,
  ruling: null as number | null,
  coreActivate: true,
  distinctController: true,
  draft: defaultDraft("") as ConsentDraft,
  holderSig: null as Hex | null,
  providerSig: null as Hex | null,
  controllerSig: null as Hex | null,
  preflight: [] as PreflightStep[],
  projectedDealId: null as string | null,
  sending: false,
  sendError: null as string | null,
  coreWrites: true,
  cancelNonce: "1",
  writeError: null as string | null,
  dualSign: true,
  dualForm: emptyDualSign() as DualSignForm,
  dsUsedP: false,
  dsUsedC: false,
  recoveredP: null as string | null,
  recoveredC: null as string | null,
  packages: true,
  modsDraft: emptyModsDraft() as ModsDraft,
  idsOverride: "",
  policy: emptyPolicy() as LivePolicy,
  labVerbs: true,
  labForm: emptyLabForm() as LabForm,
  labProof: null as string | null,
  labError: null as string | null,
  zkArb: true,
  courtPref: null as CourtPref | null,
  contestAllowance: null as bigint | null,
  dealPolicy: emptyPolicy() as LivePolicy,
  poolFlag: true,
  holderIsPool: false,
  poolPaste: "",
  poolSnap: null as PoolSnapshot | null,
  poolError: null as string | null,
  poolDepositAmt: "1000000",
  poolUnlockNonce: "1",
  poolReconP: "1",
  poolReconC: "1",
  rampFlag: true,
  rampForm: emptyRampForm() as RampForm,
  rampQuote: null as { nativeFee: string; amountOut: string } | null,
  rampError: null as string | null,
};

const el = {
  selector: document.querySelector<HTMLElement>("#recinto-selector")!,
  roles: document.querySelector<HTMLElement>("#role-strip")!,
  home: document.querySelector<HTMLElement>("#recinto-home")!,
  deal: document.querySelector<HTMLElement>("#deal-view")!,
  consent: document.querySelector<HTMLElement>("#consent")!,
  slots: document.querySelector<HTMLElement>("#slots")!,
  lab: document.querySelector<HTMLElement>("#lab")!,
  pool: document.querySelector<HTMLElement>("#pool")!,
  ramp: document.querySelector<HTMLElement>("#ramp")!,
  catalog: document.querySelector<HTMLElement>("#catalog")!,
  book: document.querySelector<HTMLElement>("#address-book")!,
};

function paint(): void {
  renderRecintoSelector(
    el.selector,
    {
      chainId: state.chainId,
      rpcUrl: state.rpcUrl,
      escrowPaste: state.escrowPaste,
      recintos,
      probe: state.probe,
      probing: state.probing,
    },
    {
      chainId: (id) => {
        state.chainId = id;
        state.probe = null;
        clearDeal();
        clearConsentSigs();
        paint();
        void refreshPreflight();
      },
      rpcUrl: (url) => {
        state.rpcUrl = url;
        paint();
      },
      escrow: (value) => {
        state.escrowPaste = value;
        state.probe = null;
        clearDeal();
        clearConsentSigs();
        paint();
        void refreshPreflight();
      },
      pick: (row) => focusRecinto(row),
      probe: () => void refreshProbe(),
    },
  );
  renderRoleStrip(el.roles, state.seats, state.activeRole, {
    active: (role) => {
      state.activeRole = role;
      paint();
      void refreshExtras();
    },
    address: (role, value) => {
      const seat = state.seats.find((s) => s.role === role);
      if (!seat) return;
      seat.address = !value ? null : isAddress(value) ? getAddress(value) : value;
      paint();
      void refreshExtras();
    },
    pk: (role, value) => {
      const seat = state.seats.find((s) => s.role === role);
      if (!seat) return;
      seat.pk = value || null;
      if (value) {
        try {
          seat.address = accountFromPk(value).address;
        } catch {
          /* keep address */
        }
      }
      paint();
    },
  });
  renderConsentPanel(
    el.consent,
    {
      draft: state.draft,
      coreActivate: state.coreActivate,
      distinctController: state.distinctController,
      steps: state.preflight,
      holderSig: state.holderIsPool ? ("0x" as Hex) : state.holderSig,
      providerSig: state.providerSig,
      controllerSig: state.controllerSig,
      ha: tryParsed()?.ha ?? null,
      pa: tryParsed()?.pa ?? null,
      ca: tryParsed()?.ca ?? null,
      mods: state.packages ? parseModsDraft(state.modsDraft) : null,
      dealId: state.projectedDealId,
      sending: state.sending,
      sendError: state.sendError,
      suggestedToken: suggestedToken(),
    },
    {
      draft: (d) => {
        state.draft = d;
        state.holderSig = null;
        state.providerSig = null;
        state.controllerSig = null;
        state.sendError = null;
        paint();
        void refreshPreflight();
      },
      toggleFlag: () => {
        state.coreActivate = !state.coreActivate;
        paint();
        void refreshPreflight();
      },
      toggleDistinct: () => {
        state.distinctController = !state.distinctController;
        paint();
        void refreshPreflight();
      },
      fillSeats: () => {
        const h = state.seats.find((s) => s.role === "Holder")?.address ?? "";
        const p = state.seats.find((s) => s.role === "Provider")?.address ?? "";
        const c = state.seats.find((s) => s.role === "Controller")?.address ?? "";
        state.draft = {
          ...state.draft,
          holder: h,
          provider: p,
          controller: state.draft.p2p ? h : c,
        };
        state.holderSig = null;
        state.providerSig = null;
        state.controllerSig = null;
        paint();
        void refreshPreflight();
      },
      useToken: () => {
        const tok = suggestedToken();
        if (!tok) return;
        state.draft = { ...state.draft, token: tok };
        state.holderSig = null;
        state.providerSig = null;
        state.controllerSig = null;
        paint();
        void refreshPreflight();
      },
      signHa: () => void signHa(),
      signPa: () => void signPa(),
      signCa: () => void signCa(),
      send: () => void sendActivate(),
      refresh: () => void refreshPreflight(),
    },
  );
  const mods = parseModsDraft(state.modsDraft);
  const ids = currentPackageIds();
  renderPackageModsPanel(
    el.slots,
    {
      packages: state.packages,
      draft: state.modsDraft,
      rows: slotRows(mods, ids, state.policy, state.escrowPaste),
      ids,
      idsOverride: state.idsOverride,
      suggested: suggestedMods(),
    },
    {
      toggle: () => {
        state.packages = !state.packages;
        clearConsentSigs();
        paint();
        void refreshSlots();
      },
      draft: (d) => {
        state.modsDraft = d;
        clearConsentSigs();
        paint();
        void refreshSlots();
      },
      idsOverride: (value) => {
        state.idsOverride = value;
        clearConsentSigs();
        paint();
        void refreshPreflight();
      },
      pasteSet: () => {
        const s = suggestedMods();
        if (!s) return;
        state.modsDraft = s;
        clearConsentSigs();
        paint();
        void refreshSlots();
      },
    },
  );
  renderLabCage(
    el.lab,
    {
      labVerbs: state.labVerbs,
      form: state.labForm,
      proof: state.labProof,
      anvil: (state.probe?.rpcChainId ?? state.chainId) === 31337,
      error: state.labError,
      passport: state.modsDraft.passport,
      court: state.modsDraft.court,
      token: state.draft.token,
    },
    {
      toggle: () => {
        state.labVerbs = !state.labVerbs;
        paint();
      },
      form: (f) => {
        state.labForm = f;
      },
      setHuman: () => void runLab("setHuman"),
      encodeProof: () => encodeLabProof(),
      submitRuling: () => void runLab("submitRuling"),
      mint: () => void runLab("mint"),
      approve: () => void runLab("approve"),
      deposit: () => void runLab("deposit"),
      warp: () => void runLab("warp"),
    },
  );
  renderPoolView(
    el.pool,
    {
      poolFlag: state.poolFlag,
      poolPaste: state.poolPaste,
      snap: state.poolSnap,
      recinto: state.escrowPaste,
      holderIsPool: state.holderIsPool,
      depositAmt: state.poolDepositAmt,
      unlockNonce: state.poolUnlockNonce,
      reconP: state.poolReconP,
      reconC: state.poolReconC,
      error: state.poolError,
      suggested: suggestedPool(),
    },
    {
      toggle: () => {
        state.poolFlag = !state.poolFlag;
        paint();
      },
      poolPaste: (v) => {
        state.poolPaste = v;
        paint();
      },
      holderIsPool: () => {
        state.holderIsPool = !state.holderIsPool;
        if (state.holderIsPool) {
          state.draft = { ...state.draft, p2p: false };
          state.distinctController = true;
        }
        clearConsentSigs();
        paint();
        void refreshPreflight();
      },
      depositAmt: (v) => {
        state.poolDepositAmt = v;
      },
      unlockNonce: (v) => {
        state.poolUnlockNonce = v;
      },
      reconP: (v) => {
        state.poolReconP = v;
      },
      reconC: (v) => {
        state.poolReconC = v;
      },
      probe: () => void refreshPool(),
      useSuggested: () => {
        const p = suggestedPool();
        if (!p) return;
        state.poolPaste = p;
        paint();
        void refreshPool();
      },
      fillHolder: () => {
        if (!state.poolPaste) return;
        state.draft = { ...state.draft, holder: state.poolPaste, p2p: false };
        state.holderIsPool = true;
        state.distinctController = true;
        clearConsentSigs();
        paint();
        void refreshPreflight();
      },
      deposit: () => void runPool("deposit"),
      authorize: () => void runPool("authorize"),
      unlock: () => void runPool("unlock"),
      reconcile: () => void runPool("reconcile"),
    },
  );
  renderRampView(
    el.ramp,
    {
      rampFlag: state.rampFlag,
      form: state.rampForm,
      quote: state.rampQuote,
      error: state.rampError,
    },
    {
      toggle: () => {
        state.rampFlag = !state.rampFlag;
        paint();
      },
      form: (f) => {
        state.rampForm = f;
      },
      quote: () => void runRampQuote(),
      send: () => void runRampSend(),
      pasteSet: () => pasteRampSet(),
    },
  );
  renderCatalogSpace(
    el.catalog,
    {
      paths: PATHS,
      flags: {
        core: true,
        packages: state.packages,
        labVerbs: state.labVerbs,
        zkArb: state.zkArb,
        pool: state.poolFlag,
        ramp: state.rampFlag,
      },
    },
    {
      start: (id) => startPath(id),
    },
  );
  renderRecintoHome(
    el.home,
    {
      chainId: state.chainId,
      escrow: state.escrowPaste,
      rpcUrl: state.rpcUrl,
      probe: state.probe,
      dealId: state.lookupDealId,
      signer: state.lookupSigner,
      nonce: state.lookupNonce,
      shortcuts: shortcutsFor(state.chainId, state.escrowPaste),
      loading: state.dealLoading,
    },
    {
      dealId: (value) => {
        state.lookupDealId = value;
      },
      signer: (value) => {
        state.lookupSigner = value;
      },
      nonce: (value) => {
        state.lookupNonce = value;
      },
      load: () => void loadDeal(),
      shortcut: (dealId) => {
        state.lookupDealId = dealId;
        state.lookupSigner = "";
        state.lookupNonce = "";
        paint();
        void loadDeal();
      },
    },
  );
  if (state.deal) {
    const sender = activeSender();
    const drift = driftForDeal();
    const matrix = matrixForDeal(state.deal, sender, {
      credit: state.credit,
      ruling: state.ruling,
      dualSign: toMatrixDraft(state.dualForm, {
        now: state.deal.blockTimestamp,
        usedP: state.dsUsedP,
        usedC: state.dsUsedC,
        provider: state.deal.terms.provider,
        controller: state.deal.terms.controller,
        recoveredP: state.recoveredP,
        recoveredC: state.recoveredC,
      }),
      driftZk: drift.some((r) => r.slot === "zk" && r.liveId !== null && !r.inSigned),
      driftArb: drift.some((r) => r.slot === "court" && r.liveId !== null && !r.inSigned),
      proof: state.labProof,
      courtPref: state.courtPref
        ? {
            kind: state.courtPref.kind,
            courtFee: state.courtPref.courtFee,
            allowance: state.courtPref.allowance,
            cost: state.courtPref.cost,
            msgValue: state.courtPref.kind === "kleros" ? state.courtPref.cost : 0n,
          }
        : null,
      contestPref: {
        fee: contestOpenDue(state.deal, state.dealPolicy),
        allowance: state.contestAllowance,
      },
    });
    const label = sender ? `${state.activeRole} ${sender}` : `${state.activeRole} desconectado`;
    renderDealView(
      el.deal,
      state.deal,
      state.bindings,
      matrix,
      label,
      {
        coreWrites: state.coreWrites,
        nonce: state.cancelNonce,
        writeError: state.writeError,
        dualSign: state.dualSign,
        dualForm: state.dualForm,
        digestP: dualDigests().p,
        digestC: dualDigests().c,
        sending: state.sending,
        zkArb: state.zkArb,
        drift,
      },
      {
        coreWrites: (on) => {
          state.coreWrites = on;
          paint();
        },
        zkArb: (on) => {
          state.zkArb = on;
          paint();
        },
        nonce: (value) => {
          state.cancelNonce = value;
        },
        send: (verb) => void sendVerb(verb),
        dualToggle: () => {
          state.dualSign = !state.dualSign;
          paint();
        },
        dualForm: (f) => {
          state.dualForm = f;
          state.recoveredP = null;
          state.recoveredC = null;
          paint();
        },
        signP: () => void signDual("P"),
        signC: () => void signDual("C"),
        relay: () => void relayDual(),
      },
    );
  } else renderDealEmpty(el.deal, state.dealError);
  renderAddressBook(el.book, sets, (set: AddressSet) => {
    if (!set.escrow || set.chainId === null) return;
    focusRecinto({
      chainId: set.chainId,
      escrow: set.escrow,
      sources: [set.sourceFile],
      testTokens: set.testToken ? [{ sourceFile: set.sourceFile, token: set.testToken }] : [],
    });
  });
}

function focusRecinto(row: RecintoRow): void {
  state.chainId = row.chainId;
  state.escrowPaste = row.escrow;
  state.rpcUrl = DEFAULT_RPC[row.chainId] ?? state.rpcUrl;
  state.probe = null;
  clearDeal();
  clearConsentSigs();
  state.modsDraft = emptyModsDraft();
  state.idsOverride = "";
  state.policy = emptyPolicy();
  paint();
  void refreshProbe();
  void refreshSlots();
}

function clearDeal(): void {
  state.deal = null;
  state.bindings = [];
  state.dealError = null;
  state.lookupDealId = "";
  state.credit = null;
  state.ruling = null;
  state.dualForm = emptyDualSign();
  state.recoveredP = null;
  state.recoveredC = null;
}

function activeSender(): HexAddress | null {
  const seat = state.seats.find((s) => s.role === state.activeRole);
  if (!seat?.address || !isAddress(seat.address)) return null;
  return getAddress(seat.address) as HexAddress;
}

function shortcutsFor(chainId: number, escrow: string): DealShortcut[] {
  if (!escrow || !isAddress(escrow)) return [];
  const want = getAddress(escrow);
  const out: DealShortcut[] = [];
  for (const set of sets) {
    if (set.chainId !== chainId || set.escrow !== want) continue;
    for (const [label, value] of Object.entries(set.labels)) {
      if (!/dealid$/i.test(label) && label !== "dealId") continue;
      if (!isHexBytes32(value)) continue;
      out.push({ sourceFile: set.sourceFile, label, dealId: value });
    }
  }
  return out;
}

async function loadDeal(): Promise<void> {
  if (!isAddress(state.escrowPaste)) {
    state.dealError = "escrow inválido";
    state.deal = null;
    paint();
    return;
  }
  state.dealLoading = true;
  state.dealError = null;
  paint();
  try {
    const escrow = getAddress(state.escrowPaste) as HexAddress;
    const dealId = await resolveDealId(state.rpcUrl, escrow, {
      dealId: state.lookupDealId,
      signer: state.lookupSigner,
      nonce: state.lookupNonce,
    });
    if (isEmptyDealId(dealId) || dealId === ZERO_BYTES32) {
      state.deal = null;
      state.dealError = "NONE: dealOf vacío o dealId 0x0. No hay Deal.";
      return;
    }
    const deal = await fetchDeal(state.rpcUrl, escrow, dealId);
    if (deal.status === 0 && deal.clocks.activatedAt === 0n) {
      state.deal = null;
      state.dealError = "NONE: IEscrow.status = 0. No hay Deal en este recinto.";
      state.bindings = [];
      return;
    }
    state.deal = deal;
    state.lookupDealId = deal.dealId;
    state.bindings = await fetchBindings(state.rpcUrl, escrow, deal.modules);
    state.dualForm = {
      ...emptyDualSign(deal.dealId),
      deadline: String(deal.blockTimestamp + 86_400n),
      type: state.dualForm.type,
    };
    state.recoveredP = null;
    state.recoveredC = null;
    await refreshExtras();
  } catch (err) {
    state.deal = null;
    state.bindings = [];
    state.dealError = err instanceof Error ? err.message : String(err);
  } finally {
    state.dealLoading = false;
    paint();
  }
}

async function refreshExtras(): Promise<void> {
  if (!state.deal || !isAddress(state.escrowPaste)) return;
  const escrow = getAddress(state.escrowPaste) as HexAddress;
  const sender = activeSender();
  try {
    state.credit = sender
      ? await fetchCredit(state.rpcUrl, escrow, state.deal.terms.token, sender)
      : null;
  } catch {
    state.credit = null;
  }
  if (!isZeroAddress(state.deal.modules.court)) {
    state.ruling = await fetchRuling(state.rpcUrl, state.deal.modules.court, state.deal.dealId);
    try {
      state.courtPref = await fetchCourtPref(
        state.rpcUrl,
        state.deal.modules.court,
        state.deal.terms.controller,
      );
    } catch {
      state.courtPref = null;
    }
  } else {
    state.ruling = null;
    state.courtPref = null;
  }
  try {
    state.dealPolicy = await probeSlots(
      state.rpcUrl,
      state.deal.modules,
      state.deal.terms.holder,
      state.deal.terms.provider,
    );
  } catch {
    state.dealPolicy = emptyPolicy();
  }
  if (state.deal && contestOpenDue(state.deal, state.dealPolicy) > 0n) {
    try {
      state.contestAllowance = await fetchAllowance(
        state.rpcUrl,
        state.deal.terms.token,
        state.deal.terms.controller,
        escrow,
      );
    } catch {
      state.contestAllowance = null;
    }
  } else {
    state.contestAllowance = null;
  }
  if (state.deal) {
    try {
      state.dsUsedP = await fetchUsed(
        state.rpcUrl,
        escrow,
        state.deal.terms.provider,
        BigInt(state.dualForm.nonceP || "0"),
      );
      state.dsUsedC = await fetchUsed(
        state.rpcUrl,
        escrow,
        state.deal.terms.controller,
        BigInt(state.dualForm.nonceC || "0"),
      );
    } catch {
      state.dsUsedP = false;
      state.dsUsedC = false;
    }
  }
  paint();
}

function dualDigests(): { p: string | null; c: string | null } {
  const f = state.dualForm;
  if (!f.type || !f.dealId || !f.deadline || f.deadline === "0" || !isAddress(state.escrowPaste)) {
    return { p: null, c: null };
  }
  const chainId = state.probe?.rpcChainId ?? state.chainId;
  const escrow = getAddress(state.escrowPaste) as HexAddress;
  const base = {
    dealId: f.dealId as Hex,
    deadline: BigInt(f.deadline),
    providerBps: f.type === "MutualSplit" ? Number(f.providerBps || "0") : undefined,
  };
  try {
    return {
      p: hashDualSign(f.type, chainId, escrow, { ...base, nonce: BigInt(f.nonceP || "0") }),
      c: hashDualSign(f.type, chainId, escrow, { ...base, nonce: BigInt(f.nonceC || "0") }),
    };
  } catch {
    return { p: null, c: null };
  }
}

async function signDual(who: "P" | "C"): Promise<void> {
  const f = state.dualForm;
  if (!f.type || !isAddress(state.escrowPaste)) {
    state.writeError = "elegí type y Recinto";
    paint();
    return;
  }
  const role = who === "P" ? "Provider" : "Controller";
  const pk = seatPk(role) ?? (role === "Controller" ? seatPk("Holder") : null);
  if (!pk) {
    state.writeError = `${role} sin pk`;
    paint();
    return;
  }
  const chainId = state.probe?.rpcChainId ?? state.chainId;
  const escrow = getAddress(state.escrowPaste) as HexAddress;
  const msg = {
    dealId: f.dealId as Hex,
    nonce: BigInt(who === "P" ? f.nonceP || "0" : f.nonceC || "0"),
    deadline: BigInt(f.deadline || "0"),
    providerBps: f.type === "MutualSplit" ? Number(f.providerBps || "0") : undefined,
  };
  try {
    const sig = await signDualSign(pk, chainId, escrow, f.type, msg);
    if (who === "P") state.dualForm = { ...state.dualForm, providerSig: sig };
    else state.dualForm = { ...state.dualForm, controllerSig: sig };
    const recovered =
      f.type === "MutualSplit"
        ? await recoverTypedDataAddress({
            domain: eip712Domain(chainId, escrow),
            types: dualSignTypes,
            primaryType: "MutualSplit",
            message: {
              dealId: msg.dealId,
              providerBps: msg.providerBps ?? 0,
              nonce: msg.nonce,
              deadline: msg.deadline,
            },
            signature: sig,
          })
        : await recoverTypedDataAddress({
            domain: eip712Domain(chainId, escrow),
            types: dualSignTypes,
            primaryType: f.type,
            message: { dealId: msg.dealId, nonce: msg.nonce, deadline: msg.deadline },
            signature: sig,
          });
    if (who === "P") state.recoveredP = recovered;
    else state.recoveredC = recovered;
    state.writeError = null;
  } catch (err) {
    state.writeError = err instanceof Error ? err.message : String(err);
  }
  paint();
}

async function relayDual(): Promise<void> {
  const f = state.dualForm;
  if (!state.dualSign || !f.type || !isDraftComplete(f) || !state.deal || !isAddress(state.escrowPaste)) {
    state.writeError = "draft dual-sign incompleto o dualSign off";
    paint();
    return;
  }
  const pk = seatPk("Relayer") ?? seatPk("Holder");
  if (!pk) {
    state.writeError = "Relayer/Holder sin pk";
    paint();
    return;
  }
  try {
    await sendDualSign({
      rpcUrl: state.rpcUrl,
      chainId: state.probe?.rpcChainId ?? state.chainId,
      escrow: getAddress(state.escrowPaste) as HexAddress,
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
    await loadDeal();
  } catch (err) {
    state.writeError = err instanceof Error ? err.message : String(err);
    paint();
  }
}

async function refreshProbe(): Promise<void> {
  if (!state.escrowPaste) return;
  state.probing = true;
  paint();
  state.probe = await probeRecinto(state.rpcUrl, state.escrowPaste);
  state.probing = false;
  paint();
}

function suggestedToken(): string | null {
  if (!isAddress(state.escrowPaste)) return null;
  const want = getAddress(state.escrowPaste);
  for (const set of sets) {
    if (set.chainId === state.chainId && set.escrow === want && set.testToken) return set.testToken;
  }
  return null;
}

function currentPackageIds() {
  if (!state.packages) return [];
  try {
    const override = parseIdOverride(state.idsOverride);
    if (override) return override;
  } catch {
    return [];
  }
  return computedIds(parseModsDraft(state.modsDraft), state.policy);
}

function startPath(id: string): void {
  const p = pathById(id);
  if (!p) return;
  state.draft = {
    ...state.draft,
    p2p: p.p2p,
    fiatDuration: p.fiatDuration,
    releaseDuration: p.releaseDuration,
    disputeDuration: p.disputeDuration,
    arbitrationDuration: p.arbitrationDuration,
  };
  if (p.p2p) state.draft.controller = state.draft.holder;
  if (id === "CASE-CORE-01-CTRL" || id === "PATH-POOL-HOLDER") {
    state.distinctController = true;
    state.draft.p2p = false;
  }
  if (id === "PATH-POOL-HOLDER") state.holderIsPool = true;
  if (id === "PATH-RAMP-TAXI") {
    const usdc = rampSetField("usdc");
    if (usdc) state.draft = { ...state.draft, token: usdc };
  }
  clearConsentSigs();
  paint();
  void refreshPreflight();
}

function rampSetField(key: string): string | null {
  for (const set of sets) {
    if (set.chainId === state.chainId && set.labels[key]) return set.labels[key] ?? null;
    if (set.sourceFile.includes("ramp") && set.labels[key]) return set.labels[key] ?? null;
  }
  return null;
}

function pasteRampSet(): void {
  state.rampForm = {
    ...state.rampForm,
    ramp: rampSetField("ramp") ?? state.rampForm.ramp,
    token: rampSetField("usdc") ?? state.rampForm.token,
    dest: rampSetField("destEid") ?? state.rampForm.dest,
  };
  paint();
}

async function runRampQuote(): Promise<void> {
  const f = state.rampForm;
  if (!state.rampFlag) {
    state.rampError = "ramp off";
    paint();
    return;
  }
  if (!isAddress(f.ramp) || !isAddress(f.token) || !isAddress(f.to)) {
    state.rampError = "ramp, token y to";
    paint();
    return;
  }
  try {
    const q = await rampQuote(state.rpcUrl, getAddress(f.ramp) as HexAddress, {
      token: getAddress(f.token) as HexAddress,
      amount: BigInt(f.amount || "0"),
      minAmountOut: BigInt(f.minAmountOut || "0"),
      dest: Number(f.dest || "0"),
      to: getAddress(f.to) as HexAddress,
      refund: isAddress(f.refund) ? (getAddress(f.refund) as HexAddress) : (getAddress(f.to) as HexAddress),
    });
    state.rampQuote = { nativeFee: String(q.nativeFee), amountOut: String(q.amountOut) };
    state.rampError = null;
  } catch (err) {
    state.rampError = err instanceof Error ? err.message : String(err);
  }
  paint();
}

async function runRampSend(): Promise<void> {
  const f = state.rampForm;
  const pk = seatPk(state.activeRole) ?? seatPk("Holder");
  if (!state.rampFlag || !pk || !isAddress(f.ramp) || !isAddress(f.token) || !isAddress(f.to)) {
    state.rampError = "ramp flag, pk, ramp, token, to";
    paint();
    return;
  }
  try {
    const intent = {
      token: getAddress(f.token) as HexAddress,
      amount: BigInt(f.amount || "0"),
      minAmountOut: BigInt(f.minAmountOut || "0"),
      dest: Number(f.dest || "0"),
      to: getAddress(f.to) as HexAddress,
      refund: isAddress(f.refund) ? (getAddress(f.refund) as HexAddress) : (getAddress(f.to) as HexAddress),
    };
    const value = state.rampQuote ? BigInt(state.rampQuote.nativeFee) : 0n;
    await rampSend({
      rpcUrl: state.rpcUrl,
      chainId: state.probe?.rpcChainId ?? state.chainId,
      ramp: getAddress(f.ramp) as HexAddress,
      pk,
      intent,
      value,
    });
    state.rampError = null;
  } catch (err) {
    state.rampError = err instanceof Error ? err.message : String(err);
  }
  paint();
}

function suggestedPool(): string | null {
  if (!isAddress(state.escrowPaste)) return null;
  const want = getAddress(state.escrowPaste);
  for (const set of sets) {
    if (set.chainId === state.chainId && set.escrow === want && set.labels.pool) return set.labels.pool;
  }
  return null;
}

async function refreshPool(): Promise<void> {
  if (!isAddress(state.poolPaste)) {
    state.poolError = "pool inválido";
    paint();
    return;
  }
  try {
    const agent = activeSender();
    state.poolSnap = await probePool(state.rpcUrl, getAddress(state.poolPaste) as HexAddress, agent);
    state.poolError = null;
  } catch (err) {
    state.poolSnap = null;
    state.poolError = err instanceof Error ? err.message : String(err);
  }
  paint();
}

async function runPool(kind: "deposit" | "authorize" | "unlock" | "reconcile"): Promise<void> {
  if (!state.poolFlag) {
    state.poolError = "pool off";
    paint();
    return;
  }
  const pk = seatPk(state.activeRole) ?? seatPk("Controller") ?? seatPk("Holder");
  if (!pk || !isAddress(state.poolPaste)) {
    state.poolError = "pk y pool";
    paint();
    return;
  }
  const common = {
    rpcUrl: state.rpcUrl,
    chainId: state.probe?.rpcChainId ?? state.chainId,
    pool: getAddress(state.poolPaste) as HexAddress,
    pk,
  };
  try {
    if (kind === "deposit") {
      await poolDeposit({ ...common, amount: BigInt(state.poolDepositAmt || "0") });
    } else if (kind === "authorize") {
      const parsed = tryParsed();
      if (!parsed) throw new Error("DealTerms inválidos");
      // `Pool.authorize` runs the kernel's own `Packages.resolve`, so it needs the same slots the activation
      // will. `currentPackageIds()` returns [] whenever packages are off and `parseModsDraft` on an empty
      // draft yields all-zero slots, so the signed ids and the mods cannot disagree on this path.
      const mods = parseModsDraft(state.packages ? state.modsDraft : emptyModsDraft());
      await poolAuthorize({ ...common, ha: parsed.ha, mods });
    } else if (kind === "unlock") {
      await poolUnlock({ ...common, nonce: BigInt(state.poolUnlockNonce || "0") });
    } else {
      await poolReconcile({
        ...common,
        nonce: BigInt(state.poolUnlockNonce || "0"),
        providerNonce: BigInt(state.poolReconP || "0"),
        controllerNonce: BigInt(state.poolReconC || "0"),
      });
    }
    state.poolError = null;
    await refreshPool();
  } catch (err) {
    state.poolError = err instanceof Error ? err.message : String(err);
    paint();
  }
}

function suggestedMods(): ModsDraft | null {
  if (!isAddress(state.escrowPaste)) return null;
  const want = getAddress(state.escrowPaste);
  for (const set of sets) {
    if (set.chainId !== state.chainId || set.escrow !== want) continue;
    const passport = set.labels.passport ?? "";
    const reputation = set.labels.reputation ?? "";
    const bonds = set.labels.bondVault ?? set.labels.bonds ?? "";
    const zk = set.labels.zk ?? "";
    const court = set.labels.arbitration ?? set.labels.court ?? "";
    if (!passport && !reputation && !bonds && !zk && !court) continue;
    return { passport, reputation, bonds, zk, court };
  }
  return null;
}

function tryParsed() {
  try {
    return parseDraft(state.draft, currentPackageIds());
  } catch {
    return null;
  }
}

function clearConsentSigs(): void {
  state.holderSig = null;
  state.providerSig = null;
  state.controllerSig = null;
  state.preflight = [];
  state.projectedDealId = null;
  state.sendError = null;
}

async function refreshSlots(): Promise<void> {
  const mods = parseModsDraft(state.modsDraft);
  const parsed = tryParsed();
  try {
    state.policy = await probeSlots(
      state.rpcUrl,
      mods,
      parsed?.terms.holder ?? null,
      parsed?.terms.provider ?? null,
    );
  } catch {
    state.policy = emptyPolicy();
  }
  await refreshPreflight();
}

function seatPk(role: Role): string | null {
  return state.seats.find((s) => s.role === role)?.pk ?? null;
}

async function refreshPreflight(): Promise<void> {
  const parsed = tryParsed();
  if (!parsed || !isAddress(state.escrowPaste)) {
    state.preflight = [];
    state.projectedDealId = null;
    paint();
    return;
  }
  const escrow = getAddress(state.escrowPaste) as HexAddress;
  const chainId = state.probe?.rpcChainId ?? state.chainId;
  const now = state.probe ? BigInt(Math.floor(Date.now() / 1000)) : BigInt(Math.floor(Date.now() / 1000));
  let usedHolder = false;
  let usedProvider = false;
  let usedController = false;
  let allowance: bigint | null = null;
  let dealStatus: number | null = null;
  let domain = state.probe?.domainSeparator ?? null;
  try {
    usedHolder = await fetchUsed(state.rpcUrl, escrow, parsed.terms.holder, parsed.ha.nonce);
    usedProvider = await fetchUsed(state.rpcUrl, escrow, parsed.terms.provider, parsed.pa.nonce);
    usedController = await fetchUsed(
      state.rpcUrl,
      escrow,
      parsed.terms.controller,
      parsed.ca.nonce,
    );
  } catch {
    /* offline */
  }
  try {
    allowance = await fetchAllowance(state.rpcUrl, parsed.terms.token, parsed.terms.holder, escrow);
  } catch {
    allowance = null;
  }
  if (domain) {
    const id = computeDealId(
      domain,
      parsed.terms,
      parsed.ha.nonce,
      parsed.pa.nonce,
      parsed.ca.nonce,
    );
    state.projectedDealId = id;
    try {
      dealStatus = await fetchStatus(state.rpcUrl, escrow, id);
    } catch {
      dealStatus = null;
    }
  }
  state.preflight = await preflightActivateCore({
    terms: parsed.terms,
    ha: parsed.ha,
    pa: parsed.pa,
    ca: parsed.ca,
    holderSig: state.holderSig,
    providerSig: state.providerSig,
    controllerSig: state.controllerSig,
    chainId,
    escrow,
    now,
    usedHolder,
    usedProvider,
    usedController,
    allowance,
    dealStatus,
    coreActivate: state.coreActivate,
    distinctController: state.distinctController,
    packages: state.packages,
    mods: parseModsDraft(state.modsDraft),
    policy: state.policy,
    holderIsPool: state.holderIsPool,
  });
  paint();
}

function encodeLabProof(): void {
  const f = state.labForm;
  const dealId = f.dealId || state.lookupDealId || state.deal?.dealId || "";
  if (!isHexBytes32(dealId) || !isHexBytes32(f.nullifier)) {
    state.labError = "dealId y nullifier bytes32";
    paint();
    return;
  }
  state.labProof = encodeMockProof(dealId, f.nullifier);
  state.labError = null;
  paint();
}

async function runLab(kind: "setHuman" | "submitRuling" | "mint" | "approve" | "deposit" | "warp"): Promise<void> {
  if (!state.labVerbs) {
    state.labError = "labVerbs off";
    paint();
    return;
  }
  const pk = seatPk(state.activeRole) ?? seatPk("Holder") ?? seatPk("Relayer");
  const chainId = state.probe?.rpcChainId ?? state.chainId;
  const f = state.labForm;
  try {
    if (kind === "warp") {
      if (chainId !== 31337) throw new Error("reloj LAB solo en Anvil 31337");
      await anvilIncreaseTime(state.rpcUrl, Number(f.warp || "0"));
      if (state.deal) await loadDeal();
      else paint();
      return;
    }
    if (!pk) throw new Error("asiento activo sin pk");
    const common = { rpcUrl: state.rpcUrl, chainId, pk };
    if (kind === "setHuman") {
      if (!isAddress(state.modsDraft.passport) || !isAddress(f.wallet) || !isHexBytes32(f.subject)) {
        throw new Error("passport, wallet y subject bytes32");
      }
      await labSetHuman({
        ...common,
        passport: getAddress(state.modsDraft.passport) as HexAddress,
        wallet: getAddress(f.wallet) as HexAddress,
        subject: f.subject,
      });
    } else if (kind === "submitRuling") {
      if (!isAddress(state.modsDraft.court) || !isHexBytes32(f.dealId || state.deal?.dealId || "")) {
        throw new Error("court y dealId");
      }
      await labSubmitRuling({
        ...common,
        court: getAddress(state.modsDraft.court) as HexAddress,
        dealId: (f.dealId || state.deal!.dealId) as HexBytes32,
        ruling: Number(f.ruling || "0"),
      });
      if (state.deal) await loadDeal();
    } else if (kind === "mint") {
      if (!isAddress(state.draft.token) || !isAddress(f.mintTo)) throw new Error("token y mint to");
      await labMint({
        ...common,
        token: getAddress(state.draft.token) as HexAddress,
        to: getAddress(f.mintTo) as HexAddress,
        amount: BigInt(f.mintAmount || "0"),
      });
    } else if (kind === "approve") {
      if (!isAddress(state.draft.token) || !isAddress(f.approveSpender)) throw new Error("token y spender");
      await labApprove({
        ...common,
        token: getAddress(state.draft.token) as HexAddress,
        spender: getAddress(f.approveSpender) as HexAddress,
        amount: BigInt(f.approveAmount || "0"),
      });
    } else if (kind === "deposit") {
      if (!isAddress(f.vault) || !isHexBytes32(f.subject) || !isAddress(state.draft.token)) {
        throw new Error("vault, subject y token");
      }
      await labDeposit({
        ...common,
        vault: getAddress(f.vault) as HexAddress,
        subject: f.subject,
        token: getAddress(state.draft.token) as HexAddress,
        amount: BigInt(f.depositAmount || "0"),
      });
    }
    state.labError = null;
  } catch (err) {
    state.labError = err instanceof Error ? err.message : String(err);
  }
  paint();
}

async function signHa(): Promise<void> {
  const parsed = tryParsed();
  const pk = seatPk("Holder");
  if (!parsed || !pk || !isAddress(state.escrowPaste)) {
    state.sendError = "Holder pk y DealTerms válidos";
    paint();
    return;
  }
  const chainId = state.probe?.rpcChainId ?? state.chainId;
  try {
    state.holderSig = await signHolderAuthorization(
      pk,
      chainId,
      getAddress(state.escrowPaste) as HexAddress,
      parsed.ha,
    );
    state.sendError = null;
  } catch (err) {
    state.sendError = err instanceof Error ? err.message : String(err);
  }
  paint();
  void refreshPreflight();
}

async function signPa(): Promise<void> {
  const parsed = tryParsed();
  const pk = seatPk("Provider");
  if (!parsed || !pk || !isAddress(state.escrowPaste)) {
    state.sendError = "Provider pk y DealTerms válidos";
    paint();
    return;
  }
  const chainId = state.probe?.rpcChainId ?? state.chainId;
  try {
    state.providerSig = await signProviderAgreement(
      pk,
      chainId,
      getAddress(state.escrowPaste) as HexAddress,
      parsed.pa,
    );
    state.sendError = null;
  } catch (err) {
    state.sendError = err instanceof Error ? err.message : String(err);
  }
  paint();
  void refreshPreflight();
}

async function signCa(): Promise<void> {
  const parsed = tryParsed();
  const pk = seatPk("Controller");
  if (!parsed || !pk || !isAddress(state.escrowPaste)) {
    state.sendError = "Controller pk y DealTerms válidos";
    paint();
    return;
  }
  if (parsed.terms.holder.toLowerCase() === parsed.terms.controller.toLowerCase()) {
    state.sendError = "P2P: CA dummy, no se firma";
    paint();
    return;
  }
  const chainId = state.probe?.rpcChainId ?? state.chainId;
  try {
    state.controllerSig = await signControllerAcceptance(
      pk,
      chainId,
      getAddress(state.escrowPaste) as HexAddress,
      parsed.ca,
    );
    state.sendError = null;
  } catch (err) {
    state.sendError = err instanceof Error ? err.message : String(err);
  }
  paint();
  void refreshPreflight();
}

function driftForDeal(): DriftRow[] {
  if (!state.deal) return [];
  return slotRows(state.deal.modules, state.deal.terms.packageIds, state.dealPolicy, state.escrowPaste)
    .filter((r) => r.address)
    .map((r) => ({ slot: r.slot, liveId: r.id, inSigned: r.inIds === true }));
}

async function sendVerb(verb: string): Promise<void> {
  if (verb === "mutualCancel" || verb === "coSignedRelease" || verb === "mutualSplit") {
    await relayDual();
    return;
  }
  if (isZkArb(verb)) {
    if (!state.zkArb || !state.deal || !isAddress(state.escrowPaste)) return;
    const pk = seatPk(state.activeRole) ?? seatPk("Relayer") ?? seatPk("Holder");
    if (!pk) {
      state.writeError = `asiento ${state.activeRole} sin pk`;
      paint();
      return;
    }
    try {
      await sendZkArb({
        rpcUrl: state.rpcUrl,
        chainId: state.probe?.rpcChainId ?? state.chainId,
        escrow: getAddress(state.escrowPaste) as HexAddress,
        pk,
        verb,
        dealId: state.deal.dealId,
        proof: (state.labProof as Hex | null) ?? "0x",
        value: state.courtPref?.kind === "kleros" ? (state.courtPref.cost ?? 0n) : 0n,
      });
      await loadDeal();
    } catch (err) {
      state.writeError = err instanceof Error ? err.message : String(err);
      paint();
    }
    return;
  }
  if (!isCoreWrite(verb) || !state.deal || !isAddress(state.escrowPaste)) return;
  const pk = seatPk(state.activeRole);
  if (!pk) {
    state.writeError = `asiento ${state.activeRole} sin pk`;
    paint();
    return;
  }
  if (!state.coreWrites) {
    state.writeError = "coreWrites off";
    paint();
    return;
  }
  state.writeError = null;
  try {
    await sendCoreWrite({
      rpcUrl: state.rpcUrl,
      chainId: state.probe?.rpcChainId ?? state.chainId,
      escrow: getAddress(state.escrowPaste) as HexAddress,
      pk,
      verb,
      dealId: state.deal.dealId,
      token: state.deal.terms.token,
      nonce: BigInt(state.cancelNonce || "0"),
    });
    await loadDeal();
  } catch (err) {
    state.writeError = err instanceof Error ? err.message : String(err);
    paint();
  }
}

async function sendActivate(): Promise<void> {
  const parsed = tryParsed();
  const relayerPk = seatPk("Relayer") ?? seatPk("Holder");
  const p2p =
    parsed !== null && parsed.terms.holder.toLowerCase() === parsed.terms.controller.toLowerCase();
  const holderSig = state.holderIsPool ? ("0x" as Hex) : state.holderSig;
  if (
    !parsed ||
    !holderSig ||
    !state.providerSig ||
    (!p2p && !state.controllerSig) ||
    !relayerPk ||
    !isAddress(state.escrowPaste)
  ) {
    state.sendError = "faltan firmas, Relayer/Holder pk o escrow";
    paint();
    return;
  }
  if (state.probe?.rpcChainId !== null && state.probe?.rpcChainId !== state.chainId) {
    state.sendError = "RPC chainId ≠ Recinto. Firmar/enviar bloqueado.";
    paint();
    return;
  }
  const last = state.preflight[state.preflight.length - 1];
  if (!last?.eval.enabled) {
    state.sendError = "preflight no ok";
    paint();
    return;
  }
  state.sending = true;
  state.sendError = null;
  paint();
  try {
    const escrow = getAddress(state.escrowPaste) as HexAddress;
    const chainId = state.probe?.rpcChainId ?? state.chainId;
    const packed = parseModsDraft(state.modsDraft);
    const use7 = state.packages && !modsEmpty(packed);
    const common = {
      rpcUrl: state.rpcUrl,
      chainId,
      escrow,
      relayerPk: (relayerPk.startsWith("0x") ? relayerPk : `0x${relayerPk}`) as Hex,
      ha: parsed.ha,
      holderSig,
      pa: parsed.pa,
      providerSig: state.providerSig,
      ca: p2p ? null : parsed.ca,
      controllerSig: p2p ? null : state.controllerSig,
    };
    if (use7) await sendActivate7({ ...common, mods: packed });
    else await sendActivate6(common);
    if (state.probe?.domainSeparator) {
      state.lookupDealId = computeDealId(
        state.probe.domainSeparator,
        parsed.terms,
        parsed.ha.nonce,
        parsed.pa.nonce,
        parsed.ca.nonce,
      );
      await loadDeal();
    }
  } catch (err) {
    state.sendError = err instanceof Error ? err.message : String(err);
  } finally {
    state.sending = false;
    paint();
  }
}

function contestOpenDue(deal: DealSnapshot | null, policy: LivePolicy): bigint {
  const r = policy.reputation;
  if (!deal || !r || r.contestBps == null || r.contestFloor == null) return 0n;
  return contestDue(deal.terms.principal, r.contestBps, r.contestFloor);
}

paint();
if (state.escrowPaste) void refreshProbe();
{
  const tok = suggestedToken();
  if (tok && !state.draft.token) state.draft = { ...state.draft, token: tok };
}
