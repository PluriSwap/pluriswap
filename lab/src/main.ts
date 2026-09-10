import { getAddress, isAddress, type Hex } from "viem";
import { loadBundledSets, recintosFromSets } from "./addressbook/load.ts";
import {
  DEFAULT_RPC,
  ROLES,
  type AddressSet,
  type HexAddress,
  type RecintoRow,
  type Role,
  type SeatState,
} from "./addressbook/types.ts";
import { renderAddressBook } from "./chrome/AddressBookDrawer.ts";
import { renderConsentPanel, defaultDraft, type ConsentDraft } from "./consent/ConsentPanel.ts";
import { computeDealId } from "./consent/eip712.ts";
import { parseDraft } from "./consent/parse.ts";
import { preflightActivateCore, type PreflightStep } from "./consent/preflight.ts";
import { accountFromPk, signHolderAuthorization, signProviderAgreement } from "./consent/sign.ts";
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
import { probeRecinto, type RecintoProbe } from "./recinto/probe.ts";
import { sendActivate6 } from "./verbs/activateCore.ts";
import { isCoreWrite, sendCoreWrite } from "./verbs/coreWrites.ts";
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
  draft: defaultDraft("") as ConsentDraft,
  holderSig: null as Hex | null,
  providerSig: null as Hex | null,
  preflight: [] as PreflightStep[],
  projectedDealId: null as string | null,
  sending: false,
  sendError: null as string | null,
  coreWrites: true,
  cancelNonce: "1",
  writeError: null as string | null,
};

const el = {
  selector: document.querySelector<HTMLElement>("#recinto-selector")!,
  roles: document.querySelector<HTMLElement>("#role-strip")!,
  home: document.querySelector<HTMLElement>("#recinto-home")!,
  deal: document.querySelector<HTMLElement>("#deal-view")!,
  consent: document.querySelector<HTMLElement>("#consent")!,
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
      steps: state.preflight,
      holderSig: state.holderSig,
      providerSig: state.providerSig,
      ha: tryParsed()?.ha ?? null,
      pa: tryParsed()?.pa ?? null,
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
        state.sendError = null;
        paint();
        void refreshPreflight();
      },
      toggleFlag: () => {
        state.coreActivate = !state.coreActivate;
        paint();
        void refreshPreflight();
      },
      fillSeats: () => {
        const h = state.seats.find((s) => s.role === "Holder")?.address ?? "";
        const p = state.seats.find((s) => s.role === "Provider")?.address ?? "";
        state.draft = {
          ...state.draft,
          holder: h,
          provider: p,
          controller: state.draft.p2p ? h : state.draft.controller,
        };
        state.holderSig = null;
        state.providerSig = null;
        paint();
        void refreshPreflight();
      },
      useToken: () => {
        const tok = suggestedToken();
        if (!tok) return;
        state.draft = { ...state.draft, token: tok };
        state.holderSig = null;
        state.providerSig = null;
        paint();
        void refreshPreflight();
      },
      signHa: () => void signHa(),
      signPa: () => void signPa(),
      send: () => void sendActivate(),
      refresh: () => void refreshPreflight(),
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
    const matrix = matrixForDeal(state.deal, sender, {
      credit: state.credit,
      ruling: state.ruling,
      dualSign: null,
    });
    const label = sender ? `${state.activeRole} ${sender}` : `${state.activeRole} desconectado`;
    renderDealView(
      el.deal,
      state.deal,
      state.bindings,
      matrix,
      label,
      { coreWrites: state.coreWrites, nonce: state.cancelNonce, writeError: state.writeError },
      {
        coreWrites: (on) => {
          state.coreWrites = on;
          paint();
        },
        nonce: (value) => {
          state.cancelNonce = value;
        },
        send: (verb) => void sendVerb(verb),
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
  paint();
  void refreshProbe();
  void refreshPreflight();
}

function clearDeal(): void {
  state.deal = null;
  state.bindings = [];
  state.dealError = null;
  state.lookupDealId = "";
  state.credit = null;
  state.ruling = null;
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
  } else {
    state.ruling = null;
  }
  paint();
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

function tryParsed() {
  try {
    return parseDraft(state.draft);
  } catch {
    return null;
  }
}

function clearConsentSigs(): void {
  state.holderSig = null;
  state.providerSig = null;
  state.preflight = [];
  state.projectedDealId = null;
  state.sendError = null;
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
  let allowance: bigint | null = null;
  let dealStatus: number | null = null;
  let domain = state.probe?.domainSeparator ?? null;
  try {
    usedHolder = await fetchUsed(state.rpcUrl, escrow, parsed.terms.holder, parsed.ha.nonce);
    usedProvider = await fetchUsed(state.rpcUrl, escrow, parsed.terms.provider, parsed.pa.nonce);
  } catch {
    /* offline */
  }
  try {
    allowance = await fetchAllowance(state.rpcUrl, parsed.terms.token, parsed.terms.holder, escrow);
  } catch {
    allowance = null;
  }
  if (domain) {
    const id = computeDealId(domain, parsed.terms, parsed.ha.nonce, parsed.pa.nonce, 0n);
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
    holderSig: state.holderSig,
    providerSig: state.providerSig,
    chainId,
    escrow,
    now,
    usedHolder,
    usedProvider,
    allowance,
    dealStatus,
    coreActivate: state.coreActivate,
  });
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

async function sendVerb(verb: string): Promise<void> {
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
  if (!parsed || !state.holderSig || !state.providerSig || !relayerPk || !isAddress(state.escrowPaste)) {
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
    await sendActivate6({
      rpcUrl: state.rpcUrl,
      chainId,
      escrow,
      relayerPk: (relayerPk.startsWith("0x") ? relayerPk : `0x${relayerPk}`) as Hex,
      ha: parsed.ha,
      holderSig: state.holderSig,
      pa: parsed.pa,
      providerSig: state.providerSig,
    });
    if (state.probe?.domainSeparator) {
      state.lookupDealId = computeDealId(
        state.probe.domainSeparator,
        parsed.terms,
        parsed.ha.nonce,
        parsed.pa.nonce,
        0n,
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

paint();
if (state.escrowPaste) void refreshProbe();
{
  const tok = suggestedToken();
  if (tok && !state.draft.token) state.draft = { ...state.draft, token: tok };
}
