# Paquetes opcionales

Fuente de la máquina: `STATE_MACHINE.md`. Capas y resolución de `packageId`: `ARCHITECTURE.md`. Acoplamiento kernel ↔ paquetes ↔ DAO: `PROTECTION.md`. Este archivo asienta fórmulas y reglas de cada paquete. No redefinen el grafo ni el binding.

Todos son opt-in. Core-only no los necesita. El deal nombra **identidades de paquete** (hash inmutable). Amount, recipient y momento de cada fee viven en ese hash, no en un campo libre del deal. Si el fee fuera un parámetro del deal, se pondría a cero y se usaría el módulo gratis.

La DAO no es un paquete que factura. Es un recipient que *un* paquete pone en su preimage. Un clon con fee cero es otro hash, otro producto. Las partes lo firman y el mismo escrow lo resuelve (`ARCHITECTURE.md` §5). “Oficial” es un producto (frontend, JSON), no un gate del kernel.

Las rampas de bridge (`RAMPS.md`) no son un paquete de esta lista: no hay `invoice`, no hay bps para la DAO. El usuario paga solo Stargate (o la otra rampa) y el gas.

---

## 1. Qué hace cada uno

| Paquete | Para qué | Punto en la máquina | Cobra | Dónde va el fee |
| --- | --- | --- | --- | --- |
| Human Passport | Raíz anti-Sybil: sólo wallets con Passport vigente entran al recinto con paquetes | Admisión | No | — |
| Reputación | Capa de confianza: cap del principal y fee de acceso | Activación (cap + fee); post-terminal (score) | Sí, en activación | Lo que diga el paquete (oficial: DAO) |
| Bonds | Suben el cap, skin-in-the-game | Activación (reserva); terminal (suelta o slash) | No es un fee: es colateral | Slash: address de firma del ganador (Holder o Provider); **quema** sólo en el stalemate que las partes dejaron vencer |
| ZK / payment proof | Auto-release autenticado; apaga `DISPUTED` | Arista `FUNDED` → `RELEASED` | Sí, **al verificar** | Lo que diga el paquete (oficial: DAO) |
| Arbitraje | Tribunal cuando no hay ZK | `FIAT_SENT` / `DISPUTED` → `ARBITRATION_ACTIVE` | Court fee al abrir, de la wallet del opener | Tribunal; el paquete puede sumar contest-open a la DAO |
| DAO | Recipient | — | No cobra por sí | — |

---

## 2. Orden en activación

Si esos paquetes están seleccionados:

1. Passport identifica al sujeto (sin fee).
2. Reputación calcula `cap(score, bond)` y cobra su fee de activación. Si `principal > cap`, no hay deal.
3. Bonds lockean en el vault (suben el cap en el paso 2).
4. ZK no cobra todavía.
5. Pull exacto del principal → `FUNDED`.

Sin estos paquetes: sin cap, sin fee de reputación, sin Passport. El recinto Core sigue abierto.

---

## 3. ZK: proof o timeout

El deal firmó el verifier V. Solo V. Otro proof se ignora.

Ese escrow **no entra a `DISPUTED`**. Tampoco claim ni release unilateral. Salidas:

- Proof de V → `RELEASED`. Ahí cobra el paquete ZK (verificación).
- `fiatDeadline` / cancel Provider / mutual cancel → `CANCELLED`. No hubo verificación: no hay fee ZK.

Si el timeout corre y el Controller (o cualquiera) ejecuta la cancelación, el principal vuelve al Holder. Es el comportamiento esperado. Las partes acordaron V y una no cumplió. No hay otro camino.

### 3.1 Un proof, un deal

No se reusa. Dos amarres, los dos en la misma tx que `verifyProof`:

1. **`dealId` en los public inputs.** V verifica un proof para *este* escrow. Las mismas bytes en otro deal fallan: el `dealId` no matchea.
2. **`paymentNullifier` gastado.** V devuelve un id del pago fiat (rail + receipt, o el nullifier del circuito). El paquete lo marca usado. Un segundo proof, aunque tenga otro `dealId`, no puede liquidar el mismo pago.

