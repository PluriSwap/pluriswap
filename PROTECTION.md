# Protección: kernel, paquetes y DAO

Este archivo define **cómo** el kernel habla con los paquetes opcionales y con la DAO. No redefine la máquina (`STATE_MACHINE.md`), ni las fórmulas de reputación/bonds (`PACKAGES.md`), ni los pools (`POOLS.md`).

El kernel no “tiene” humanidad, reputación, bonds, ZK, arbitraje ni DAO. Tiene **puntos de llamada nombrados**. Un deal nombra identidades de paquete en `termsHash`. Si no nombra ninguna, Core-only: mismo grafo, cero fees de paquete, cero caps.

```
deal.terms  →  packageId[]     (opt-in)
kernel      →  paquetes        (unidireccional: pregunta / reserva / cobra / notifica)
paquetes    ↛  kernel          (no escriben estado del deal, no mueven principal Core)
DAO         =  recipient       (nunca caller, nunca writer de escrow)
```

---

## 1. Qué es protección aquí

Protección es todo lo que **no** hace falta para un escrow bilateral y que las partes eligen para racionar riesgo o acelerar el fiat:

| Pieza | Qué protege | Relación con el kernel |
| --- | --- | --- |
| Human Passport | Sybil: el sujeto es un humano | Admisión: el kernel pide un sujeto autenticado |
| Reputación | Tamaño del deal y costo de acceso | Admisión: el kernel pide un cap; post-terminal: consume el record |
| Bonds | Skin y cap alto | Activación: reserva; terminal: el kernel aplica suelta / slash / quema |
| ZK | Verdad del pago | Arista: el kernel acepta solo el verifier V y apaga `DISPUTED` |
| Arbitraje | Veredicto cuando no hay ZK | Arista: el kernel mapea un ruling cerrado a un terminal |
| DAO | Financiar esos servicios | Recipient de fees que **el paquete** declaró |

Core no es un modo degradado. Es el recinto. La protección se engancha o no se engancha.

---

## 2. Contrato de llamada

El kernel, en un punto nombrado, hace una de estas cosas. Nada más.

| Verbo | Cuándo | Qué espera de vuelta | Si falla |
| --- | --- | --- | --- |
| `identify` | Activación | Sujeto Passport (nullifier) por Holder y por Provider | Reject atómico; no hay deal |
| `admit` | Activación | `cap` del sujeto; `ok` si `inFlight + principal <= cap` | Reject atómico |
| `invoice` | Activación / contest-open / verificar / completion | `(amount, recipient, payer)` del **paquete**, no del deal | Reject si no se puede cobrar |
| `reserveBond` | Activación | Lock `dealId → amount` en el BondVault del sujeto | Reject atómico |
| `verifyProof` | `FUNDED` + ZK | `dealId` ok + `paymentNullifier` fresco de V | Ignore / reject; el deal no cambia |
| `openCourt` | `FIAT_SENT` o `DISPUTED` | Disputa creada bajo adapter snapshotado | Reject; estado igual |
| `readRuling` | `ARBITRATION_ACTIVE` | `holder_win` / `provider_win` / `stalemate` | Ignore si no es de esa terna |
| `disposeBond` | Terminal | Nada: unlock del lock, slash al ganador, o quema | El terminal Core ya commitió |
| `notifyTerminal` | Después del commit | Nada requerido | Fallo **no** revierte el escrow |

Reglas duras:

- El paquete no devuelve receivers, outcomes, estados, ni destinos de principal.
- `invoice.recipient` y `invoice.amount` salen del hash inmutable del paquete. El deal no los pisa.
- La DAO no aparece como verbo. Si un paquete oficial la puso de recipient, el kernel le acredita. Si el deal eligió un clon con fee cero, la DAO no cobra.
- `notifyTerminal` es EP-POST: reputación e `inFlight` se actualizan después. Si revierte, el escrow ya es terminal; se reintenta. No se deshace `RELEASED`.

