import { ROLES, type Role, type SeatState } from "../addressbook/types.ts";

export function renderRoleStrip(
  root: HTMLElement,
  seats: SeatState[],
  active: Role,
  on: { active: (role: Role) => void; address: (role: Role, value: string) => void },
): void {
  const holder = seats.find((s) => s.role === "Holder")?.address;
  const controller = seats.find((s) => s.role === "Controller")?.address;
  const p2p = holder && controller && holder.toLowerCase() === controller.toLowerCase();

  root.innerHTML = `
    <div class="roles-head">
      <span>Asientos</span>
      <span class="muted">PR-1: desconectados. Pegar address es sesión, no una wallet. No hay secretos.</span>
      ${p2p ? `<span class="chip">Holder=Controller</span>` : ""}
    </div>
    <div class="roles">
      ${seats
        .map((seat) => {
          const onClass = seat.role === active ? " is-on" : "";
          return `<article class="seat${onClass}" data-role="${seat.role}">
            <button type="button" class="seat-pick" data-role="${seat.role}">
              <strong>${seat.role}</strong>
              <span class="muted">${seat.address ? "address de sesión" : "desconectado"}</span>
            </button>
            <input spellcheck="false" data-role="${seat.role}" placeholder="0x… (opcional)"
              value="${seat.address ?? ""}" />
          </article>`;
        })
        .join("")}
    </div>
    <p class="hint">El asiento activo será <code>msg.sender</code> de la próxima tx (PR-4). Relayer = cualquiera. DAO no es asiento.</p>
  `;

  root.querySelectorAll<HTMLButtonElement>(".seat-pick").forEach((btn) => {
    btn.addEventListener("click", () => on.active(btn.dataset.role as Role));
  });
  root.querySelectorAll<HTMLInputElement>("input[data-role]").forEach((input) => {
    input.addEventListener("change", () => {
      const role = input.dataset.role as Role;
      if (ROLES.includes(role)) on.address(role, input.value.trim());
    });
  });
}
