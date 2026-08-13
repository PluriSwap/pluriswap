# Paquetes opcionales

Fuente de la máquina: `STATE_MACHINE.md`. Acoplamiento kernel ↔ paquetes ↔ DAO: `PROTECTION.md`. Este archivo asienta fórmulas y reglas de cada paquete. No redefinen el grafo.

Todos son opt-in. Core-only no los necesita. El deal nombra **identidades de paquete** (hash inmutable). Amount, recipient y momento de cada fee viven en ese hash, no en un campo libre del deal. Si el fee fuera un parámetro del deal, se pondría a cero y se usaría el módulo gratis.

La DAO no es un paquete que factura. Es un recipient que los paquetes oficiales ponen en su preimage. Un clon con fee cero es otro hash, otro producto.

Las rampas de bridge (`RAMPS.md`) no son un paquete de esta lista: no hay `invoice`, no hay bps para la DAO. El usuario paga solo Stargate (o la otra rampa) y el gas.

---

## 1. Qué hace cada uno

| Paquete | Para qué | Punto en la máquina | Cobra | Dónde va el fee |
| --- | --- | --- | --- | --- |
| Human Passport | Raíz anti-Sybil: el sujeto de reputación es un humano, no una address | Admisión | No | — |
| Reputación | Capa de confianza: cap del principal y fee de acceso | Activación (cap + fee); post-terminal (score) | Sí, en activación | Lo que diga el paquete (oficial: DAO) |
| Bonds | Suben el cap, skin-in-the-game | Activación (reserva); terminal (suelta o slash) | No es un fee: es colateral | Slash: address de firma del ganador (Holder o Provider); **quema** en stalemate |
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

`used[paymentNullifier] = true` es del paquete ZK, no del Passport. El nullifier de humanidad es otra cosa: identifica al sujeto. Este identifica un receipt.

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

Si el paquete no declara completion fee, el fee es cero.

Timeout de `DISPUTED` sin abrir arbitraje: cualquiera, tras `disputeDeadline`, fuerza `STALEMATE`. Principal 50/50. Bonds, si hay, se queman. No es un veredicto; es el costo de no cerrar en paz a tiempo. El split dual-firmado es la salida pacífica *antes* de ese reloj.

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

Atómico con el commit Core (`disposeBond`):

| Terminal | Qué hace el vault con el lock de ese deal |
| --- | --- |
| Pacífico (release, split, ZK, cancel, fiat timeout, claim) | Unlock → vuelve a `available` |
| Culpable (arb win/loss) | Slash: lock del perdedor → address de firma del ganador (Holder o Provider). Unlock del ganador a su `available`. Nunca al Controller. |
| Stalemate | Quema el lock de **ambos** al sink inmutable |

Después del unlock, ese monto ya es `available`: se puede retirar o volver a lockear en otro deal. No hay cooldown extra: el slash/quema va en la misma tx que el terminal, no hay carrera contra un withdraw.

### 5.4 Qué no es

- No es un fee. No va a la DAO.
- No se mezcla con el principal. Un `CANCELLED` devuelve principal al Holder y, si fue pacífico, unlock del bond al vault.
- Core-only no usa el vault. Abrir `DISPUTED` en Core no exige lock.

---

## 6. Bonds: pacífico vs slash

Pacífico (los bonds se sueltan): release, dual-sign (incluido el split), proof ZK, cancel, fiat timeout, claim por silencio.

Slash:

| Terminal | Bonds |
| --- | --- |
| Adapter declara culpable (holder win / provider win) | Lock del perdedor a la address de firma del **ganador** (Holder o Provider de ese deal). El lock del ganador vuelve a su `available`. Nunca al Controller. Nunca a la DAO. |
| Stalemate — timeout de `DISPUTED` sin tribunal, ruling rehusado, o arbitration timeout | **Quema** de ambos bonds a un sink inmutable. No a la DAO. No a una parte. |

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
| Terminal con completion | Split u otro terminal donde el paquete cobre completion | Sobre el **principal completo**, deducido antes de partir. |

Timeout / cancel Holder-positivo: no hay fee extra. Lo de activación, si se cobró, ya se consumió.

Varios paquetes: cada uno cobra lo suyo. Si en activación no alcanza, no hay deal.

---

## 8. Invariantes

- El deal nombra paquetes; los paquetes nombran fees. No al revés.
- Core-only: cero fees de paquete.
- Humanidad no cobra; reputación sí, en activación, y raciona el size.
- ZK cobra al verificar, no al seleccionar. Un `paymentNullifier` liquida un deal; el `dealId` va en los public inputs.
- Split desde `DISPUTED` es pacífico; completion fee sobre el deal entero.
- Stalemate (timeout de `DISPUTED`, arb refused, arb timeout) quema bonds. El split antes del reloj es la salida pacífica.
- Slash con culpable: lock del perdedor a la address de firma del ganador (Holder o Provider). Nunca al Controller.
- La DAO cobra cuando usás **sus** paquetes, no cuando usás la idea de ZK o de reputación.

---

## 9. Passport, reputación y bonds

Van **juntos**. Sin Passport no hay sujeto, no hay score, no hay cap que suba. Core-only no mira reputación: el recinto sigue abierto, el tamaño no se raciona, el score no se mueve. Con el paquete, **Holder y Provider** tienen que pasar el cap: el deal no es más grande que lo que cada sujeto puede sostener.

### 9.1 Human Passport

No cobra. Identifica al **sujeto**. El score, el `inFlight` y el bond se keyean por el nullifier del Passport, no por la wallet. Varias wallets del mismo humano comparten cap y reputación.

Sin Passport vigente: este paquete rechaza la activación **y** no hay `notifyTerminal` de score. Una address nueva no fabrica un humano nuevo ni un historial. Eso es el anti-Sybil y el freno del cap: sin humanidad el máximo de los deals no sube.

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
| Cancel, fiat timeout, claim por silencio | nada | — |
| Stalemate (incl. timeout de `DISPUTED`) | nada | `+5` ambos |
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