---

## 3. El deal solo nombra paquetes

`termsHash` incluye, para cada perfil encendido, la identidad content-addressed del paquete (código, policy, fee schedule, burn sink si hay bonds, verifier V si hay ZK, adapter si hay arbitraje).

No incluye `daoFee`, `daoRecipient`, ni un amount editable. Eso vive en el paquete.

Activación: el kernel carga esas identidades, las snapshottea, y no las vuelve a leer de un registry. Upgrade, pause o delisting posteriores no mutan el deal vivo.

---

## 4. Secuencia

### 4.1 Activación (hacia `FUNDED`)

Orden fijo si los paquetes están seleccionados. Un paso que falla revierte todo: nonce de `HolderAuthorization` intacto, sin principal, sin fee, sin bond, sin `inFlight`.

```
1. Verificar HolderAuthorization + Provider (+ ControllerAcceptance)
2. identify     Passport → sujetoH, sujetoP
3. admit        Reputación: cap(sujeto, bond?) ≥ inFlight + principal
                (Holder y Provider por separado; gana el más chico)
4. invoice      Reputación: fee de activación → recipient del paquete (oficial: DAO)
5. reserveBond  lock en BondVault (10% de este principal; no se puede withdraw)
6. Pull exacto del principal desde el Holder
7. Snapshot de paquetes, sujetos, clocks. Destinos = Holder y Provider de firma.
8. FUNDED
```

ZK no cobra aquí. Arbitraje no cobra aquí. Passport no cobra.

Sin estos paquetes: pasos 2–5 no existen. Firma + pull → `FUNDED`.

### 4.2 Deal activo

El kernel corre `STATE_MACHINE.md`. Los paquetes no tienen tick.

| Evento | Kernel | Paquete |
| --- | --- | --- |
| Proof ZK de V | `verifyProof` → `RELEASED` | Cobra `invoice` al verificar (oficial: DAO) |
| Proof que no es V | Ignore | — |
| Controller abre `DISPUTED` | Si ZK está on: **reject**. Si no: entra `DISPUTED` | `invoice` contest-open solo si el paquete lo declara |
| Controller abre arbitraje | Solo si ARBITRATION on y ZK off | Court fee de la wallet del opener al tribunal; contest-open opcional a la DAO |
| `disputeDeadline` | Cualquiera fuerza `STALEMATE` | — |
| Fiat timeout (deal ZK) | `CANCELLED`; principal al Holder | ZK no cobra |

Un deal ZK no llega a `FIAT_SENT` ni a `DISPUTED`. Un deal con arbitraje no usa el stalemate Core de `DISPUTED` una vez abierto el tribunal: lo reemplaza el mapa del adapter (win o stalemate).

### 4.3 Terminal (un solo commit)

```
1. Kernel escribe el terminal record (estado, deltas, origen)
2. El escrow acredita Holder / Provider / fee ya invoiced (credit-first; push opcional)
3. disposeBond  unlock | slash del lock al ganador | quema ambos locks (stalemate)
4. Commit
5. notifyTerminal  reputación: count/volume/penalty, suelta inFlight
```

El paso 5 no puede revertir 1–4. Humanidad no se llama en el terminal.

---

## 5. Fees: el kernel cobra, el paquete decide

Momentos cerrados (`PACKAGES.md` §7). El kernel no inventa un quinto.

| Momento | Quién declara amount/recipient | Payer | Oficial |
| --- | --- | --- | --- |
| Activación | Paquete reputación | Holder (extra al principal) | DAO |
| Abrir contest | Paquete arbitraje (opcional) | Wallet del opener | DAO si el paquete lo dice |
| Court | Adapter / policy de arbitraje | Wallet del opener | El tribunal, **no** la DAO |
| Al verificar ZK | Paquete ZK | Según el paquete; típico del lado Provider en `RELEASED` | DAO |
| Completion (split u otro) | El paquete que lo declare | Sobre el **principal completo**, antes de partir | DAO si el paquete lo dice |