`used[paymentNullifier] = true` es del paquete ZK, no del Passport. Passport responde si una wallet es humana; este nullifier identifica un receipt de pago.

Si el nullifier ya está gastado, o el `dealId` no es el del escrow, `verifyProof` rechaza y el deal no cambia. Autenticación, consumo, `RELEASED` y fee ZK commit o revert juntos.

---

## 4. Disputa sin ZK

`DISPUTED` existe en el kernel. Se usa cuando el deal **no** seleccionó ZK: el Controller congela un claim no autenticado.

Desde `DISPUTED` se puede, en paz:

- Mutual cancel → todo el principal al Holder.
- Co-signed release → todo al Provider.
- **Split** → una parte del principal al Holder, el resto al Provider, según bps del payload.

El split no es un veredicto. Es un acuerdo parcial.

**Completion fee en el split.** Se calcula sobre el **principal completo del deal**, no sobre la tajada del Provider. Se deduce primero; después se aplican los bps al resto.

Ejemplo: principal 1000, fee de paquete 10, split 30% Provider → fee 10, restan 990 → Provider 297, Holder 693. Un split 1% no reduce el fee a 0,1.

Si el paquete no declara completion fee, el fee es cero. Si el fee declarado no cabe en el leftover (`fee >= left`, igualdad incluida), el kernel lo omite y el ganador conserva todo el pot: el outcome Core se commitea igual. Un fee igual al principal no se cobra, porque cobrarlo dejaría en cero a la parte que acaba de ganar.

Timeout de `DISPUTED` sin abrir arbitraje: cualquiera, tras `disputeDeadline`, fuerza `STALEMATE`. Principal 50/50. Bonds, si hay, se queman. No es un veredicto; es el costo de no cerrar en paz a tiempo. El split dual-firmado es la salida pacífica *antes* de ese reloj.

### 4.1 Tribunal: Kleros V2

El tribunal oficial es `KlerosAdapter` sobre Kleros V2 (Arbitrum). PluriSwap toca a Kleros **dos veces** por deal y nada más:

1. **Abrir.** El Controller llama `Escrow.openCourt{value: arbitrationCost}(dealId)` desde `FIAT_SENT` o `DISPUTED`. El kernel valida estado, reloj y rol, y sólo él llama `KlerosAdapter.openCourt`: `createDispute` en `KlerosCore` (2 opciones) y evento `DisputeRequest` con `externalDisputeID = uint256(dealId)` y el `templateId` registrado.
2. **Recibir.** Cuando los jurados votan y se agotan las apelaciones, `KlerosCore` llama `KlerosAdapter.rule(disputeId, ruling)`. El adapter guarda 0 → 3 (rehúsa), 1 → Holder, 2 → Provider. Cualquiera llama `Escrow.readRuling(dealId)` y el kernel cierra.

**La evidencia no pasa por PluriSwap.** Las partes la suben en la Court dapp de Kleros, en el caso que abrió el paso 1; el dapp la liga al caso por el `externalDisputeID` del evento. Apelaciones, votos y períodos son de Kleros. Si el tribunal nunca contesta, `arbitrationDuration` del deal permite cerrar por timeout (unlock, silencio).

**Lo que ve el jurado.** El adapter registra al construirse un *dispute template* (KIP-99) en el `DisputeTemplateRegistry` de la chain: título, pregunta, las tres respuestas, `arbitratorChainID`/`arbitratorAddress` de esa chain y `policyURI` (obligatorio; sin él la Court UI no renderiza el caso). El template lleva placeholders que el dapp llena con **una** llamada `abi/call` a `KlerosAdapter.caseOf(externalDisputeID)`: `dealId`, Holder, Provider, token y monto legible (`"1250.5 USDC"`), leídos de `IEscrow.terms`. Los alias `Holder`/`Provider` etiquetan la evidencia que sube cada parte. La política que leen los jurados está en `KLEROS_POLICY.md`: se pinea en IPFS y su multiaddr es `KLEROS_POLICY_URI`.

