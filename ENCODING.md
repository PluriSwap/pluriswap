# Encoding EIP-712

Este archivo congela el typed data. Economía y grafo: `STATE_MACHINE.md`. Paquetes: `PACKAGES.md` / `PROTECTION.md`. Si un campo no está aquí, no se firma.

Principio: **el envelope es estable; la extensión es un array de `packageId`**. Un paquete nuevo no cambia el typehash de Core. Un campo nuevo de Core es versión nueva de dominio (deployment nuevo, deals viejos intactos).

---

## 1. Dominio

```
EIP712Domain(
  string  name,
  string  version,
  uint256 chainId,
  address verifyingContract
)
```

| Campo | Valor |
| --- | --- |
| `name` | `PluriSwap` |
| `version` | `1` |
| `chainId` | el de la chain (Sepolia `421614`, mainnet `42161`) |
| `verifyingContract` | address del escrow |

Sin `salt`. El contrato es la instancia. Replay cross-chain y cross-deploy lo corta el dominio.

`version` del dominio es la del **kernel**, no la de un paquete. Paquete nuevo ≠ bump de dominio.

OZ: `EIP712` + `_hashTypedDataV4`. Verificación: `SignatureChecker.isValidSignatureNow(signer, digest, bytes)` — EOA y EIP-1271, el mismo digest.

---

## 2. Qué se firma y qué no

Se firma lo que el kernel snapshottea. No se firma:

- fees (viven en el `packageId`);
- receivers (las addresses de firma *son* los destinos);
- dealId (nace en la activación);
- sujeto Passport / score / cap.

Tres mensajes de activación, un struct de negocio compartido:

```
DealTerms          ← lo que las tres partes tienen que ver igual
HolderAuthorization
ProviderAgreement
ControllerAcceptance   ← solo si Holder ≠ Controller
```

Dual-sign, **después** de `FUNDED`, son otros types. No se recicla `DealTerms` para un split: el deal ya existe; se firma `dealId` + acción.

---

## 3. `DealTerms` — el struct de negocio

```solidity
struct DealTerms {
    address holder;
    address controller;
    address provider;
    address token;
    uint256 principal;
    uint256 fiatDuration;
    uint256 releaseDuration;
    uint256 disputeDuration;
    uint256 arbitrationDuration; // ignorado si ARBITRATION no está en packageIds
    bytes32[] packageIds;        // vacío = Core-only
}
```

Type string EIP-712 (orden de campos = orden de encode):

```
DealTerms(address holder,address controller,address provider,address token,uint256 principal,uint256 fiatDuration,uint256 releaseDuration,uint256 disputeDuration,uint256 arbitrationDuration,bytes32[] packageIds)
```

Reglas:

- `principal > 0`. Duraciones `>= 0`.
- `holder != provider`. `controller` puede ser `holder`.
- `packageIds`: **únicos y ordenados ascendente**. El kernel rechaza si no. Así el mismo set no tiene dos hashes. El orden de *ejecución* de hooks es el de `PROTECTION.md`, no el del array.
- Cada `packageId` es el hash de contenido del paquete (código + policy + fees + sink/V/adapter). El deal no pisa amounts.
- Si ZK está en el set, `DISPUTED` apaga. Si ARBITRATION está y ZK también, activación rechaza (incompatibles).
- `arbitrationDuration` solo se usa si ARBITRATION está seleccionado; si no, se ignora (puede ser 0).

`termsHash` = `hashStruct(DealTerms)` según EIP-712 (no un `abi.encode` suelto). Es el mismo hash que anida el envelope. Wallets que muestran nested structs ven token, principal, roles, relojes, paquetes.

**Por qué no un `termsHash` opaco.** Un `bytes32` suelto es future-proof para el contrato y opaco para el firmante. Nested `DealTerms` es igual de extensible (`packageIds`) y se puede leer en MetaMask / Safe.

**Por qué no meter campos de paquete en `DealTerms`.** Un fee, un verifier address suelto, o un cap, romperían el typehash en cada experimento. El `packageId` ya bindea eso.

---

## 4. Activación

### 4.1 Nonce por party

Cada firma de activación trae **su** nonce. El mapa es `used[signer][nonce]`, no un contador global ni solo del Holder.

Sin nonce del Provider, el mismo `ProviderAgreement` llenaría N deals idénticos (otro nonce del Holder, mismos `DealTerms`). Eso no es un OTC: es una orden abierta. Un nonce por firmante = un fill. Lo mismo para el Controller: aceptar un trabajo no es aceptar todos los clones.

No es secuencial. Cada address elige el número. `used[Alice][7]` no choca con `used[Bob][7]`. Dos deals concurrentes del mismo Holder: dos nonces del Holder y dos del Provider.

Si la activación revierte, no se marca ninguno. Un nonce usado no se reusa. Más adelante: `cancelNonce(nonce)` invalida el del `msg.sender` sin activar.

Dual-sign **no** lleva nonce: el `dealId` ya es único y el estado del deal impide replay.

### 4.2 `HolderAuthorization`

```solidity
struct HolderAuthorization {
    DealTerms terms;
    uint256 nonce;
    uint256 deadline; // creation expiry (unix)
}
```

```
HolderAuthorization(DealTerms terms,uint256 nonce,uint256 deadline)DealTerms(...)
```

Autoriza pull exacto de `terms.principal` de `terms.token` desde `terms.holder` hacia el escrow, para un deal con esos términos, si se activa antes de `deadline`. Consume `used[holder][nonce]`.

`deadline` es el de la *autorización*, no un reloj del deal. Los relojes del escrow arrancan en activación / `FIAT_SENT` / `DISPUTED`.

