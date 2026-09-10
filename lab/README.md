# PluriSwap lab (PR-1)

Consola de laboratorio de **solo lectura** para un Recinto (`chainId` + `escrow`). No es un marketplace. El JSON de `deployments/` es un AddressBook: atajo, no registry. Pegar un escrow compatible está al mismo nivel que elegir una fila.

Chrome: español. Identifiers on-chain: inglés (`escrow`, `domainSeparator`, `Holder`).

## Correr

Desde `lab/`:

```bash
npm install
npm test
npm run dev
```

RPC por defecto:

- `421614` → `https://sepolia-rollup.arbitrum.io/rpc`
- `31337` → `http://127.0.0.1:8545`

El constructor del escrow no bindea paquetes. Core-only vs packaged es **por deal** (PR-2).

## Demo: tres Recintos Sepolia, dos `testToken`

Conmutar las chips del chrome (o “Usar este escrow” en el drawer). Cada JSON es un **set** bound a su `escrow`. Archivos que comparten `(chainId, escrow)` son el mismo Recinto.

| sourceFile | Recinto | `testToken` de *ese* archivo |
| --- | --- | --- |
| `sepolia.json` | `0x9b00…0499E` | `0x3E9a…2d667` |
| `sepolia-packages.json` | `0xed09…071F8` | `0x3E9a…2d667` |
| `sepolia-paths.json` | `0x1Ab0…0325E` | `0x2F97…5b265` |

Esperar **tres** `domainSeparator` distintos (el dominio bindea `verifyingContract`). `sepolia-paths.json` no usa el token de `sepolia.json`.

No hay botón “usar oficiales”. `sepolia-kleros.json` y `*-pool-factory.json` no son Recintos (no tienen `escrow`): viven como sets auxiliares.

## Asientos

Holder / Provider / Controller / Relayer empiezan **desconectados**. Pegar una address es sesión, no una clave. No se persisten secretos. Si Holder y Controller son la misma address aparece `Holder=Controller`.

## Demo PR-2: Deal explorer (`IEscrow`)

En el Recinto `sepolia.json` (`0x9b00…`), atajo `releasedDealId` → `status = RELEASED`, `packageIds = []` (Core-only).

Cambiar al Recinto `sepolia-packages.json` (`0xed09…`) y abrir `zkDealId`. Kinds debe incluir ZK. No mezclar esos dealId entre recintos: el dominio es otro `verifyingContract`.

Si `releaseDuration = 0` y el deal ya está `FIAT_SENT` (o el origen `fiatSentAt` está escrito), `openDisputed` aparece como `TooLate` en el panel de clocks. `claim` aparece `due`.

Lookup también acepta `dealOf(signer, nonce)`. Cambiar de Recinto descarta el Deal en foco.

## Demo PR-3: matriz (primer revert)

Pegar la address del **Provider** en el asiento Provider y activarlo. En un deal `FUNDED` Core, `markFiat` = ENABLED. Mismo deal, asiento Holder → `Escrow.Unauthorized`.

Deal ZK `FUNDED`: `markFiat` = `Escrow.EdgeOff`; `timeoutFiat` sigue (anyone, due si `fiatDuration=0`).

Deal `FIAT_SENT` con `releaseDuration=0`: `openDisputed` = `Clocks.TooLate`; `claim` = ENABLED.

Filas dual-sign = `draft-empty` hasta el composer (PR-6). CASE-CORE-16/17 (`release`/`claim` en `DISPUTED`, verbos en terminal) siguen visibles con `WrongStatus`.

## Demo PR-4: `activate` P2P Core-only (6 args)

Anvil (`31337`). Cuentas Foundry 0 (Holder=Relayer) y 1 (Provider). PK solo en el asiento, nunca en el AddressBook.

```bash
# mint + approve al escrow del Recinto 31337
cast send $TOKEN "mint(address,uint256)" $HOLDER 1000000 --private-key $PK0 --rpc-url http://127.0.0.1:8545
cast send $TOKEN "approve(address,uint256)" $ESCROW 1000000 --private-key $PK0 --rpc-url http://127.0.0.1:8545
```

En Consentimiento: copiar asientos, testToken del set, nonces libres, deadline unix futuro, (3600, 1800, 7200, 0), `packageIds=[]`. Firmar HA y PA. Relayer envía overload **6** con CA dummy + `bytes("")`. `status == FUNDED`. El inspector muestra 6 args.

Si hay `packageIds` corta con PR-8.

## Demo PR-5: verbos Core de asiento

Tras `FUNDED`, asiento Provider + pk → `markFiat`. Asiento Controller (P2P = Holder) → `release`. `timeoutFiat` con `fiatDuration=0` (anyone). `openDisputed` exige `releaseDuration=100` (no 0). `claim` con `releaseDuration=0`. `withdraw` con crédito 0 = `no-op` (no se envía). Flag `coreWrites` (default on). Filas dual-sign/ZK/ARB siguen visibles sin botón Enviar.