**Direcciones y parámetros.** `script/KlerosConfig.s.sol` fija por chain el `KlerosCore` y el `DisputeTemplateRegistry` (Arbitrum One `0x991d…22ea` / `0x0cFB…a5A2`; Arbitrum Sepolia `0xE844…3479` / `0xe763…ebcb`) y admite override por env: `KLEROS_CORE`, `KLEROS_TEMPLATE_REGISTRY`, `KLEROS_COURT` (1), `KLEROS_JURORS` (3), `KLEROS_DISPUTE_KIT` (1, Classic), `KLEROS_POLICY_URI`. Otra corte u otro `extraData` es otro adapter y otro `packageId`: la firma de las partes fija ante qué tribunal van.

**Whitelist en Arbitrum One.** El `KlerosCore` de mainnet sólo acepta `createDispute` de arbitrables listados por la gobernanza de Kleros (`ArbitrableNotWhitelisted()` si no). El deploy registra el template igual y loguea el estado; hasta que Kleros liste la address del adapter, `openCourt` revierte y el paquete ARB no es usable en mainnet. Sepolia no tiene whitelist. `test/fork/KlerosAdapter.fork.t.sol` fija ambos hechos contra las chains reales.

**Compatibilidad.** El evento `DisputeRequest` en producción tiene cinco argumentos (subgraph `master`); la rama `dev` de Kleros lo reduce a tres y deja de usar `externalDisputeID`. El adapter emite ambas formas, así el mismo adapter (y su whitelist) sobrevive a la actualización.

---

## 5. Bonds: vault global y locks

El bond **no** vive en el escrow del deal. El principal del deal y el colateral son custodia distinta. Mezclarlos dejaría el slash/quema dentro del kernel y permitiría retirar skin que cubre deals vivos.

### 5.1 Dónde está

Un **BondVault** del paquete BONDS, keyeado por sujeto Passport y token. No es el kernel, no es la DAO, no es el Holder del deal.

```
deposited[sujeto]   // total depositado
locked[sujeto]      // suma de locks de deals activos
available           = deposited - locked
```

Depósito cuando quiera. Withdraw **solo** de `available`. Un withdraw que coma `locked` rechaza.

### 5.2 Lock por deal

Al activar, el vault traba un lock `dealId → amount` contra ese sujeto:

```
lockAmount * 10 >= principal     // 10% de este deal
locked' = locked + lockAmount
available' >= 0                  // si no, no hay deal
```

La suma de locks es el 10% del `inFlight`. Por eso “bond global + 10% del total que quiere activar”: un depósito grande cubre muchos deals; cada deal nuevo solo traba su tajada.

Ese lock dura **hasta el terminal de ese deal**. Los relojes del escrow (fiat, release, dispute, arb) son los que lo sueltan. No hay un withdraw paralelo. No hay un admin que lo libere.

### 5.3 Terminal

Atómico con el commit Core (`Packages.runPostTerminal`):

| Terminal | Qué hace el vault con el lock de ese deal |
| --- | --- |
| Pacífico (release, split, ZK, cancel, fiat timeout, claim) | Unlock → vuelve a `available` |
| Culpable (arb win/loss) | Slash: lock del perdedor → address de firma del ganador (Holder o Provider). Unlock del ganador a su `available`. |
| Sin veredicto (tribunal rehúsa, arbitration timeout) | Unlock de ambos: sin culpa probada no se mueve dinero |
| Stalemate de `DISPUTED` (nadie co-firmó ni fue a tribunal) | Quema el lock de **ambos** al sink inmutable |

Después del unlock, ese monto ya es `available`: se puede retirar o volver a lockear en otro deal. No hay cooldown extra: el slash/quema va en la misma tx que el terminal, no hay carrera contra un withdraw.

