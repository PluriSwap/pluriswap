import { getAddress, isAddress } from "viem";
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
import { renderRecintoHome, type DealShortcut } from "./chrome/RecintoHome.ts";
import { renderRecintoSelector } from "./chrome/RecintoSelector.ts";
import { renderRoleStrip } from "./chrome/RoleStrip.ts";
import { renderDealEmpty, renderDealView } from "./deal/DealView.ts";
import { fetchBindings, fetchDeal, isEmptyDealId, resolveDealId } from "./deal/fetch.ts";
import { ZERO_BYTES32, isHexBytes32, type DealSnapshot, type ModuleBinding } from "./deal/types.ts";
import { probeRecinto, type RecintoProbe } from "./recinto/probe.ts";
import "./style.css";

const sets = loadBundledSets();
const recintos = recintosFromSets(sets);

const first = recintos.find((r) => r.chainId === 421614) ?? recintos[0];

const state = {
  chainId: first?.chainId ?? 421614,
  rpcUrl: DEFAULT_RPC[first?.chainId ?? 421614] ?? "",
  escrowPaste: (first?.escrow ?? "") as string,
  seats: ROLES.map((role): SeatState => ({ role, address: null })),
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
};

const el = {
  selector: document.querySelector<HTMLElement>("#recinto-selector")!,
  roles: document.querySelector<HTMLElement>("#role-strip")!,
  home: document.querySelector<HTMLElement>("#recinto-home")!,
  deal: document.querySelector<HTMLElement>("#deal-view")!,
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
        paint();
      },
      rpcUrl: (url) => {
        state.rpcUrl = url;
        paint();
      },
      escrow: (value) => {
        state.escrowPaste = value;
        state.probe = null;
        clearDeal();
        paint();
      },
      pick: (row) => focusRecinto(row),
      probe: () => void refreshProbe(),
    },
  );
  renderRoleStrip(el.roles, state.seats, state.activeRole, {
    active: (role) => {
      state.activeRole = role;
      paint();
    },
    address: (role, value) => {
      const seat = state.seats.find((s) => s.role === role);
      if (!seat) return;
      seat.address = !value ? null : isAddress(value) ? getAddress(value) : value;
      paint();
    },
  });
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
  if (state.deal) renderDealView(el.deal, state.deal, state.bindings);
  else renderDealEmpty(el.deal, state.dealError);
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
  paint();
  void refreshProbe();
}

function clearDeal(): void {
  state.deal = null;
  state.bindings = [];
  state.dealError = null;
  state.lookupDealId = "";
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
  } catch (err) {
    state.deal = null;
    state.bindings = [];
    state.dealError = err instanceof Error ? err.message : String(err);
  } finally {
    state.dealLoading = false;
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

paint();
if (state.escrowPaste) void refreshProbe();
