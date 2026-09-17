# Review: Core vs módulos

Hallazgo de código (2026-09-08). No reabre el grafo ni el typed data. Si hay conflicto sobre estados, manda `STATE_MACHINE.md`. Sobre capas, `ARCHITECTURE.md`. Este archivo congela **brechas** entre spec, bytecode y el recorte “Core trustless + módulos que se referencian”.

**Hecho:** ítems 1–3 y 5. Ítem 4: Passport hecho, court y verifier siguen mock. Ítem 6 resuelto por otra vía: el edge de paquetes salió a la librería externa `Packages` (Escrow 22.2 KB → 15.3 KB). Decisiones de kernel del 2026-09-12 (§3.1, §3.5, `CLAIMED`, zero-checks) cerradas; ver §7.

---

## 1. Mapa de capas

```
                    referencian Core (lectura) y entre ellos
                    ┌─────────────────────────────────────────┐
  Holder / Pool ──► │  CORE                                   │
  Provider          │  Escrow + Consent/Terms/Clocks/Settlement│
  Controller        │  único escritor del deal                 │
  Relayer cualquiera│  único que mueve principal               │
                    └──────────────┬──────────────────────────┘
                                   │ verbos (unidireccional)
                                   ▼
                    PASSPORT · REPUTATION · BONDS · ZK · COURT
                    Pool (Holder-contrato) · Rampa (composer)
```

| Capa | Debe ser | Hoy |
| --- | --- | --- |
| **Core** | Descentralizado, permissionless, trustless. Sin owner, sin pausa, sin allowlist. `packageIds = []` llega a terminal. | Cumple lo esencial. Constructor vacío, timeouts anyone, credit-first del principal, sin `Ownable`/`Pausable`. |
| **Paquetes** | Opt-in. Trust *elegida*. Deben poder leer Core y validarse entre sí (mismo Passport, mismo vault, mismo operator). | El kernel los llama. Hasta el ítem 1 no podían leer el deal por una interfaz compartida. El kernel **aún no comprueba** que Reputation, BondVault y el slot Passport hablen del mismo sujeto. |
| **Pool** | Holder. Un solo borde: EIP-1271 + pull. Referencia `settlementOf`. | `IEscrow` + `dealOf`. Reserva `invoiceActivation`. `credits` se escribe al reconocer el terminal. Approve exacto. |
| **Rampa** | Composer. Cero bps de protocolo. Antes de `activate` o después de `withdraw`. | Taxi only, sin compose. No habla con el escrow. |

---

## 2. Grafo de referencias

**Debería:**

- Core publica `IEscrow` (`status`, `terms`, `clocks`, `settlementOf`, `subjects`, `modules`, `kinds`, `used`, `dealOf`, `domainSeparator`, `creditOf`).
- Cada paquete declara `operator` (escrow) **y** sus peers (`passport()`, `vault()`, `verifier()`).
- En `activate`, el kernel exige `reputation.passport() == mods.passport`, `vault.passport() == mods.passport`, y que el `packageId` bindee la address del módulo en **todos** los kinds.
- Pool reserva `principal + controllerFee + invoiceActivation` leyendo el paquete.
- Rampa no toca el grafo.

**Hoy (tras ítem 1):**

| Desde → Hacia | Existe | Problema |
| --- | --- | --- |
| Escrow → interfaces de paquete | Sí | Core importa `PackageId` desde `packages/` (el ID es concern del kernel). |
| Módulos / pool → Core | **`IEscrow`** | Lectura estable. `notifyTerminal` ya no re-identifica. |
| Reputation → Passport / BondVault | A medias | Passport **propio** en el constructor; vault llega como argumento de `admit`. No se compara con `mods.passport`. |
| BondVault → Passport | A medias | Otro Passport inmutable, distinto del del deal si el relayer mezcla impls. |
| ZK / Court → peers | No | ZK ni siquiera bindea su propia address en el `packageId`. |
| Pool → Escrow | `IEscrow` | Lee `dealOf` / `settlementOf` / `activationFee` del paquete nombrado. |
| Rampa → Escrow | No | Correcto para composer; incompleto vs `RAMPS.md` (compose + activate). |

