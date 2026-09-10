# Arquitectura

Este archivo congela **cómo se parten las piezas** y **cómo se bindean**. No reabre el grafo, la economía, ni el typed data.

La spec es la verdad. Un recorte de bytecode que congele un set “oficial” en el constructor **no** es el protocolo.

| Tema | Fuente (manda si hay conflicto) |
| --- | --- |
| Estados, transiciones, outcomes, roles | `STATE_MACHINE.md` |
| EIP-712, nonces, `dealId` | `ENCODING.md` |
| Fórmulas de paquetes y bonds | `PACKAGES.md` |
| Verbos kernel → paquete y DAO | `PROTECTION.md` |
| Constitución de un vault Holder | `POOLS.md` |
| Bridge in/out | `RAMPS.md` |
| Bytecode, OZ, visibilidad | `IMPLEMENTATION.md` |
| Capas, binding, resolución, observabilidad | **este archivo** |

Si un diseño propuesto no encaja en una capa de la sección 2, no es una extensión: es otra arquitectura.

---

## 1. Recinto

PluriSwap es un escrow de principal cripto contra fiat offchain. El recinto de settlement es **una chain y un deployment**. Hoy: Arbitrum, dominio EIP-712 `PluriSwap` / `1`.

```
                    ┌─────────────────────────────────────┐
  Holder ──pull──►  │  Escrow = máquina + caja del deal   │
  Provider ◄─credit │  único escritor de estado Core      │
  Controller opera  │  único que mueve principal          │
                    └──────────────┬──────────────────────┘
                                   │ verbos (unidireccional)
                                   ▼
                    cualquier impl compatible (opt-in por deal)
                    Passport / Reputation / Bonds / ZK / Court
                    BondVault es otra caja (skin, no principal)

  Pool  = Holder-contrato (EIP-1271 + pull). No es un perfil del kernel.
  Rampa = composer delante o detrás. No tiene verbo.
  DAO   = recipient que *un* paquete puso en su hash. Nunca caller.
```

Mandatory Core: Holder y Provider cualesquiera activan, fondean y llegan a terminal **sin** paquetes, pool, rampa, DAO, ni frontend. `packageIds = []`.

El kernel no tiene dueño, no pausa, no lista paquetes, no endosa impls. Cualquiera despliega un escrow. Cualquiera publica un paquete. Las partes eligen IDs. El relayer trae las addresses. El kernel verifica y snapshottea.

---

## 2. Capas

Cinco capas. El kernel no absorbe las otras.

| Capa | Qué es | Qué no es |
| --- | --- | --- |
| **Kernel** | Máquina + custodia de principal. Consentimiento, catálogo, pull exacto, créditos, clocks | Identidad, tribunal, verifier, NAV, bridge, catálogo de vendors |
| **Paquetes** | Módulos opt-in detrás de verbos y *kinds* nombrados. El deal nombra `packageId`s | Escritores de estado Core. Cajas de principal. Un allowlist del constructor |
| **BondVault** | Caja de skin, keyeada por sujeto Passport | El escrow. Un fee. La DAO |
| **Pool** | Servicio de liquidez que *es* el Holder | Un perfil `POOL`, un mandato, un fee de Controller en el kernel |
| **Rampa** | Composer de token hacia/desde el Holder | Estados `BRIDGING_*`. `invoice` de protocolo |

Reglas de borde:

- El kernel llama a los paquetes. Los paquetes no llaman al kernel para escribir el deal.
- Un paquete no devuelve receivers, outcomes, ni destinos de principal.
- Un pool no abre otro catálogo. Produce el mismo `HolderAuthorization`.
- Una rampa termina antes de `activate` o después de `withdraw`.
- Upgrade, pause o delisting de un paquete no mutan un deal ya snapshotado. Las salidas Core siguen.
- No hay registry como gate de `activate`. Anunciar impls es un servicio. Ejecutar no lo pide.

---

## 3. Superficie del kernel

El kernel ve tres roles: **Holder**, **Provider**, **Controller**. No ve Sponsor, LP, rampa, ni DAO.

### 3.1 Qué guarda

Por `dealId`: status, `DealTerms`, orígenes de reloj, sujetos Passport si hay, **addresses resueltas** de los módulos de *ese* deal, bitmap de kinds, `holderAmt` / `providerAmt` al terminal.

Por firmante: `used[signer][nonce]`.

Por token y beneficiario: créditos maduros.

No guarda un set mundial de paquetes oficiales. No guarda fees ni receivers: viven en el `packageId`.

### 3.2 Entrypoints (clases)

