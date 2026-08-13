# Plan de implementación (TDD)

Objetivo: escrow **Core** en Foundry, anvil verde, **Arbitrum Sepolia** con ERC-20 mintable nuestra.

**Ley:** no hay código de producción sin un test que haya fallado primero por la razón correcta. Compilar no cuenta como rojo. Un stub que revierte sí: el test espera el outcome y falla.

Ciclo, un comportamiento por vez:

```
RED (un test) → ver que falla bien → GREEN (mínimo) → REFACTOR (sigue verde) → siguiente test
```

No implementar el catálogo entero y “después los tests”. Cada `CASE-CORE` es un ciclo. Si se escribió producción antes del test, se borra y se empieza por el test.

Encoding, economía y grafo **no se reabren**:

| Tema | Fuente |
| --- | --- |
| Estados, transiciones, outcomes | `STATE_MACHINE.md` |
| EIP-712, nonces, dual-sign, `dealId` | `ENCODING.md` |
| Libraries, OZ, custodia | `IMPLEMENTATION.md` |
| Paquetes (después de Core) | `PACKAGES.md`, `PROTECTION.md` |
| Pools / rampas (después) | `POOLS.md`, `RAMPS.md` |

---

## Stack

- Foundry, Solidity `0.8.28`, `evm_version = "cancun"`, `via_ir = true`
- OZ v5: `EIP712`, `SignatureChecker`, `SafeERC20`, `ReentrancyGuardTransient`
- Token: ERC-20 mintable, 6 decimals. No Circle
- Chain: Arbitrum Sepolia `421614`

No Hardhat. No `Pausable` / `Ownable` sobre settlement. No proxy.

---

## Layout

```
src/
  Escrow.sol
  TestToken.sol
  libraries/{Types,Consent,Terms,Clocks,Settlement,Machine}.sol
  mocks/{FeeOnTransferToken,RevertingReceiver,Mock1271}.sol
test/
  Base.t.sol                    // mint, approve, sign* helpers — nace con el primer test que lo necesite
  Consent.t.sol
  Terms.t.sol
  Settlement.t.sol
  Activate.t.sol
  HappyPath.t.sol
  Cancel.t.sol
  Timeouts.t.sol
  Claim.t.sol
  Dispute.t.sol
  DualSign.t.sol
  Nonce.t.sol
  CreditFirst.t.sol
  Roles.t.sol
script/
  Deploy.s.sol
  Deal.s.sol
```

`Escrow.sol` fino. Libraries `external`. `packageIds = []` en todo Core.

---

## Entrypoints (aparecen cuando el test los nombra)

| Función | Caso |
| --- | --- |
| `activate(...)` | CASE-CORE-01 |
| `markFiat(dealId)` | 02 |
| `cancelByProvider(dealId)` | 03 |
| `timeoutFiat(dealId)` | 04 |
| `release(dealId)` | 06 |
| `claim(dealId)` | 07 |
| `openDisputed(dealId)` | 11 |
| `forceStalemate(dealId)` | 15 |
| `relayMutualCancel(...)` | 05 / 08 / 12 |
| `relayCoSignedRelease(...)` | 10 / 13 |
| `relayMutualSplit(...)` | 09 / 14 |
| `withdraw(token)` | crédito |
| `cancelNonce(nonce)` | invalida `used[msg.sender][nonce]` |

---

## Fase 0 — Bootstrap (excepción TDD)

Config, no comportamiento: `forge init --force` (no pisa los `.md`), OZ v5, `foundry.toml`, remappings. Un `TestToken` mintable solo porque el primer test de settlement lo va a pedir — se agrega **con** ese test, no antes “por las dudas”.

**Hecho cuando:** `forge test` corre (aunque sea el test placeholder de forge, que se borra en el primer RED real).

---

## Fase 1 — Consentimiento EIP-712

Cada ítem: escribir el test → `forge test --match-test <nombre>` rojo → mínimo verde.

Archivo `test/Consent.t.sol` y `test/Terms.t.sol`.