Si `terms.holder == terms.controller`, esta firma cubre al Controller. No hay `ControllerAcceptance` y no se consume un segundo nonce.

### 4.3 `ProviderAgreement`

```solidity
struct ProviderAgreement {
    DealTerms terms;
    uint256 nonce;
    uint256 deadline;
}
```

Mismo `DealTerms` (`hashStruct` idéntico). Consume `used[provider][nonce]`. `deadline` acota la oferta; el nonce impide un segundo fill.

### 4.4 `ControllerAcceptance`

```solidity
struct ControllerAcceptance {
    DealTerms terms;
    uint256 nonce;
    uint256 deadline;
}
```

Solo si `holder != controller`. Consume `used[controller][nonce]`. Evita colgar el rol a una address que no pidió el trabajo, y evita reusar esa aceptación en otro fill.

### 4.5 `dealId`

Nace en activación, determinístico:

```
dealId = keccak256(abi.encode(
    DOMAIN_SEPARATOR,
    hashStruct(terms),
    holderNonce,
    providerNonce,
    holder == controller ? uint256(0) : controllerNonce
))
```

Dual-sign y ZK usan este id. Bindea el fill completo (las tres nonces), no un contador de bloque.

---

## 5. Dual-sign (post-`FUNDED`)

Types **distintos**. Un `uint8 action` no es future-proof: un valor nuevo reinterpreta payloads viejos. Un type nuevo no toca los viejos.

Dominio = el mismo escrow. Firman el **Provider** y el **Controller** snapshotados. El Holder no firma de nuevo: en P2P `holder == controller`, así que una de las dos firmas es esa wallet y la otra es el Provider. `holder != provider` siempre.

Relayer cualquiera. `SignatureChecker` en las dos. EIP-1271 si alguna party es contrato.

Cada party firma el **mismo type** con el mismo `dealId` y el mismo `deadline`, y **su** nonce. Los digests difieren (el nonce). El kernel exige `dealId` y `deadline` idénticos entre las dos copias; consume `used[provider][nonceP]` y `used[controller][nonceC]`. Si el relay revierte, no se consume ninguno.

No hay dual-sign de “cambiar Holder”. No hay payout.

### 5.1 `MutualCancel` — CASE-CORE-05 / 08 / 12 y ARB dual-sign a `CANCELLED`

```solidity
struct MutualCancel {
    bytes32 dealId;
    uint256 nonce;
    uint256 deadline;
}
```

```
MutualCancel(bytes32 dealId,uint256 nonce,uint256 deadline)
```

Qué autoriza: terminar **ese** deal en `CANCELLED`, principal 100% al Holder, bonds (si hay) unlock pacífico. Válido desde `FUNDED`, `FIAT_SENT`, `DISPUTED`, `ARBITRATION_ACTIVE`, mientras el deal no sea terminal y `block.timestamp <= deadline`.

Provider firma `MutualCancel({dealId, nonce: nonceP, deadline})`.
Controller firma `MutualCancel({dealId, nonce: nonceC, deadline})`.

Mismo `dealId`, mismo `deadline`, nonces distintos (salvo coincidencia numérica en espacios distintos: `used[provider][5]` y `used[controller][5]` no chocan).

No re-firma `DealTerms`. El `dealId` ya bindea términos, parties y fill. Un cancel de otro deal no verifica.

Cancel unilateral del Provider en `FUNDED` (CASE-CORE-03) **no** usa este type: es una llamada, no un dual-sign.

### 5.2 `CoSignedRelease`

```solidity
struct CoSignedRelease {
    bytes32 dealId;
    uint256 nonce;
    uint256 deadline;
}
```

Mismo esquema de dos firmas. Outcome: `RELEASED`, principal 100% al Provider. No sustituye al release unilateral del Controller desde `FIAT_SENT`.

### 5.3 `MutualSplit`

```solidity
struct MutualSplit {
    bytes32 dealId;
    uint16  providerBps; // 0..10000, sobre el resto *después* del completion fee
    uint256 nonce;
    uint256 deadline;
}
```

Las dos copias tienen que coincidir en `dealId`, `providerBps` y `deadline`. `providerBps = 10000` no sustituye a `CoSignedRelease` (type distinto, el wallet muestra otra intención).

---

## 6. Qué no va en el typed data (y cómo se extiende)

| Quiero… | Dónde |
| --- | --- |
| Un paquete nuevo | Otro `packageId` en el array. Typehash de `DealTerms` igual |
| Fee / V / adapter / sink | Preimage del `packageId` |
| Un reloj Core nuevo | Kernel `version` "2", contrato nuevo |
| Una acción dual-sign nueva | Struct EIP-712 nuevo. Los tres de arriba siguen |
| Invalidar un nonce sin activar | Función `cancelNonce` después; no cambia el type |
| Permit2 / approve | Fuera del digest. El digest autoriza el pull; el token coopera aparte |

---

## 7. Invariantes

- Un solo domain separator por escrow. EOA y contrato firman el mismo digest.
- `DealTerms` es la unidad de acuerdo. Las tres firmas de activación anidan o son ese struct.
- `packageIds` vacío es Core-only. Orden canónico.
- Nonce por **party** (`used[signer][nonce]`), elegido, no secuencial. Activación y dual-sign consumen el nonce de cada firmante. Un relay que revierte no marca.
- Destinos = `holder` y `provider` del struct. No hay campo receiver.
- Dual-sign nombra `dealId`, no re-firma `DealTerms`.
- Bump de `EIP712Domain.version` = otro kernel. Deals del v1 intactos.
