import { refreshHead, refreshProbe, setChain, setEscrowPaste } from "../app/actions.ts";
import * as S from "../app/store.ts";
import { Addr, Badge, Button, Input, short } from "../ui/atoms.tsx";

export function RecintoBar() {
  const p = S.probe.value;
  const head = S.chainHead.value;
  const tone = !p ? "muted" : p.error ? "bad" : p.domainMatches ? "ok" : "warn";
  const label = !p
    ? S.probing.value
      ? "leyendo…"
      : "sin probar"
    : p.error
      ? "sin código / RPC"
      : p.domainMatches
        ? "dominio OK"
        : "dominio ≠ chain";
  return (
    <div class="recinto-bar">
      <div class="brand">
        <strong>PluriSwap</strong>
        <span>consola de laboratorio</span>
      </div>
      <div class="recinto-fields">
        <select value={String(S.chainId.value)} onChange={(e) => setChain(Number((e.currentTarget as HTMLSelectElement).value))}>
          <option value="31337">Anvil · 31337</option>
          <option value="421614">Arbitrum Sepolia · 421614</option>
          <option value="42161">Arbitrum One · 42161</option>
        </select>
        <Input class="rpc" value={S.rpcUrl.value} onValue={(v) => (S.rpcUrl.value = v)} placeholder="RPC" title="RPC del recinto" />
        <Input
          class="escrow"
          value={S.escrowPaste.value}
          onValue={setEscrowPaste}
          placeholder="escrow 0x… (pegá cualquiera compatible)"
          title="Escrow en foco. Pegar está al mismo nivel que elegir del AddressBook."
        />
        <Button onClick={() => void refreshProbe()} busy={S.probing.value}>
          leer dominio
        </Button>
        <Badge tone={tone} title={p?.domainSeparator ?? ""}>
          {label}
          {p?.domainSeparator ? ` · ${short(p.domainSeparator, 4, 4)}` : ""}
        </Badge>
      </div>
      <div class="chain-clock" title="Cabeza del RPC del recinto. Es el block.timestamp que usa el kernel, no el reloj de tu laptop.">
        {head ? (
          <>
            <span>#{head.number.toString()}</span>
            <span>{new Date(Number(head.timestamp) * 1000).toLocaleTimeString()}</span>
          </>
        ) : (
          <span class="muted">sin bloque</span>
        )}
        <Button onClick={() => void refreshHead()}>↻</Button>
        <Button onClick={() => (S.bookOpen.value = !S.bookOpen.value)}>AddressBook</Button>
      </div>
      {p && p.rpcChainId !== null && p.rpcChainId !== S.chainId.value && (
        <div class="bar-warn">
          El RPC responde chainId {p.rpcChainId}, no {S.chainId.value}. Las firmas se harán con {p.rpcChainId}. Corregí uno de los dos.
        </div>
      )}
      {S.escrow.value && (
        <div class="recinto-line">
          Recinto en foco: <Addr value={S.escrow.value} full /> · EIP-712 <code>PluriSwap / 1 / {S.effectiveChainId.value}</code>
          {S.setsForRecinto().length > 0 && <span class="muted"> · sets: {S.setsForRecinto().map((s) => s.sourceFile).join(", ")}</span>}
        </div>
      )}
    </div>
  );
}