| # | Test | Rojo correcto | Producción que nace |
| --- | --- | --- | --- |
| 1.1 | `test_hashTerms_stable` | hash ≠ valor esperado (typehash mal / no implementado) | `Types.sol` + `Terms.hashTerms` según `ENCODING.md` |
| 1.2 | `test_hashTerms_revertsIfPackageIdsUnsorted` | no revierte | check canónico |
| 1.3 | `test_hashTerms_revertsIfDuplicatePackageId` | no revierte | unique |
| 1.4 | `test_hashTerms_revertsIfHolderEqualsProvider` | no revierte | |
| 1.5 | `test_hashTerms_revertsIfPrincipalZero` | no revierte | |
| 1.6 | `test_holderAuthorization_eoaRecovers` | `SignatureChecker` false | `Consent` + domain `PluriSwap` / `1` |
| 1.7 | `test_providerAgreement_eoaRecovers` | false | mismo domain, type distinto |
| 1.8 | `test_controllerAcceptance_eoaRecovers` | false | |
| 1.9 | `test_holderAuthorization_1271MagicValue` | EOA path o false | `Mock1271` + `isValidSignatureNow` |
| 1.10 | `test_holderAuthorization_1271Rejects` | pasa cuando debería fallar | |
| 1.11 | `test_differentNonces_differentDigests` | digests iguales | nonce en el struct |
| 1.12 | `test_dealId_deterministic` | ≠ fórmula `ENCODING.md` §4.5 | `dealId(...)` puro |

**Hecho cuando:** los 12 verdes. Todavía no hay `activate`.

---

## Fase 2 — Pull y créditos (harness)

`test/Settlement.t.sol`. Harness mínimo (`SettlementHarness`) que expone pull/credit/withdraw. El Escrow real aún no.

| # | Test | Rojo correcto | Producción |
| --- | --- | --- | --- |
| 2.1 | `test_pullExact_movesPrincipal` | balance no cambia / revert | `TestToken` + `safeTransferFrom` + delta |
| 2.2 | `test_pullExact_revertsIfFeeOnTransfer` | el pull “pasa” con menos tokens | `FeeOnTransferToken`; no hay crédito |
| 2.3 | `test_creditThenTryPush_success` | tokens no llegan | `trySafeTransfer` |
| 2.4 | `test_creditThenTryPush_revertingReceiverKeepsCredit` | toda la tx revierte | credit-first: crédito queda |
| 2.5 | `test_withdraw_paysBeneficiary` | 0 transfer | `withdraw` |
| 2.6 | `test_withdraw_revertingKeepsCredit` | crédito se pierde o tx revierte el terminal | reintento |

**Hecho cuando:** 2.1–2.6 verdes. Fee-on-transfer y receiver que revierte cubiertos **antes** de `activate`.

---

## Fase 3 — Activación (CASE-CORE-01)

`test/Activate.t.sol`. Primer test que nombra `Escrow.activate`. Stub: `activate` revierte `not implemented` → el test espera `FUNDED` y falla (RED).

| # | Test | Caso |
| --- | --- | --- |
| 3.1 | `test_activate_p2p_fundedPullsExact` | P2P, `holder == controller`, pull, estado `FUNDED`, `dealId` |
| 3.2 | `test_activate_revertsIfHolderSigBad` | |
| 3.3 | `test_activate_revertsIfProviderSigBad` | |
| 3.4 | `test_activate_revertsIfMissingControllerAcceptance` | `holder != controller` |
| 3.5 | `test_activate_distinctController_cannotBeCalledByHolder` | Holder no `release` después (este assert puede esperar a 4.x si `release` aún no existe; si no existe, no se escribe 3.5 todavía) |
| 3.6 | `test_activate_revertsIfNonceReplay` | mismo nonce Holder |
| 3.7 | `test_activate_revertsIfProviderNonceReplay` | |
| 3.8 | `test_activate_failedPull_doesNotConsumeNonce` | fee-on-transfer: `used[holder][nonce]` sigue false |
| 3.9 | `test_activate_revertsIfDeadlinePassed` | `vm.warp` |
| 3.10 | `test_activate_twoConcurrentDealsDifferentNonces` | pool-shaped: mismo Holder, dos nonces |
| 3.11 | `test_cancelNonce_blocksActivate` | |
| 3.12 | `test_activate_revertsIfHolderEqualsProvider` | |

