import { setActiveRole, setSeatAddress, setSeatPk } from "../app/actions.ts";
import * as S from "../app/store.ts";
import { ROLES } from "../addressbook/types.ts";
import { Badge, Button, Input, short } from "../ui/atoms.tsx";

const HINT: Record<string, string> = {
  Holder: "Pone el principal. Firma HolderAuthorization. En P2P también es Controller.",
  Provider: "Paga el fiat offchain. markFiat, cancelByProvider, firma dual-sign.",
  Controller: "Juzga si el fiat llegó: release / openDisputed / openCourt. Firma dual-sign.",
  Relayer: "Envía las txs que llevan firmas (activate, dual-sign) y los verbos permissionless.",
};

/** Cuentas Foundry/Anvil por defecto: solo un atajo para 31337. Nunca se persisten. */
const ANVIL = [
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
  "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
  "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
];

export function SeatStrip() {
  const active = S.activeRole.value;
  return (
    <div class="seat-strip">
      <div class="seat-head">
        <strong>Asientos</strong>
        <span class="muted">
          El asiento activo es <code>msg.sender</code> de la próxima tx. Cambiá de asiento a conciencia: la matriz se recalcula contra él.
        </span>
        {S.p2pSeats.value && <Badge tone="info">Holder = Controller (P2P)</Badge>}
        {S.isAnvil.value && (
          <Button
            onClick={() => {
              ROLES.forEach((r, i) => setSeatPk(r, ANVIL[i === 3 ? 0 : i]!));
              setSeatPk("Controller", ANVIL[0]!);
            }}
            title="Holder = cuenta 0, Provider = cuenta 1, Controller = cuenta 0 (P2P), Relayer = cuenta 0"
          >
            cargar cuentas Anvil
          </Button>
        )}
      </div>
      <div class="seats">
        {S.seats.value.map((seat) => {
          const on = seat.role === active;
          return (
            <article class={`seat${on ? " is-on" : ""}${seat.address ? "" : " is-empty"}`} key={seat.role}>
              <button type="button" class="seat-pick" onClick={() => setActiveRole(seat.role)} title={HINT[seat.role]}>
                <strong>{seat.role}</strong>
                <span class="muted">{seat.address ? short(seat.address) : "desconectado"}</span>
                {on && <Badge tone="ok">activo</Badge>}
              </button>
              <Input value={seat.address ?? ""} onValue={(v) => setSeatAddress(seat.role, v)} placeholder="address 0x…" />
              <Input
                type="password"
                value={seat.pk ?? ""}
                onValue={(v) => setSeatPk(seat.role, v)}
                placeholder="pk de sesión (Anvil / test)"
                title="Solo en memoria. Sin pk el asiento evalúa la matriz pero no envía."
              />
            </article>
          );
        })}
      </div>
    </div>
  );
}