| Clase | Quién | Ejemplos |
| --- | --- | --- |
| Activación | Relayer cualquiera | `activate` (+ módulos en calldata, no en el digest) |
| Autoridad de rol | Provider o Controller snapshotado | `markFiat`, `cancelByProvider`, `release`, `openDisputed`, `openCourt` |
| Permissionless | Cualquiera | `timeoutFiat`, `claim`, `forceStalemate`, `forceArbitrationTimeout`, `verifyProof` |
| Dual-sign | Relayer; firman Provider + Controller | `mutualCancel`, `coSignedRelease`, `mutualSplit` |
| Lectura de extensión | Cualquiera, si el perfil está on | `readRuling` |
| Crédito | Beneficiario | `withdraw` |
| Nonce | `msg.sender` | `cancelNonce` |

### 3.3 Dependencias

El kernel **no importa implementaciones**. Habla las interfaces de la sección 4. OpenZeppelin: crypto, ERC-20, reentrancy (`IMPLEMENTATION.md`).

`Machine.sol` no es una capa. El catálogo es `STATE_MACHINE.md`.

El constructor del escrow **no** recibe paquetes. Un escrow vacío es un recinto Core completo.

### 3.4 Lectura — `IEscrow`

Cualquier contrato (paquete, pool, rampa, indexer) lee el recinto por `src/interfaces/IEscrow.sol`. No hay un view ad-hoc por consumidor. El kernel no escribe deal ni mueve principal por esta interfaz.

| Getter | Qué |
| --- | --- |
| `terms(dealId)` | `DealTerms` snapshotados |
| `clocks(dealId)` | orígenes (`activatedAt`, `fiatSentAt`, `disputedAt`, `arbitrationOpenedAt`) |
| `subjects` / `modules` / `kinds` | sujetos Passport, `PackageMods`, bitmap |
| `settlementOf` / `status` / `creditOf` | terminal y créditos |
| `domainSeparator` / `used` / `dealOf` | consentimiento; `dealOf` es el `dealId` de un nonce consumido en `activate` |

`notifyTerminal` recibe el sujeto de `subjects`, no re-identifica. Un remap de Passport no muda `inFlight` ni el score de *ese* deal.

---

## 4. Contrato de paquete (interfaces)

Los *kinds* son la superficie cerrada de extensión (EXT-01). Cinco. Un kind nuevo es versión nueva de kernel. Las **impls** de cada kind son permissionless.

| Interfaz | Kind | Verbos | Policy que entra al `packageId` |
| --- | --- | --- | --- |
| `IPassport` | PASSPORT | `identify` | address del adapter |
| `IReputation` | REPUTATION | `admit`, `invoiceActivation`, `invoiceCompletion`, `notifyTerminal` | module, feeRecipient, activationFee, completionFee |
| `IBondVault` | BONDS | `reserve`, `unlock`, `slash`, `burn` | vault, sink, lock bps |
| `IPaymentProof` | ZK | `verifyProof`, `invoiceVerify` | module, verifier V, feeRecipient, verifyFee |
| `IVerifier` | (no es paquete) | `verify → (dealId, nullifier)` | — |
| `ICourt` | ARBITRATION | `openCourt`, `readRuling`, `packageBinding` | adapter, partner, key |

`packageId = hash(kind, address del módulo, policy)`. El kernel **recomputa** ese hash con `libraries/PackageId` y la address que trajo el relayer. La fórmula es del kernel, no un catálogo de vendors: cualquier impl cuyo hash esté firmado resuelve. No confía en un `packageId()` que el módulo pueda mentir. Mentir sobre la policy solo produce *otro* ID; si las partes no lo firmaron, no hay deal.

`admit` / `notifyTerminal` / `verifyProof` / `reserve` / `dispose` / `openCourt` los llama el kernel. Un extraño no es el kernel. Cada impl bindea un `operator` inmutable (el escrow) al deploy; no es un campo de `DealTerms` ni entra al `packageId`.

---

## 5. Resolución — permissionless

### 5.1 Qué se firma

`DealTerms.packageIds`: identidades content-addressed, canónicas. El deal no firma addresses, `daoFee`, ni amounts.

Las partes que quieren un paquete comunitario (fee cero, otro V, otro tribunal) firman **ese** hash. Mismo typehash de `DealTerms`.

### 5.2 Cómo se resuelve (único perfil)

En `activate`, el calldata trae `PackageMods` — cinco slots, uno por kind, no firmados:

```
passport | reputation | bonds | zk | court
```

El kernel, por cada slot no nulo:

1. Lee la policy pública del módulo.
2. Recomputa `id = PackageId.kind(address, policy)`.
3. Exige que `id` esté en `terms.packageIds`.
4. Si hay Reputation o Bonds, exige `module.passport() == mods.passport`.