### 5.4 Qué no es

- No es un fee. No va a la DAO.
- No se mezcla con el principal. Un `CANCELLED` devuelve principal al Holder y, si fue pacífico, unlock del bond al vault.
- Core-only no usa el vault. Abrir `DISPUTED` en Core no exige lock.

---

## 6. Bonds: pacífico vs slash

Pacífico (los bonds se sueltan): release, dual-sign (incluido el split), proof ZK, cancel, fiat timeout, claim por silencio.

Principio: **el dinero sólo se mueve con culpa probada o con negativa probada a resolver.** El score registra el resto.

| Terminal | Bonds |
| --- | --- |
| Adapter declara culpable (holder win / provider win) | Lock del perdedor a la address de firma del **ganador** (Holder o Provider de ese deal). El lock del ganador vuelve a su `available`. Es compensación a la parte dañada; nunca a la DAO. Si el Holder es su propio Controller, cobra como Holder. |
| Tribunal rehúsa decidir (ruling 0 de Kleros → 3) | Unlock de ambos. Sin culpa probada no hay castigo monetario. Ambos scores registran el stalemate (+5). |
| Arbitration timeout (el tribunal nunca contestó) | Unlock de ambos, scores en silencio: la falla es del tribunal, no de las partes. |
| Stalemate — timeout de `DISPUTED` sin co-firma ni tribunal | **Quema** de ambos bonds a un sink inmutable. No a la DAO. No a una parte. Las dos partes tenían salida (split, co-firma, tribunal) y ninguna la tomó. |

El timeout de `DISPUTED` **es** stalemate. Cualquiera lo ejecuta. Si el slash en empate fuera al counterparty, conviene forzar el reloj para cazar el bond ajeno. La quema cierra eso.

En un deal ZK no hay tribunal: el bond sirvió para subir el cap y se devuelve al terminal.

Un split puede slashear de más solo si **las dos partes lo firman** en el payload. Eso es acuerdo, no culpa de protocolo.

---

## 7. Momentos de fee que el kernel conoce

Lista cerrada. Un paquete no inventa un cuarto momento.

| Momento | Cuándo | De dónde |
| --- | --- | --- |
| Activación | Al entrar a `FUNDED` | Extra al principal (Holder). Reputación usa este. |
| Abrir contest | Al abrir `DISPUTED` o arbitraje | Wallet del opener. Muerto en deals ZK. |
| Al verificar | Proof ZK → `RELEASED` | Lo declara el paquete ZK. |
| Terminal con completion | **Cualquier terminal donde la tajada del Provider sea > 0**: release, co-firma, split, claim, ZK, arb win del Provider, stalemate 50/50 | Sobre el **pot completo**, deducido antes de partir. La operación ocurrió; el fee es el mismo sin importar cómo cerró. |

Refund al Holder (cancel, fiat timeout, split que deja al Provider en cero, arb win del Holder): no hay completion fee. No hubo operación. Lo de activación, si se cobró, ya se consumió.

Varios paquetes: cada uno cobra lo suyo. Si en activación no alcanza, no hay deal. En el terminal, si verify/completion no cabe en el leftover (`fee >= left`), ese fee se omite; el escrow no revierte.

---

## 8. Invariantes

- El deal nombra paquetes; los paquetes nombran fees. No al revés.
- Core-only: cero fees de paquete.
- Humanidad no cobra; reputación sí, en activación, y raciona el size.
- ZK cobra al verificar, no al seleccionar. Un `paymentNullifier` liquida un deal; el `dealId` va en los public inputs.
- Completion fee si y sólo si el Provider cobra algo; sobre el pot entero, antes del split. Un refund nunca la paga.
- `CLAIMED` es terminal propio: el Provider cerró la operación (Peaceful), el Controller ausente no es culpa probada (Silent).
- Stalemate de `DISPUTED` (nadie resolvió) quema bonds. Tribunal que rehúsa o no contesta: bonds de vuelta. El split antes del reloj es la salida pacífica.
- Slash con culpable: lock del perdedor a la address de firma del ganador (Holder o Provider). Compensa a la parte dañada.
- La DAO cobra cuando usás **sus** paquetes, no cuando usás la idea de ZK o de reputación.