---

## 3. Diferencias de negocio

### 3.1 `claim` no paga completion; `release` sí — **cerrado**

**Decisión (2026-09-12):** el completion fee se cobra sobre el pot entero en cualquier terminal donde el Provider cobre algo (release, co-firma, split con bps > 0, claim, ZK, arb win del Provider, stalemate 50/50) y nunca en un refund. `claim` cierra en `CLAIMED`.

Hallazgo original:


`release`, `coSignedRelease`, `mutualSplit`, `verifyProof` y un win de corte deducen `completionFee`. `claim` manda el principal entero al Provider.

El Controller (o cualquiera tras el deadline) puede esperar el claim y **evitar el fee de la DAO**. El camino “silencio = no-contestación” queda más barato que el release honesto.

La spec es ambigua (`PACKAGES.md` habla de timeout Holder-positivo; el claim es Provider-positivo). El código eligió no cobrar.

### 3.2 Fee de completion / ZK mayor que el leftover revierte salidas Core

`_takeCompletionFrom` hace `left -= fee` sin `fee <= left`. Un paquete con fee enorme, o `verifyFee + completionFee > principal`, hace underflow y **bloquea** release / split / proof / arb-win. Cancel, timeout fiat, stalemate y claim siguen. Viola KERNEL-04.

El chequeo de drift compara `completionFee()` con el hash. `invoiceCompletion()` puede devolver **otro** amount. Lo mismo en activación y en ZK. El ID no amarra el invoice.

### 3.3 Passport / Reputation / Bonds no son un solo sujeto

En `_engage` el kernel identifica con `mods.passport` y guarda `subjectH/P`. `Reputation.admit` vuelve a llamar **su** `passport.identify(wallet)`. `BondVault.reserve` usa los sujetos del kernel; `withdraw` usa el Passport del vault.

El `packageId` de reputación **no incluye** el Passport. El de bonds **no incluye** el Passport. El kernel no exige igualdad.

Un relayer puede combinar Passport oficial + Reputation clonado con otro Passport. Caps e `inFlight` van a un sujeto; locks y `escrow.subjects` van a otro.

**Ítem 1:** `notifyTerminal` ya recibe el sujeto snapshotado. Un remap de Passport post-activación no deja `inFlight` huérfano por re-identify. `admit` sigue re-identificando (ítem 2).

### 3.4 ZK: el `packageId` no bindea el módulo

`PackageId.zk(verifier, feeRecipient, verifyFee)` omite la address del wrapper. Reputation, Bonds, Passport y Court sí meten la suya.

`ARCHITECTURE.md` dice `hash(kind, address del módulo, policy)`. El kernel llama `mods.zk.verifyProof`, no al verifier. Un wrapper que **reporte** el mismo V y los mismos fees, y cuyo `verifyProof` no verifique, matchea el ID firmado.

`VerifierMock` acepta cualquier `abi.encode(dealId, nullifier)`. El camino ZK de Sepolia no es un proof.

### 3.5 Slash P2P vs Provider-Controller — **cerrado**

**Decisión (2026-09-12):** el slash siempre paga a la address de firma del ganador; no existe la excepción del Controller (`controller == provider` ahora es inválido en `Terms`). Tribunal que rehúsa o no contesta: unlock de ambos, sin culpa probada no se mueve dinero. Sólo el stalemate de `DISPUTED` quema.

Hallazgo original:


Holder-win + `holder == controller`: pasan `controller = address(0)` para que el Holder-P2P **cobre** el slash. Provider-win: siempre pasan el Controller real; si `provider == controller`, el slash **quema al sink**.

