import { useEffect } from "preact/hooks";
import type { SpaceId } from "../catalog/paths.ts";
import { AddressBookDrawer } from "../chrome/AddressBookDrawer.tsx";
import { PathTray, SPACE_NAME } from "../chrome/PathTray.tsx";
import { RecintoBar } from "../chrome/RecintoBar.tsx";
import { SeatStrip } from "../chrome/SeatStrip.tsx";
import { CatalogSpace } from "../spaces/CatalogSpace.tsx";
import { ConsentSpace } from "../spaces/ConsentSpace.tsx";
import { CreditsSpace } from "../spaces/CreditsSpace.tsx";
import { DealSpace } from "../spaces/DealSpace.tsx";
import { GuideSpace } from "../spaces/GuideSpace.tsx";
import { LabSpace } from "../spaces/LabSpace.tsx";
import { PackagesSpace } from "../spaces/PackagesSpace.tsx";
import { PoolSpace } from "../spaces/PoolSpace.tsx";
import { RampSpace } from "../spaces/RampSpace.tsx";
import { RecintoSpace } from "../spaces/RecintoSpace.tsx";
import { Badge } from "../ui/atoms.tsx";
import { refreshHead, refreshProbe } from "./actions.ts";
import * as S from "./store.ts";

const NAV: { id: SpaceId; kind?: "lab" | "pool" }[] = [
  { id: "guide" },
  { id: "recinto" },
  { id: "catalog" },
  { id: "consent" },
  { id: "packages" },
  { id: "deal" },
  { id: "credits" },
  { id: "pool", kind: "pool" },
  { id: "ramp" },
  { id: "lab", kind: "lab" },
];

const SPACES: Record<SpaceId, () => preact.JSX.Element> = {
  guide: GuideSpace,
  recinto: RecintoSpace,
  deal: DealSpace,
  consent: ConsentSpace,
  packages: PackagesSpace,
  pool: PoolSpace,
  credits: CreditsSpace,
  catalog: CatalogSpace,
  lab: LabSpace,
  ramp: RampSpace,
};

export function App() {
  useEffect(() => {
    void refreshProbe();
    const t = setInterval(() => void refreshHead(), 15_000);
    return () => clearInterval(t);
  }, []);
  const Space = SPACES[S.space.value];
  const d = S.deal.value;
  return (
    <div class={`app${S.bookOpen.value ? " book-open" : ""}`}>
      <RecintoBar />
      <SeatStrip />
      <PathTray />
      <div class="body">
        <nav class="nav">
          {NAV.map((n) => (
            <button
              type="button"
              key={n.id}
              class={`nav-item${S.space.value === n.id ? " is-on" : ""}${n.kind ? ` nav-${n.kind}` : ""}`}
              onClick={() => (S.space.value = n.id)}
            >
              {SPACE_NAME[n.id]}
              {n.id === "deal" && d && <Badge tone="info">{statusShort(d.status)}</Badge>}
              {n.id === "lab" && <Badge tone="lab">LAB</Badge>}
            </button>
          ))}
          <div class="nav-foot">
            <span class="muted">txs de sesión: {S.txLog.value.length}</span>
          </div>
        </nav>
        <main class="space">
          <Space />
        </main>
        <AddressBookDrawer />
      </div>
    </div>
  );
}

function statusShort(s: number): string {
  return ["NONE", "FUNDED", "FIAT_SENT", "DISPUTED", "RELEASED", "SPLIT", "STALEMATE", "CANCELLED", "ARB", "ARB_RESOLVED", "CLAIMED"][s] ?? String(s);
}