---

## 9. Passport, reputación y bonds

Van **juntos**. Sin Passport no hay sujeto, no hay score, no hay cap que suba. Core-only no mira reputación: el recinto sigue abierto, el tamaño no se raciona, el score no se mueve. Con el paquete, **Holder y Provider** tienen que pasar el cap: el deal no es más grande que lo que cada sujeto puede sostener.

### 9.1 Human Passport

No cobra. Identifica al **sujeto**. El adapter oficial es `HumanPassport` sobre el `GitcoinPassportDecoder` de Human Passport (ex Gitcoin Passport; Arbitrum One `0x2050256A91cbABD7C42465aA0d5325115C1dEB43`). El decoder puntúa **addresses**, no humanos: el sujeto es la wallet con Passport vigente (`bytes32(uint160(wallet))`). Score, `inFlight` y bond se keyean por esa wallet. Una segunda wallet del mismo humano es otro sujeto, sin historial.

La anti-Sybil es la de Passport: un stamp cuenta para una sola address a la vez (deduplicación), así que dos wallets sólo son "humanas" a la vez con dos juegos de stamps disjuntos. `isHuman` del decoder es `score >= threshold` (4 decimales, 20.0 = `200000`); el adapter puede fijar su propio `minScore` inmutable. Umbral, decoder y adapter quedan bindeados por `PackageId.passport(adapter)`: otro decoder u otro umbral es otro adapter, otro id, otra firma.

El decoder revierte cuando no hay attestation o expiró (stamps a 90 días, `maxScoreAge`), y es un proxy upgradeable y pausable del equipo de Passport. El adapter traduce cualquier revert a `NoPassport`: la admisión falla cerrada y el kernel no quema nonce. Dependencia de liveness declarada: `BondVault.withdraw` exige `identify` vigente, así que un Passport vencido deja el bond estacionado hasta re-verificar la misma wallet. No es pérdida; es una re-verificación.

En Arbitrum Sepolia y local no hay decoder: los scripts despliegan `PassportMock` (herramienta de laboratorio, `setHuman` sin auth) o, con `PASSPORT_DECODER`, un `HumanPassport` sobre `PassportDecoderMock` (escribible sólo por el deployer).

Sin Passport vigente: este paquete rechaza la activación. En el terminal, `notifyTerminal` usa el sujeto que el kernel snapshotteó en `IEscrow.subjects` — no vuelve a `identify`. Un remap o revoke de Passport no deja `inFlight` huérfano ni fabrica otro humano. Una address nueva no fabrica un historial. Eso es el anti-Sybil y el freno del cap: sin humanidad el máximo de los deals no sube.

Humanidad no mueve principal, no suelta escrow, no cambia un deal vivo (ADM-05). El Holder snapshotado no se reemplaza porque el Passport apunte a otra wallet.

### 9.2 Tiers

Caps en unidades enteras del token de settlement. Concurrentes: `inFlight + principal` no puede superar el cap. Lifetime volume no es el cap; el cap es exposición **en vuelo**.

| Tier | Score mínimo | Cap base | Cap con bond (≥ 10% del in-flight) |
| --- | ---: | ---: | ---: |
| T1 | 0 | 250 | 400 |
| T2 | 10 | 500 | 700 |
| T3 | 25 | 1_000 | 1_500 |
| T4 | 50 | 2_000 | 5_000 |
| T5 | 100 | sin límite | sin límite |

T5 no usa bond para el cap. El bond sigue sirviendo como skin si el paquete BONDS está seleccionado.

### 9.3 Bond del 10%

