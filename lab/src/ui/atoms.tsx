import type { ComponentChildren, JSX } from "preact";
import { useEffect, useState } from "preact/hooks";
import { labelFor } from "../app/store.ts";

export function Panel(props: {
  title: ComponentChildren;
  subtitle?: ComponentChildren;
  children: ComponentChildren;
  kind?: "kernel" | "lab" | "pool" | "derived" | "plain";
  right?: ComponentChildren;
  id?: string;
  collapsed?: boolean;
}) {
  const [open, setOpen] = useState(!props.collapsed);
  // Si el padre cambia `collapsed` (p.ej. un log que pasa de vacío a lleno), seguirlo.
  useEffect(() => setOpen(!props.collapsed), [props.collapsed]);
  return (
    <section class={`panel panel-${props.kind ?? "plain"}`} id={props.id}>
      <header class="panel-head" onClick={() => setOpen((o) => !o)}>
        <div>
          <h3>{props.title}</h3>
          {props.subtitle && <p class="panel-sub">{props.subtitle}</p>}
        </div>
        <div class="panel-right" onClick={(e) => e.stopPropagation()}>
          {props.right}
          <span class="chev" onClick={() => setOpen((o) => !o)}>
            {open ? "▾" : "▸"}
          </span>
        </div>
      </header>
      {open && <div class="panel-body">{props.children}</div>}
    </section>
  );
}

export function Badge(props: { tone?: "ok" | "warn" | "bad" | "muted" | "lab" | "info"; children: ComponentChildren; title?: string }) {
  return (
    <span class={`badge badge-${props.tone ?? "muted"}`} title={props.title}>
      {props.children}
    </span>
  );
}

export function Field(props: {
  label: ComponentChildren;
  hint?: ComponentChildren;
  children: ComponentChildren;
  inline?: boolean;
}) {
  return (
    <label class={`field${props.inline ? " field-inline" : ""}`}>
      <span class="field-label">{props.label}</span>
      {props.children}
      {props.hint && <span class="field-hint">{props.hint}</span>}
    </label>
  );
}

export function Input(props: JSX.InputHTMLAttributes<HTMLInputElement> & { onValue?: (v: string) => void }) {
  const { onValue, ...rest } = props;
  return (
    <input
      spellcheck={false}
      autocomplete="off"
      {...rest}
      onInput={(e) => {
        onValue?.((e.currentTarget as HTMLInputElement).value);
        (rest.onInput as ((e: Event) => void) | undefined)?.(e);
      }}
    />
  );
}

export function Button(props: JSX.ButtonHTMLAttributes<HTMLButtonElement> & { tone?: "primary" | "ghost" | "lab" | "danger"; busy?: boolean }) {
  const { tone, busy, children, ...rest } = props;
  return (
    <button type="button" class={`btn btn-${tone ?? "ghost"}`} {...rest} disabled={busy || !!rest.disabled}>
      {busy ? "…" : children}
    </button>
  );
}

export function short(hex: string | null | undefined, head = 6, tail = 4): string {
  if (!hex) return "—";
  if (hex.length <= head + tail + 2) return hex;
  return `${hex.slice(0, head + 2)}…${hex.slice(-tail)}`;
}

export function Addr(props: { value: string | null | undefined; full?: boolean; noLabel?: boolean }) {
  const [copied, setCopied] = useState(false);
  if (!props.value) return <code class="addr muted">—</code>;
  const label = props.noLabel ? null : labelFor(props.value);
  const zero = /^0x0{40}$/i.test(props.value);
  return (
    <code
      class={`addr${zero ? " muted" : ""}`}
      title={`${props.value} (click: copiar)`}
      onClick={() => {
        void navigator.clipboard?.writeText(props.value!);
        setCopied(true);
        setTimeout(() => setCopied(false), 800);
      }}
    >
      {zero ? "0x0 (nulo)" : props.full ? props.value : short(props.value)}
      {label && <span class="addr-label">{label}</span>}
      {copied && <span class="addr-copied">copiado</span>}
    </code>
  );
}

export function Hex32(props: { value: string | null | undefined }) {
  return <Addr value={props.value} noLabel />;
}

export function Help(props: { children: ComponentChildren }) {
  return <p class="help">{props.children}</p>;
}

export function Warn(props: { children: ComponentChildren; tone?: "warn" | "bad" | "info" }) {
  return <p class={`callout callout-${props.tone ?? "warn"}`}>{props.children}</p>;
}

export function KV(props: { rows: [ComponentChildren, ComponentChildren][] }) {
  return (
    <dl class="kv">
      {props.rows.map(([k, v], i) => (
        <div key={i}>
          <dt>{k}</dt>
          <dd>{v}</dd>
        </div>
      ))}
    </dl>
  );
}

export function fmtTs(ts: bigint | number | null | undefined): string {
  if (ts === null || ts === undefined) return "—";
  const n = Number(ts);
  if (!n) return "0 (no arrancó)";
  return `${n} · ${new Date(n * 1000).toLocaleString()}`;
}

export function fmtDur(s: bigint | number): string {
  const n = Number(s);
  if (n === 0) return "0 s";
  if (n % 86_400 === 0) return `${n / 86_400} d`;
  if (n % 3600 === 0) return `${n / 3600} h`;
  if (n % 60 === 0) return `${n / 60} min`;
  return `${n} s`;
}

export function fmtAmt(v: bigint | null | undefined): string {
  if (v === null || v === undefined) return "—";
  return v.toLocaleString("en-US");
}

export function Seat(props: { seat: string }) {
  const s = props.seat;
  const tone = s === "LAB" ? "lab" : s === "anyone" ? "muted" : "info";
  return <Badge tone={tone}>{s === "anyone" ? "cualquiera" : s}</Badge>;
}