Tras 3.1 verde hay Escrow + used mapping + pull. El resto es un ciclo cada uno.

**Hecho cuando:** 3.1–3.12 verdes (3.5 se mueve a fase 4 si `release` no nació).

---

## Fase 4 — Camino feliz y cancel (02, 03, 06)

`test/HappyPath.t.sol`, `test/Cancel.t.sol`.

| # | Test | Caso |
| --- | --- | --- |
| 4.1 | `test_markFiat_onlyProvider` | no-Provider revierte; Provider → `FIAT_SENT` |
| 4.2 | `test_release_onlyController_paysProvider` | CASE-CORE-06; crédito/push al Provider |
| 4.3 | `test_release_revertsFromFunded` | sin markFiat |
| 4.4 | `test_cancelByProvider_fromFunded_paysHolder` | CASE-CORE-03 |
| 4.5 | `test_cancelByProvider_revertsAfterMarkFiat` | |
| 4.6 | `test_cancelByProvider_onlyProvider` | |
| 4.7 | `test_holderCannotRelease_whenDistinctController` | cierra 3.5 |

**Hecho cuando:** P2P activate → markFiat → release verde; cancel Provider verde.

---

## Fase 5 — Relojes (04, 07, 11 timing)

`test/Timeouts.t.sol`, `test/Claim.t.sol`. Durations 0 y `vm.warp`.

| # | Test | Caso |
| --- | --- | --- |
| 5.1 | `test_timeoutFiat_durationZero_eligibleImmediately` | CASE-CORE-04; principal al Holder |
| 5.2 | `test_timeoutFiat_beforeDeadlineReverts` | duration > 0, sin warp |
| 5.3 | `test_timeoutFiat_anyone` | no es el Holder |
| 5.4 | `test_timeoutFiat_racesMarkFiat_firstWins` | CASE-RACE-01 |
| 5.5 | `test_claim_afterReleaseDeadline` | CASE-CORE-07; duration 0 |
| 5.6 | `test_claim_beforeDeadlineReverts` | |
| 5.7 | `test_openDisputed_strictlyBeforeReleaseDeadline` | en el deadline: dispute revierte, claim pasa (CASE-RACE-03) |
| 5.8 | `test_claim_revertsIfNotFiatSent` | |

**Hecho cuando:** 5.1–5.8 verdes. `Clocks.sol` nació del primer timeout, no antes.

---

## Fase 6 — Disputa y stalemate (11, 15, 16)

`test/Dispute.t.sol`.

| # | Test | Caso |
| --- | --- | --- |
| 6.1 | `test_openDisputed_onlyController_fromFiatSent` | CASE-CORE-11 |
| 6.2 | `test_openDisputed_revertsFromFunded` | |
| 6.3 | `test_openDisputed_once` | segunda vez revierte |
| 6.4 | `test_release_revertsWhileDisputed` | CASE-CORE-16 |
| 6.5 | `test_claim_revertsWhileDisputed` | 16 |
| 6.6 | `test_forceStalemate_beforeDeadlineReverts` | |
| 6.7 | `test_forceStalemate_splitsFiftyFifty` | CASE-CORE-15; fee 0 |
| 6.8 | `test_forceStalemate_anyone` | |
| 6.9 | `test_terminal_rejectsFurtherStateChange` | CASE-CORE-17 |

**Hecho cuando:** 6.1–6.9 verdes.

---

## Fase 7 — Dual-sign EIP-712 (05, 08–10, 12–14)

`test/DualSign.t.sol`. Types de `ENCODING.md` §5. Dos copias: mismo `dealId` y `deadline`, nonce por party.