La spec dice “nunca al Controller; si el ganador es el Controller, quema”. El código hace una excepción solo para el Holder-P2P.

### 3.6 Pool: tesorería incompleta y fees de paquete invisibles

- `credits` está en `nav()` y `_sync()` y **nunca se incrementa**. Tras un terminal, `locked` sigue contando el deal: NAV inflado. Un `deposit` nuevo mintea contra un NAV fantasma → dilución.
- `authorize` reserva `principal + controllerFee`. El escrow, si hay reputación, hace **otro** `pullExact` del activation fee desde el Holder (el pool). El idle no lo sabía → agujero → `DEFICIENT`. La UI apaga passport/reputation/bonds/arb cuando el Holder es un pool.
- `forceApprove(escrow, type(uint256).max)` deja allowance infinita.

### 3.7 Corte y Passport “oficiales” son mocks

- `PassportMock.setHuman` no tiene auth. Con eso se retira el bond de otro (`withdraw` solo chequea `identify(msg.sender) == subject`).
- `ArbitrationMock.submitRuling` no tiene auth. `open(dealId, controller)` lo puede llamar un extraño y deja `AlreadyOpen` para el escrow.
- La UI expone `setHuman` y `submitRuling` al relayer como si fueran verbos de protocolo.

Kleros está mejor. No es lo que despliega `DeployPackages`.

### 3.8 Otras divergencias

| Tema | Spec | Código |
| --- | --- | --- |
| Contest-open invoice | Momento cerrado | **Hecho:** reputación oficial no-cero, una vez, opener paga. Core-only gratis. Drift → 0 |
| Compose rampa → `activate` | `RAMPS.md` lo permite | Solo taxi |
| `credits` del pool | Bucket de tesorería | Campo muerto |
| `CLAIMED` vs `RELEASED` | Outcome distinto | **Hecho:** `Status.CLAIMED` (10) |
| Stalemate 50/50 | Exacto | `pot/2` al Provider; el wei impar al Holder (pot = principal − completion) |
| Reloj `duration >= 0`, sin máximo | Riesgo de las partes | `origin + duration` overflow (0.8) **revierte** el timeout |
| UI en deal ZK | Proof o timeout | Ofrece `markFiat` / `claim` / `openDisputed` (`EdgeOff`) |

---

## 4. Seguridad

**Alto**

1. Swap del módulo ZK: el path `FUNDED → RELEASED` deja de ser “solo V”.
2. `PassportMock` + `BondVault` en el stack que se despliega. Identity no es trustless.
3. `invoice*` desacoplado del hash. Un módulo permissionless puede mentir el amount.
4. Completion/ZK fee > leftover revierte el terminal (KERNEL-04).

**Medio**

5. `admit` re-identifica (peers no bindeados). Ítem 1 ya no aplica a `notify`.
6. `disposeBond` fail-open + `safeTransfer` en slash/burn. Si el ganador rechaza el ERC-20, el lock queda para siempre.
7. `Settlement.withdraw` transfiere y después pone el crédito en 0. El Escrow tiene `nonReentrant`. `Pool.withdrawCredit` no.
8. `ArbitrationMock` griefing / ruling público si se usa como court real.
9. Pool: approve max + pull extra de fees no reservados.

**Bajo**

10. Core no valida `token != 0`, `holder != 0`, ni `controller != provider`.
11. `BondVault.deposit` a cualquier `subject` es un gift; el riesgo es el Passport.
12. Libraries `public` por DELEGATECALL; llamarlas en su address no mueve fondos del escrow.

El recinto Core (firmas, nonce atómico, pull exacto, credit-first del principal, timeouts permissionless, ZK apaga `DISPUTED`) está bien planteado. El riesgo está en la superficie de extensión y en los mocks tratados como producto.

---

## 5. Performance

