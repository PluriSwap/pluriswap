import { gotoPathStep, markPathStepDone, stopPath } from "../app/actions.ts";
import * as S from "../app/store.ts";
import { Badge, Button, Seat } from "../ui/atoms.tsx";

/** Bandeja del Path activo. Resalta un verbo; nunca reemplaza la matriz. */
export function PathTray() {
  const p = S.activePath.value;
  if (!p) return null;
  const i = S.pathStep.value;
  const step = p.steps[i];
  return (
    <div class="path-tray">
      <div class="path-head">
        <Badge tone="info">Path</Badge>
        <strong>{p.id}</strong>
        <span class="muted">
          paso {i + 1} / {p.steps.length}
        </span>
        <span class="muted">· duraciones ({p.fiatDuration}, {p.releaseDuration}, {p.disputeDuration}, {p.arbitrationDuration})</span>
        <span class="grow" />
        <Button onClick={() => gotoPathStep(i - 1)} disabled={i === 0}>
          ←
        </Button>
        <Button onClick={markPathStepDone} disabled={i >= p.steps.length - 1}>
          hecho →
        </Button>
        <Button onClick={stopPath}>cerrar</Button>
      </div>
      {step && (
        <div class="path-step">
          <Seat seat={step.seat} />
          <code>{step.verb}</code>
          <span class="muted">en {SPACE_NAME[step.space]}</span>
          {step.expect && <span class="path-expect">esperar: {step.expect}</span>}
          {step.note && <span class="path-note">{step.note}</span>}
          {step.space !== S.space.value && <Button onClick={() => (S.space.value = step.space)}>ir</Button>}
        </div>
      )}
      <ol class="path-steps">
        {p.steps.map((s, k) => (
          <li key={k} class={k < i ? "done" : k === i ? "now" : ""} onClick={() => gotoPathStep(k)} title={s.expect ?? ""}>
            <code>{s.verb.split(/[\s(]/)[0]}</code>
          </li>
        ))}
      </ol>
    </div>
  );
}

export const SPACE_NAME: Record<string, string> = {
  guide: "Guía",
  recinto: "Recinto",
  deal: "Deal",
  consent: "Consentimiento",
  packages: "Paquetes",
  pool: "Pool",
  credits: "Créditos",
  catalog: "Catálogo",
  lab: "Laboratorio",
  ramp: "Rampa",
};