El kernel cobra con los getters que entran al hash (`activationFee`, `completionFee`, `verifyFee`, `feeRecipient`). `invoice*` es lectura; no es la fuente del cobro.

Exige además que **cada** `packageIds[i]` haya sido reclamado por exactamente un slot. Si sobra un ID o sobra un módulo, reject. Core-only: array vacío, slots nulos.

No hay constructor allowlist. No hay registry. El mismo escrow resuelve, en deals distintos, un Passport oficial y un Reputation clon, o dos courts, o ninguno.

Un relayer no puede colar otro módulo: el ID firmado bindea la address. Un módulo en el slot equivocado (un Passport en `zk`) produce otro kind-hash y no matchea.

### 5.3 PERM-03 / PERM-05 / TRUST-02

| Invariante | Significado |
| --- | --- |
| PERM-03 | Cualquiera publica un contrato que cumple la interfaz. Nadie pide permiso al kernel ni a una DAO |
| PERM-05 / PERM-08 | Endoso, frontend o registry no son gate de `activate` |
| TRUST-02 | Usarlo exige que las tres partes firmen ese `packageId` |
| EXT-10 | El kernel snapshottea address (+ kinds) en activación. Drift posterior no muta el deal vivo |
| KERNEL-04 | Sin paquete, o paquete hostil: las salidas Core de *ese* deal siguen; un deal Core-only no se entera. Un fee que no cabe en el leftover se omite; el terminal no revierte |

Publicar y usar pasan por el **mismo** escrow. No hace falta otro deployment de kernel para un paquete nuevo.

### 5.4 Snapshot e incompatibles

En `FUNDED` quedan las addresses resueltas y el bitmap de kinds. Los verbos posteriores (`verifyProof`, `openCourt`, `disposeBond`, `notifyTerminal`) usan **ese** snapshot, no un global.

Incompatibles al resolver: ZK + ARBITRATION. Reputación sin Passport. Bonds sin Passport + Reputación.

El kernel **re-verifica** el ID contra los getters en vivo en cada momento de invoice y dispose: un módulo que deriva su policy (proxy, fee mutable) pierde el cobro — fee 0 en completion, fail-open en `disposeBond` — y `verifyProof` / `openCourt` lo rechazan (`PackageDrift`). Las salidas Core del deal siguen (KERNEL-04).

---

## 6. Observabilidad

| Evento | Cuándo |
| --- | --- |
| `Activated(dealId, holder, provider, controller, token, principal)` | CASE-CORE-01 |
| `Transitioned(dealId, from, to)` | Todo cambio de estado |
| `Settled(dealId, status, holderAmt, providerAmt)` | Commit terminal |

`settlementOf(dealId)` es el mismo record on-chain. Sin callback de pool en el terminal.

`notifyTerminal` es EP-POST: revert no deshace el escrow. `disposeBond` no puede ser el único camino que, al revertir, congele un outcome ya decidido (`PROTECTION.md` §2).

---

## 7. Pool y rampa

**Pool.** Holder-contrato. EIP-1271 + pull; holder-gross + `settlementOf` de vuelta. Constitución en `POOLS.md`.

**Rampa.** Composer. Cero bps de protocolo. `RAMPS.md`.

---

## 8. Versionado

| Cambio | Qué se bumpa |
| --- | --- |
| Campo nuevo en `DealTerms`, reloj Core, verbo o *kind* nuevo | Kernel `version` y contrato nuevo |
| Paquete nuevo (otro V, otro fee, otro sink, otro adapter) | Otro `packageId`. Mismo escrow, mismo typehash |
| Constitución de pool | Otra impl + otra factory |
| Otra rampa | Otro composer |
| Recorte de bytecode | Nada |

Upgrade del escrow = deployment nuevo. Deals viejos intactos. No hay proxy.

---

## 9. Invariantes

- Un escritor de estado del deal: el escrow. Sin owner, sin pausa, sin lista de paquetes.
- Un motor de principal: el escrow. Credit-first.
- El deal nombra IDs. Los paquetes nombran fees. El relayer trae addresses. El kernel recomputa el ID.
- El kernel habla interfaces. Cualquier impl compatible entra por `activate`.
- No hay registry ni constructor allowlist como gate.
- Publicar no requiere endorsement. Usar requiere el `packageId` firmado.
- Core-only no paga, no admite, no reserva, no verifica, no abre corte.
- Pool y rampa no añaden estados ni verbos.
- El record terminal es observable. EP-POST no revierte el escrow.

---

## 10. Alineación del bytecode

El protocolo es esta arquitectura. El código se alinea a ella: constructor vacío, `PackageMods` en `activate`, `PackageId` recompute, interfaces, snapshot por deal. Un set “oficial” puede existir como *producto* (JSON, frontend, skill). No existe como gate del kernel.