| # | Test | Caso |
| --- | --- | --- |
| 7.1 | `test_mutualCancel_fromFunded` | CASE-CORE-05; principal al Holder |
| 7.2 | `test_mutualCancel_fromFiatSent` | 08 |
| 7.3 | `test_mutualCancel_fromDisputed` | 12 |
| 7.4 | `test_mutualCancel_revertsIfDealIdMismatch` | |
| 7.5 | `test_mutualCancel_revertsIfDeadlineMismatch` | |
| 7.6 | `test_mutualCancel_revertsIfBadProviderSig` | |
| 7.7 | `test_mutualCancel_consumesNonces` | replay del mismo par revierte |
| 7.8 | `test_mutualCancel_revertsIfDeadlinePassed` | |
| 7.9 | `test_coSignedRelease_fromFiatSent_paysProvider` | 10 |
| 7.10 | `test_coSignedRelease_fromDisputed` | 13 |
| 7.11 | `test_mutualSplit_fromFiatSent` | 09; `providerBps` sobre principal (fee 0) |
| 7.12 | `test_mutualSplit_fromDisputed` | 14 |
| 7.13 | `test_mutualSplit_revertsIfBpsMismatch` | |
| 7.14 | `test_mutualSplit_10000_isNotCoSignedReleaseType` | type distinto; split 10000 sigue siendo split |
| 7.15 | `test_dualSign_anyoneCanRelay` | relayer ≠ parties |

**Hecho cuando:** 7.1–7.15 verdes.

---

## Fase 8 — Credit-first en el Escrow real

`test/CreditFirst.t.sol`. El harness de la fase 2 no basta: el **terminal** del Escrow no puede revertir por un `transfer` fallido.

| # | Test | Caso |
| --- | --- | --- |
| 8.1 | `test_release_toRevertingProvider_stillReleased` | Provider = `RevertingReceiver`; estado `RELEASED`; crédito > 0 |
| 8.2 | `test_withdraw_afterFailedPush` | el Provider retira después |
| 8.3 | `test_stalemate_partialPushFailure_keepsBothCredits` | un lado revierte el push |

**Hecho cuando:** 8.1–8.3 verdes.

---

## Fase 9 — Tamaño y Sepolia

1. `forge build --sizes`. Si `Escrow` > 24 KB, más `external` en libraries (test de tamaños no sustituye TDD de comportamiento).
2. `Deploy.s.sol` + `Deal.s.sol`. No es TDD: script. Los tests de fase 3–8 son la red de seguridad.
3. Sepolia: mintable + Escrow. Un `RELEASED` y un `CANCELLED` on-chain.
4. `deployments/sepolia.json` (addresses, no secrets).

**Hecho cuando:** anvil 3–8 verde + dos deals reales en Sepolia.

---

## Fase 10 — Paquetes (TDD igual, después)

No empieza hasta fase 9. Cada paquete: tests primero.

1. **BondVault** — `test_deposit`, `test_withdrawAvailable`, `test_withdrawLockedReverts`, `test_lockTenPercent`, `test_slashToWinnerSigningAddress`, `test_stalemateBurnsBoth`, `test_neverToController`.
2. **Passport + reputación** — juntos. `test_noPassport_noAdmit`, `test_t1Cap`, `test_notifyTerminal_doesNotRevertEscrow`.
3. **Arb mock** — `test_onlyControllerOpens`, `test_rulingTernary`, `test_timeoutStalemate`.
4. **ZK** — solo con V. `test_wrongDealIdReverts`, `test_paymentNullifierReplayReverts`.

`packageId` preimage se cierra con el primer paquete.

---

## Fase 11 — Rampa y pool

Después. Tests: `test_pool1271_activateSameTypedData`, composer de rampa cuando exista (cero bps).

---

## Fuera

Frontend, fees DAO, Circle USDC (después de 9), ETH, mainnet, upgrade del escrow.

---

## Orden

```
0 bootstrap
1 Consent/Terms          (tests 1.1–1.12)
2 Settlement harness     (2.1–2.6)
3 activate               (3.1–3.12)
4 markFiat / release / cancelProvider
5 clocks / claim / race
6 DISPUTED / stalemate
7 dual-sign EIP-712
8 credit-first en Escrow
9 sizes + Sepolia
10 paquetes
11 rampa / pool
```

Un test rojo por vez. `forge test --match-test test_<nombre>` en cada ciclo.
