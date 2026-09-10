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

## Fuera de este PR

Matriz de elegibilidad (PR-3), `activate` y verbos (PR-4+).