Quema de bonds en stalemate: sink inmutable del paquete BONDS. **No** es un fee. **No** va a la DAO.

Core-only: todas las filas amount = 0.

---

## 6. DAO

La DAO no es un actor del escrow. No firma deals, no es Controller, no pausa, no elige receivers, no es burn sink.

Puede ser, si y solo si un paquete **oficial** lo escribió en su preimage:

- recipient del fee de reputación (activación);
- recipient del fee ZK (al verificar);
- recipient de un contest-open o completion que ese paquete declare.

No cobra por Human Passport. No cobra por existir un bond. No cobra un deal Core-only. No cobra un paquete clon con fee cero: ese es otro hash. No cobra la rampa de bridge: solo el costo de Stargate (o la otra rampa) y el gas.

Gobernanza de la DAO (tesorería, listados, frontends) es fuera de este archivo. Sobre un deal vivo no tiene verbo.

---

## 7. Matriz de acoplamiento

| Paquete | Punto kernel | Entra | Sale | No puede |
| --- | --- | --- | --- | --- |
| Passport | `identify` en activación | Credencial autenticada | Nullifier / sujeto | Liberar principal; ser gate de Core-only |
| Reputación | `admit` + `invoice` en activación; `notifyTerminal` | Sujeto, principal, bond, `inFlight` | cap / ok / fee | Mutar un deal vivo; revertir settlement |
| Bonds | `reserveBond` / `disposeBond` | Vault del sujeto, `dealId`, outcome | Lock; unlock/slash/quema | Mezclar con principal; withdraw de `locked`; elegir destinos fuera de la fórmula |
| ZK | `verifyProof`; apaga CASE-CORE-11/07/06 | Proof de V, `dealId`, `paymentNullifier` | `RELEASED` + invoice | Aceptar otro verifier; reusar nullifier o proof de otro deal; bloquear fiat-timeout |
| Arbitraje | `openCourt` / `readRuling` | Fee del Controller | Estado `ARBITRATION_ACTIVE` o terna holder_win / provider_win / stalemate | Mover custodia; ruling parcial; que abra alguien que no es el Controller |
| DAO | Ninguno propio | — | Crédito si es recipient | Inyectarse en un deal que no eligió su paquete |

Pool no está en esta matriz. Es un Holder (`POOLS.md`). Habla `HolderAuthorization`, no un perfil de protección.

Rampa tampoco. Es un composer delante o detrás del escrow (`RAMPS.md`). No tiene verbo. No cobra para el protocolo.

---

## 8. Fallos

| Situación | Comportamiento |
| --- | --- |
| Paquete requerido ausente, revert, o evidencia stale en activación | No hay deal |
| ZK no produce proof | Fiat-timeout / cancel; no `DISPUTED` |
| Adapter de arbitraje mudo | Arbitration timeout → `STALEMATE`; cualquiera lo ejecuta |
| `notifyTerminal` (reputación) revierte | Escrow intacto; retry permissionless |
| Paquete no seleccionado | Su arista o hook rechaza o está ausente; Core sigue |
| Usuario pone fee 0 en los términos | Irrelevante: el fee no vive ahí |

---

## 9. Invariantes

- El kernel es el único escritor del deal y el único que mueve principal Core.
- Los paquetes se enganchan en verbos de las secciones 2 y 4. Un verbo nuevo es versión nueva de protocolo.
- Opt-in por identidad de paquete. Core-only no paga a la DAO.
- Fees: el paquete declara; el kernel cobra en un momento de la lista cerrada.
- La DAO es address de crédito, no autoridad.
- Admisión fail-closed. Post-terminal fail-open respecto del escrow.
- Un deal ZK no entra a `DISPUTED`. Un deal sin ZK puede; el timeout de esa disputa es `STALEMATE`.
- Protección nunca reescribe Holder, Provider, Controller, ni el retorno del principal al Holder.
