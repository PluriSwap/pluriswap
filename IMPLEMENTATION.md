# Implementación: libraries y dependencias

El recorte de protocolo no cambia: un escrow (máquina + caja), BondVault aparte, paquetes y rampas en otros contratos. Este archivo fija **cómo** se parte el bytecode y **qué** se reutiliza. Si hay conflicto sobre estados o economía, mandan `STATE_MACHINE.md` y `PACKAGES.md`.

---

## 1. Internal vs external

OpenZeppelin casi todo es `internal`: se **inlinea** en el contrato que lo usa. Sirve para no reescribir ECDSA ni `transferFrom`. **No** achica el blob. Puede agrandarlo.

Para el límite de ~24 KB hay que partir lógica **nuestra** en libraries con funciones `external` (DELEGATECALL, storage en el escrow) o en contratos ya acordados (BondVault, paquetes).

Desde el día uno:

| Capa | Visibilidad | Para qué |
| --- | --- | --- |
| OpenZeppelin | `internal` (la de ellos) | Crypto, ERC-20, reentrancy |
| Libraries de protocolo | `external` | Consentimiento, términos, catálogo, settlement, relojes |
| `Escrow.sol` | fino | Storage, entrypoints, `nonReentrant`, orquesta |

No se espera a que el compilador grite. El storage y quién mueve el token siguen en el escrow.

---

## 2. Mapa

```
Escrow.sol                 storage + entrypoints
  libraries/Consent.sol    HolderAuthorization, Provider, ControllerAcceptance
  libraries/Terms.sol      termsHash, snapshot
  libraries/Machine.sol    catálogo CASE-CORE / EP-EDGE, carreras
  libraries/Settlement.sol pull exacto, créditos, try-push, withdraw
  libraries/Clocks.sol     origin + duration (>= 0)

BondVault.sol              otro contrato (PACKAGES.md §5)
packages/*                 Passport, reputación, ZK, arb — contratos, no libraries del escrow
ramps/*                    composers; no Core
```

`Escrow` hereda el dominio EIP-712 y el guard de reentrancy. Llama a las libraries. No duplica math de settlement ni `ecrecover` a mano.

---

## 3. OpenZeppelin (v5)

Dependencia: `@openzeppelin/contracts` v5. No `upgradeable` para Core: el kernel es inmutable. Arbitrum tiene EIP-1153 → guard transiente.

| Usar | Dónde | Por qué |
| --- | --- | --- |
| `SignatureChecker.isValidSignatureNow` | Consent | Un solo path EOA (`ECDSA`) y contrato (EIP-1271). Es el borde Holder wallet / pool |
| `EIP712` + `MessageHashUtils` | Consent / dominio | Domain separator: chain, deployment, versión. Sin esto hay replay |
| `SafeERC20` | Settlement | `safeTransferFrom` en el pull. `trySafeTransfer` / `trySafeTransferFrom` en el push opcional (credit-first) |
| `IERC20` | Settlement | Balances para el delta exacto |
| `ReentrancyGuardTransient` | Escrow | Arbitrum. El `ReentrancyGuard` clásico queda para L1 sin transient; OZ lo depreca hacia v6 |

**No usar en Core** (rompen el recinto o no aplican):

| No | Por qué |
| --- | --- |
| `Pausable` | DEC-04: no hay freeze administrativo de una salida válida |
| `Ownable` / `AccessControl` como gate de settlement | PERM-01 / DEC-07. Admin, si existe, no toca deals vivos |
| `ERC20` mintable | El protocolo no emite el stable |
| `TransparentUpgradeableProxy` / UUPS en el escrow | Kernel inmutable. Upgrade = deployment nuevo, deals viejos intactos |
| `SafeMath` | Solidity 0.8 ya chequea overflow |

Permit2 (Uniswap) es un **path de pull** opt-in del Holder, no una dependencia del escrow. ERC-2612 tampoco es el path canónico (`STATE_MACHINE.md` §3.5).

Tests: `forge-std`. Nada de crypto casera en tests de firmas: las mismas primitives.

Plan de testnet (Core primero, Arbitrum Sepolia, USDC Circle): `TESTNET_PLAN.md`.

---

## 4. Settlement y OZ

Pull de activación: `safeTransferFrom` + chequeo de delta `== principal`. Si el token miente o descuenta fee, no hay deal.

Push de terminal: `trySafeTransfer`. Si devuelve false, el crédito queda. El outcome ya commitió. `safeTransfer` que revierte **no** puede ser el único camino: reescribiría el terminal.

Withdraw de crédito: `safeTransfer` al beneficiario; si falla, el crédito sigue (reintento).

---

## 5. Invariantes de esta capa

- Un storage: el escrow. Libraries `external` no tienen balances propios.
- OZ no define economía. No hay `Pausable` ni owner sobre un deal vivo.
- `SignatureChecker` es la verificación de `HolderAuthorization`. No un `ecrecover` suelto que deje afuera a los pools.
- BondVault, paquetes y rampas no se meten en estas libraries para “ahorrar tamaño”. Ya son otros contratos.