- `Deal` guarda `DealTerms` entero, incluido `packageIds[]`. Cada `activate` es un bloque de `SSTORE`s.
- `decimals()` en cada `admit`/`score`. Un token sin `decimals` rompe el cap.
- `Pool._unique` es O(n²). Irrelevante si la lista es chica.
- `_requireNamed` / `_named` lineales. n ≤ 5; OK.
- Fee de activación: `safeTransfer` síncrono. Completion es credit-first.
- `forceApprove(max)` en cada `authorize` del pool.

---

## 6. Qué está bien

- Sin paquetes se activa, se cancela, se marca fiat, se releasea, se claim, se disputa y se fuerza stalemate.
- El relayer no elige destinos. Holder-gross / Provider-gross = addresses de firma.
- Nonces no se consumen si el pull falla.
- EP-POST (`runPostTerminal`) no deshace el escrow. Un fallo queda en `Deal.postPending` y `retryPostTerminal` lo reintenta.
- ZK y Arb son incompatibles; Rep exige Passport; Bonds exige los dos.
- Drift: `verifyProof`/`openCourt` reject; completion y bonds fail-open.
- Pool y rampa no añaden estados al kernel.

---

## 7. Orden de trabajo

1. **`IEscrow` en Core** — terms/clocks/settlement/subjects/modules/kinds. Pool deja de copiar la interfaz. `notifyTerminal` recibe el sujeto snapshotado. **Hecho.**
2. Binding de peers en `activate`: mismo Passport para Rep y Vault; `packageId` de ZK con address del módulo; invoice amount = valor hasheado. **Hecho.**
3. `_takeCompletionFrom` no puede revertir el terminal (`fee > left` → se omite el fee). **Hecho.** `claim` cobra completion y cierra en `CLAIMED`. **Hecho.**
4. Sacar mocks del path “oficial” (Passport writable, court con `submitRuling` público, verifier que decodifica bytes). **Passport hecho:** `HumanPassport` sobre el decoder de Human Passport; `PassportPicker` lo elige en Arbitrum One o con `PASSPORT_DECODER`. `PassportMock` queda sólo para Sepolia/local. **Court hecho (2026-09-13):** `KlerosAdapter` parametrizado por chain (`KlerosConfig`: core, registry, `extraData`, `KLEROS_POLICY_URI`); template KIP-99 válido para la Court UI (`policyURI`, chain/arbitrator reales, `caseOf` como mapping); PluriSwap sólo abre y recibe, la evidencia va por la dapp de Kleros. Pendiente externo: whitelist del adapter en el `KlerosCore` de Arbitrum One (gobernanza Kleros) y pinear `KLEROS_POLICY.md`. Verifier pendiente.
5. Pool: escribir `credits` (o dejar de anunciarlo); reservar `invoiceActivation`; approve exacto; `nonReentrant` en `withdrawCredit`/`reconcile`. **Hecho.**
6. Recorte de storage del `Deal` cuando toque tamaño/gas. **Superado:** `Packages` (librería externa) saca resolve/engage/invoice/`runPostTerminal` del kernel. Tras el retry path el Escrow queda en 16.1 KB con 8.4 KB de margen. Los cuatro `uint8` de retry (`closeH`/`closeP`/`bondAction`/`postPending`) caben en el slot de `pkgs`.
7. Decisiones de kernel (2026-09-12). **Hecho.**
   - Completion fee iff el Provider cobra algo, sobre el pot entero, antes del split. Refund nunca paga.
   - `Status.CLAIMED`: Provider Peaceful, Holder Silent, bonds unlock.
   - Bonds: slash siempre al ganador (address de firma). Tribunal rehúsa → unlock + stalemate en el score. Arbitration timeout → unlock, silencio. Sólo el stalemate de `DISPUTED` quema.
   - `Terms.hashTerms` rechaza roles/token en cero y `controller == provider`. Zero-checks en `Reputation`, `BondVault`, `KlerosAdapter` (que además pierde el modo standalone), `StargateV2Ramp`. Eventos en `BondVault` y `cancelNonce`.