## Demo PR-6: dual-sign

En un deal `FUNDED`, panel Dual-sign: type `MutualCancel`, deadline unix futuro, nonceP/nonceC distintos de los de activate. Firmar Provider y Controller (P2P: Controller = Holder pk). Relayer una tx. Flag `dualSign`.

Draft vacío → las tres filas `draft-empty` (no `DeadlinePassed` por deadline 0). `providerBps=10000` no se relabela a `CoSignedRelease`. CASE-CORE-08–10 desde `FIAT_SENT`; 12–14 desde `DISPUTED`.

## Demo PR-7: Controller distinto (`ControllerAcceptance`)

Tres addresses distintas. Flag `distinctController`. Desmarcar P2P. Copiar asientos (Holder, Provider, Controller). Firmar HA, PA y CA. Relayer envía el mismo overload de 6 args con CA hashed (no dummy). `dealId` incluye `controllerNonce`. Tres `used` y tres `dealOf` apuntan al mismo id. CASE-CORE-01-CTRL: (3600, 1800, 7200, 0).

P2P sigue dummy: si `holder == controller` el inspector muestra `dummyCA=true` y `controllerSig 0x`. Flag off + `holder != controller` → preflight `distinctController off`.

## Demo PR-8: PackageId + PackageMods (overload 7)

Flag `packages`. Default Core-only: slots nulos, overload 6. Pegar addresses (o “Pegar slots del set” como atajo, no registry). La tabla recomputa `PackageId.*` y marca match/miss, peer passport, `operator`/`kernel` vs Recinto.

PATH-NEGATIVE-ZK-ARB: slots zk + court. Si ambos ids están en `packageIds` → preflight `Escrow.IncompatiblePackages`. Si falta un id (override) → `Escrow.UnknownPackage` **antes**. PATH-NEGATIVE-UNSORTED: override no canónico → `Terms.UnsortedPackageIds` antes de `TermsMismatch`.

Trío sin `setHuman` (PR-9): `_engage` muestra `IPassport.NoPassport` (DISABLED), no ENABLED. Relayer envía overload 7; `PackageMods` no entra al digest.

## Demo PR-9: jaula LAB

Flag `labVerbs`. El panel Laboratorio está marcado visualmente distinto de los verbos kernel. Copy: **no es humanidad ni un proof de circuito**. No hay botón “Verify humanity”. `ArbitrationMock.open()` no aparece.

PATH-TRIO: `setHuman` ×2 (Holder y Provider), `mint`, `approve` vault, `vault.deposit` del lock `(principal+9)/10`, `approve` escrow, activate 7-arg, `markFiat`, **release** (no claim). Reloj Anvil visible solo si `chainId == 31337`; warp 100s para CASE-CORE-11.

El payload mock se ensambla aquí y se pega en `verifyProof` (PR-10).

## Demo PR-10: ZK/ARB + drift

Flag `zkArb`. `verifyProof` exige el payload LAB (no es un circuito). Deal ZK `FUNDED`: `markFiat`/`openDisputed`/`claim` = `EdgeOff`; `timeoutFiat` sigue. PATH-ZK-PROOF `(3600,1800,7200,0)`: ensamblar proof mock → `verifyProof` → `RELEASED`. PATH-ZK-TIMEOUT `(0,1800,7200,0)`: `timeoutFiat` due inmediato.

PATH-ARB-MOCK `(3600,1800,7200, 1 days)`: `arbitrationDuration = 1 days`, **no** meter 1 days en `disputeDuration`. Controller approve **court** ≥ `courtFee`; `msg.value = 0`. Sin approve: matriz `Settlement.InexactPull`, no ENABLED. Luego `openCourt`, LAB `submitRuling`, `readRuling`. `forceArbitrationTimeout` no está due al abrir.

PATH-KLEROS `(3600,1800,7200,7 days)`: `kernel()` vs Recinto; `msg.value == arbitrationCost(extraData)`. Drift no deshabilita Core (KERNEL-04).

## Demo PR-11: espacio Pool

Flag `pool`. PATH-POOL-HOLDER `(3600,1800,7200,0)` contra el JSON cuyo `escrow` es el Recinto. Banner si `pool.escrow() ≠ Recinto`.

Tres envelopes: HA vía EIP-1271 (`holderSig = ""`), PA del Provider, **CA hashed** (dummy revierte). `holder = pool`, `controller = agente`. `authorize(ha)` en el vault **antes** de activate. Constitución (NAV, shares, deposit) no entra en la matriz del deal. Kick futuro-only: no hay botón.

## Fuera de este PR

Rampa taxi + catálogo PR-12.
