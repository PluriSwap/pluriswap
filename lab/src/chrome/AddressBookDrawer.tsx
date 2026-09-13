import { focusSet } from "../app/actions.ts";
import * as S from "../app/store.ts";
import { Addr, Badge, Button, Help } from "../ui/atoms.tsx";

export function AddressBookDrawer() {
  if (!S.bookOpen.value) return null;
  const focus = S.escrow.value;
  return (
    <aside class="book">
      <header>
        <strong>AddressBook</strong>
        <Button onClick={() => (S.bookOpen.value = false)}>cerrar</Button>
      </header>
      <Help>
        Un JSON de <code>deployments/</code> = un <em>set</em> de addresses bound al <code>escrow</code> de ese archivo. Es un atajo, no un
        registry: pegar cualquier address compatible vale igual. <code>testToken</code> es por archivo, nunca global.
      </Help>
      {S.sets.map((set) => {
        const isFocus = !!focus && set.escrow === focus && set.chainId === S.chainId.value;
        return (
          <details class={`set${isFocus ? " is-focus" : ""}`} key={set.sourceFile} open={isFocus}>
            <summary>
              <code>{set.sourceFile}</code>
              <span class="muted"> · chain {set.chainId ?? "?"}</span>
              {set.isRecinto ? <Badge tone="ok">recinto</Badge> : <Badge tone="muted">auxiliar (sin escrow)</Badge>}
              {isFocus && <Badge tone="info">en foco</Badge>}
            </summary>
            {set.isRecinto && (
              <p>
                escrow <Addr value={set.escrow} full />{" "}
                {!isFocus && <Button onClick={() => focusSet(set)}>usar este escrow</Button>}
              </p>
            )}
            {set.testToken && (
              <p>
                testToken de <em>este</em> archivo: <Addr value={set.testToken} full />
              </p>
            )}
            <table class="labels">
              <tbody>
                {Object.entries(set.labels).map(([k, v]) => (
                  <tr key={k}>
                    <td>{k}</td>
                    <td>{/^0x[0-9a-fA-F]{40}$/.test(v) ? <Addr value={v} full noLabel /> : <code>{v}</code>}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </details>
        );
      })}
    </aside>
  );
}
