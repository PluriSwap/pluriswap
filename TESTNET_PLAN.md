# Plan de implementación — testnet productiva

Objetivo: un escrow Core usable en **Arbitrum Sepolia**, con deals reales entre dos wallets, sin paquetes. Los paquetes, rampas y pools entran después, enganchados al mismo kernel.

Chain: Arbitrum Sepolia (`421614`). Token de prueba: **ERC-20 propia** (mintable, 6 decimals como USDC). No Circle, no faucet, no rampa. El sink de quema de bonds, cuando exista, es un address inmutable nuestro — no el de Circle.

Circle USDC (`0x75faf114…AA4d`) es un pase de integración después, no el camino de desarrollo. Gas: ETH de Sepolia.

El recorte de protocolo y el encoding EIP-712 (`ENCODING.md`) alcanzan para codear Core. Paquetes, rampas y pools no bloquean el primer deploy.

Fuentes: `STATE_MACHINE.md`, `IMPLEMENTATION.md`, `PACKAGES.md`, `PROTECTION.md`, `RAMPS.md`, `POOLS.md`.

---

## Listo vs no

| Capa | ¿Se puede codear? | Nota |
| --- | --- | --- |
| Core (activar, fiat, release, cancel, timeout, split, `DISPUTED` → stalemate) | Sí | Tras freeze de typed data |
| Custodia / créditos / libraries + OZ | Sí | `IMPLEMENTATION.md` |
| Relojes, destinos Holder/Provider | Sí | Mínimo 0; payout = address de firma |
| BondVault + Passport + reputación | Después | Exigen sujeto; Human Passport testnet hay que pinnear |
| ZK | Después | Verifier V + `dealId` + `paymentNullifier`; sin V no hay paquete |
| Arbitraje | Después | Adapter mock que devuelve la terna; solo Controller abre |
| Stargate | Después | Composer; Core no lo necesita. Testnet de Stargate es flaky |
| Pools | Después | Holder-contrato + EIP-1271; el typed data ya es el mismo |

Mandatory Core no pide Passport, bonds, ZK, arb, rampa ni pool. Un Holder y un Provider en Sepolia tienen que poder cerrar un deal de punta a punta. Ese es el listón de “productivo” en testnet.

---

## Fase 0 — Freeze de encoding (bloquea el resto)

Un archivo `ENCODING.md` (o el header de `src/libraries/Terms.sol`) con:

- Domain EIP-712: `name`, `version`, `chainId`, `verifyingContract`.
- `HolderAuthorization`: `termsHash`, Holder, Controller, Provider, token, principal, nonce, expiry.
- Firma del Provider sobre el mismo `termsHash`.
- `ControllerAcceptance` si `Holder ≠ Controller`.
- Preimage de `termsHash`: roles, token, principal, clocks (fiat / release / dispute / creation expiry), `packageId[]` (vacío en Core-only).
- Dual-sign: cancel, split (`bps`), co-signed release — expiry del payload.
- `dealId` = hash determinístico del deal activado (para ZK después).

Sin esto no hay tests de firma. No se reabre economía.

---

## Fase 1 — Repo Foundry + Core

Stack: Foundry, Solidity 0.8.24+, `@openzeppelin/contracts` v5, `ReentrancyGuardTransient`, `SignatureChecker`, `EIP712`, `SafeERC20`.

```
src/Escrow.sol
src/libraries/{Consent,Terms,Machine,Settlement,Clocks}.sol
test/core/*.t.sol
script/Deploy.s.sol
```

Entrypoints Core (nombres a fijar en encoding):

- `activate` — CASE-CORE-01
- `markFiat` — 02
- `cancelByProvider` — 03
- `timeoutFiat` — 04
- `release` — 06
- `claim` — 07
- `openDisputed` — 11
- `forceStalemate` — 15
- `relayDualSign` — 05 / 08 / 09 / 10 / 12 / 13 / 14
- `withdraw` — crédito maduro

Tests anvil (mínimo para llamar productiva):

