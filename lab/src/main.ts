import { getAddress, isAddress } from "viem";
import { loadBundledSets, recintosFromSets } from "./addressbook/load.ts";
import {
  DEFAULT_RPC,
  ROLES,
  type RecintoRow,
  type Role,
  type SeatState,
} from "./addressbook/types.ts";
import { renderAddressBook } from "./chrome/AddressBookDrawer.ts";
import { renderRecintoHome } from "./chrome/RecintoHome.ts";
import { renderRecintoSelector } from "./chrome/RecintoSelector.ts";
import { renderRoleStrip } from "./chrome/RoleStrip.ts";
import { probeRecinto, type RecintoProbe } from "./recinto/probe.ts";
import type { AddressSet } from "./addressbook/types.ts";
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
};

const el = {
  selector: document.querySelector<HTMLElement>("#recinto-selector")!,
  roles: document.querySelector<HTMLElement>("#role-strip")!,
  home: document.querySelector<HTMLElement>("#recinto-home")!,
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
        paint();
      },
      rpcUrl: (url) => {
        state.rpcUrl = url;
        paint();
      },
      escrow: (value) => {
        state.escrowPaste = value;
        state.probe = null;
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
  renderRecintoHome(el.home, {
    chainId: state.chainId,
    escrow: state.escrowPaste,
    rpcUrl: state.rpcUrl,
    probe: state.probe,
  });
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
  paint();
  void refreshProbe();
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