El colateral es el vault global (`PACKAGES.md` §5). Para usar la columna “con bond”, tras el lock de este deal:

```
locked * 10 >= inFlight + principal
```

Sin división. Cada deal traba `lockAmount * 10 >= principal` de ese deal. La suma cubre el 10% del total en vuelo. Si ya tiene 300 en vuelo (30 locked) y pide 100 más, traba 10: `locked = 40`. El resto de `deposited` sigue `available` y se puede retirar.

Si `available` no alcanza para el lock, no hay deal (o se usa el cap base si no se pidió la columna con bond). Si `principal` (más in-flight) supera también el cap con bond, reject.

Cada lado se evalúa solo. Un Provider T5 no obliga al Holder T1 a un deal de 2000.

### 9.4 Score — computable en Solidity

Tres enteros por sujeto. Sin loops, sin log, sin decaimiento. El score se calcula en un `view`; no se guarda.

```
successCount  uint32    // deals cerrados en paz
volume        uint256   // suma de principales de esos deals (unidades nativas)
penalty       uint32    // puntos de stalemate / pérdida
```

```
UNIT  = 250 * 10^decimals     // un “lote” = cap T1
score = satSub(successCount + volume / UNIT, penalty)
```

`satSub(a,b) = a > b ? a - b : 0`.

Tier: el mayor cuyo umbral es `<= score` (tabla 9.2). Cinco comparaciones.

Por qué `UNIT = 250`: un deal al tope de T1 suma `+1` de count y `+1` de volumen. Cinco deals limpios de 250 → score 10 → T2. Subir de tamaño cuando el cap lo permite acelera el volumen; no se puede saltar a T5 con un solo trade porque T1 no deja poner 10_000.

**Qué suma** (los dos sujetos, el principal completo del deal):

| Terminal | Count / volume | Penalty |
| --- | --- | --- |
| Release (Controller, co-signed, ZK) | `+1` y `+principal` | — |
| Split dual-firmado | `+1` y `+principal` | — |
| Claim por silencio | Provider: `+1` y `+principal`. Holder: nada | — |
| Cancel, fiat timeout | nada | — |
| Stalemate (timeout de `DISPUTED`, tribunal rehúsa) | nada | `+5` ambos |
| Arbitration timeout | nada | — (la falla es del tribunal) |
| Arb win | nada extra de volumen | — |
| Arb loss | nada | `+15` el perdedor |

Claim y cancel no fabrican reputación. Stalemate y pérdida bajan el score; no se borra el historial de volume.

En el terminal: a lo sumo tres `SSTORE` (count, volume, penalty) y se suelta `inFlight`. En activación: un `SSTORE` de `inFlight` y las comparaciones del cap. O(1).

### 9.5 Recorrido típico

Sujeto nuevo, Passport ok, score 0 → T1, cap 250 (400 si bindea 10%). Cinco releases de 250 → score 10 → T2. Deals más grandes, más `volume/UNIT`, T3/T4. T5 a score 100: del orden de 50 deals de 250, o menos si ya operaba en caps altos.

Un stalemate (penalty +5) puede devolverte de T2 a T1. El cap de deals **vivos** no se toca (ADM-05). El siguiente deal sí mira el score nuevo.

---

## 10. Invariantes de esta capa

- Passport y reputación viajan juntos. Sin Passport no hay score ni cap que suba.
- Passport keyea al sujeto; una wallet no es una identidad.
- El cap es concurrente (`inFlight`), no lifetime.
- Holder y Provider se chequean por separado; gana el más chico.
- Bond 10% desbloquea la columna alta; es el mismo skin que se quema en stalemate.
- El bond vive en el BondVault, no en el escrow. Withdraw solo de `available`; los locks de deals vivos no se tocan.
- Score = `count + volume/250 − penalty`, saturado en 0. O(1).
- Solo los cierres en paz suman count/volume. Claim y cancel no.
- Un deal vivo no se achica si el score baja. El siguiente sí.