1. P2P `Holder == Controller`: activate → markFiat → release. Principal al Provider.
2. Activate → cancel Provider. Principal al Holder.
3. Activate → timeout fiat. Principal al Holder.
4. markFiat → claim tras release duration 0 o corta.
5. markFiat → `DISPUTED` → split dual-sign.
6. `DISPUTED` → stalemate 50/50.
7. Deal ZK-off: Controller no puede release tras `DISPUTED`.
8. Pull incompleto / fee-on-transfer mock: no hay deal, nonce intacto.
9. `Holder ≠ Controller`: sin `ControllerAcceptance` rechaza; con ella, Holder no opera después.
10. Credit-first: receiver que revierte el `transfer` → terminal igual, `withdraw` después.

El token de estos tests es un `ERC20` mintable (OZ). Un segundo mock fee-on-transfer para el caso 8. No se usa Circle en anvil.

---

## Fase 2 — Deploy testnet

1. `forge script` a Arbitrum Sepolia: mintable ERC-20 (6 decimals) + Escrow. Verificar en Arbiscan.
2. Mint a dos EOAs. Approve + activate de un deal chico.
3. Recorrer a mano: happy path, cancel, un timeout, un stalemate.
4. Script `script/Deal.s.sol` que arme el typed data y mande las txs (sin frontend).

Éxito: un deal `RELEASED` y uno `CANCELLED` visibles on-chain, créditos withdrawable, bytecode del escrow bajo 24 KB (o libraries linkeadas).

No se cobra fee. `packageId[]` vacío. Circle USDC queda para un script de integración aparte, cuando el Core ya cierra con el token propio.

---

## Fase 3 — Paquetes (opt-in, mismo escrow)

Orden:

1. **BondVault** — depósito, lock 10%, unlock / slash a address de firma del ganador / quema. Tests sin Passport: sujeto = address mientras no haya Passport; en producción el sujeto es el nullifier. Mejor: no activar BONDS hasta tener Passport.
2. **Passport + reputación** — pinnear el contrato de Human Passport en Sepolia (o un mock 1271/attester de testnet). `identify` → `admit` → `invoice` (fee 0 en testnet oficial si hace falta). Caps T1. `notifyTerminal` no revierte el escrow.
3. **Arbitraje mock** — adapter que el Controller abre y que `readRuling` mapea a la terna. Court fee desde la wallet del Controller. Timeout → stalemate + quema de bonds si están.
4. **ZK** — solo cuando exista V. Hasta entonces el perfil no se selecciona. El escrow ya apaga `DISPUTED` si el `packageId` ZK está en los términos: no desplegar un deal ZK sin V.

Cada paquete es otro contrato + `packageId` content-addressed. Fee testnet: 0 o recipient de tesorería de prueba. No es la DAO de mainnet.

---

## Fase 4 — Rampa y pool (después de Core estable)

- Composer Stargate (o CCTP testnet) delante de `activate`. Cero bps de protocolo. Si la rampa testnet no está, se documenta y se sigue con el ERC-20 propio ya en Sepolia.
- Pool mínimo: contrato Holder con EIP-1271 sobre el mismo digest + approve al escrow. Un deal pool-origin = el mismo `activate`.

---

## Fuera de este plan

- Frontend.
- Montos oficiales de fee / tesorería DAO.
- ETH como token (v1 de producto = stables; testnet = ERC-20 propia).
- Depender del faucet Circle para el primer deploy.
- Upgrade del escrow (deployment nuevo).
- Mainnet.

---

## Orden de trabajo

0. `ENCODING.md` + structs Solidity.
1. Libraries + `Escrow` + tests anvil del catálogo Core.
2. Deploy Sepolia + un deal manual.
3. BondVault + Passport/reputación cuando el attester de testnet esté pinneado.
4. Adapter de arb mock.
5. ZK y Stargate cuando haya V y rampa reales en Sepolia.

La fase 0–2 es el recinto productivo. 3–5 son opt-in sobre el mismo deployment de kernel (los `packageId` nuevos no mutan deals viejos).
