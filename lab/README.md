# PluriSwap lab — consola de laboratorio

Una vista del recinto, no un segundo protocolo. Cada widget mapea a un getter, evento o entrypoint de `Escrow.sol`. La arquitectura de información está en [`../LAB_UI.md`](../LAB_UI.md); este README explica cómo correrla y cómo recorrer un deal a mano.

Chrome en español; identificadores on-chain en inglés (`FUNDED`, `markFiat`, `WrongStatus`).

## Correr

```bash
cd lab
npm install
npm test        # vitest: eip712, preflight, predicados, relojes, PackageId, paths
npm run dev     # http://localhost:5173
```

Stack: Vite + Preact + `@preact/signals` + viem. Sin backend: todo habla RPC.

### Anvil en un minuto

```bash
anvil                                             # terminal 1
export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
forge script script/Deploy.s.sol            --rpc-url http://127.0.0.1:8545 --broadcast --private-key $PRIVATE_KEY
forge script script/DeployPackages.s.sol    --rpc-url http://127.0.0.1:8545 --broadcast --private-key $PRIVATE_KEY
forge script script/DeployPoolFactory.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --private-key $PRIVATE_KEY
```

Eso escribe `deployments/31337*.json`. La consola los carga como **sets** del AddressBook (un set = un JSON, anclado al `escrow` que declara). `31337.json` y `31337-packages.json` son **dos recintos distintos** con su propio `testToken`.

## Cómo se navega

```
Recinto en foco ─ Asientos (Holder · Provider · Controller · Relayer) ─ Path activo
├─ Guía            qué es cada rol, estado, reloj y verbo
├─ Recinto         dominio EIP-712, sets, abrir un deal por dealId o (signer, nonce)
├─ Catálogo        Paths (CASE-CORE-01..17, trío, ZK, arb, pool, ramp) → "arrancar"
├─ Consentimiento  componer DealTerms, firmar HA/PA(/CA), preflight, activate
├─ Paquetes        slots de PackageMods, recompute de PackageId, peers, binding
├─ Deal            máquina viva + matriz de elegibilidad + términos, relojes, settlement, dual-sign
├─ Créditos        creditOf por asiento, withdraw
├─ Pool            deposit / authorize / unlock / reconcile
├─ Rampa           quote / send (taxi-only)
└─ Laboratorio     LAB: mint, approve, setHuman, bond deposit, payload mock, submitRuling, reloj Anvil
```

**Asientos.** El asiento activo es `msg.sender` de la próxima tx. Cada asiento tiene una address y, opcionalmente, una *pk de sesión* (solo memoria; pensada para Anvil y claves de test). En Anvil, *cargar cuentas Anvil* llena los cuatro. P2P = Holder y Controller comparten address.

**Matriz.** En Deal, todos los entrypoints del kernel están siempre listados. Los legales para el asiento activo tienen botón de enviar; los ilegales muestran el **primer revert** que el bytecode lanzaría (`WrongStatus`, `Unauthorized`, `TooEarly`, `EdgeOff`, `PackageNotSelected`, …). Click en una fila explica quién, desde/hacia qué estado, qué plata se mueve y para qué sirve.

## Recorrido 1: Core-only P2P (CASE-CORE-01 → 02 → 06)

1. Asientos → *cargar cuentas Anvil*.
2. Laboratorio → `mint(to = Holder)`; con el asiento **Holder** activo, `approve(spender = escrow)`.
3. Consentimiento → *copiar de los asientos*, *usar testToken del set*, elegir nonces libres, *firmar como Holder*, *firmar como Provider*. El preflight debe quedar todo en verde (overload de 6 args, CA dummy).
4. Asiento **Relayer** → *enviar activate*. La consola salta a Deal en `FUNDED`.
5. Asiento **Provider** → fila `markFiat` → enviar. `FIAT_SENT`.
6. Asiento **Holder** (= Controller) → fila `release` → enviar. `RELEASED`; Settlement muestra `providerAmt = principal`.

Variantes: `cancelByProvider` en FUNDED; `timeoutFiat` con `fiatDuration = 0`; `claim` con `releaseDuration = 0` (termina en `CLAIMED`, no en `RELEASED`); `openDisputed` con `releaseDuration = 100` y luego el composer dual-sign o `forceStalemate`.

## Recorrido 2: trío Passport + Reputation + Bonds (PATH-TRIO)

Recinto en foco: el de `31337-packages.json`.

1. Paquetes → *set: trío P+R+B*. Verificar `∈ packageIds = match`, peers y `operator() = escrow`. `identify(holder)` todavía dice `NoPassport`: eso es lo que el LAB va a arreglar.
2. Laboratorio, por cada uno de Holder y Provider (con **ese** asiento activo): `setHuman(wallet, subject)` (derivar subject de la wallet), `approve(vault)`, `BondVault.deposit`.
3. Asiento Holder: `approve(escrow, principal + activationFee)`.
4. Consentimiento → firmar HA/PA → preflight: `_resolve ok`, `_engage ok`, `pullExact ok` → activate (7 args).
5. Deal: `kinds = 7`; `markFiat` → `release`. Settlement observado: `providerAmt = principal − completionFee`, invoice al `feeRecipient`.

Todo lo que dice **LAB** es mock: `PassportMock.setHuman` no verifica humanidad; en producción el adapter es `HumanPassport` (Human Passport, ex Gitcoin) y responde solo si una wallet es humana.

## Recorrido 3: tribunal

- **ArbitrationMock** (`PATH-ARB-MOCK`): Controller `approve(court, courtFee)` → `markFiat` → `openCourt` → Laboratorio `submitRuling` → `readRuling`.
- **Kleros** (`PATH-KLEROS`, Sepolia/One): `openCourt` con `msg.value == arbitrationCost(extraData)`; la evidencia se sube en la dApp de Kleros; PluriSwap solo hace `readRuling` cuando `KlerosCore.rule` dejó la sentencia. `submitRuling` se deshabilita si el court es Kleros.

## Flags

Todos los flags de app (`coreActivate`, `coreWrites`, `dualSign`, `distinctController`, `packages`, `labVerbs`, `zkArb`, `pool`, `ramp`) arrancan **on** y se apagan desde Catálogo → *Flags de app*. Apagar un flag nunca oculta una fila kernel: solo quita el botón de enviar.

## Qué no hace

- No es un dapp de consumo: no hay wizard, no hay "siguiente paso" que esconda `openDisputed`.
- No trata `deployments/*.json` como registry: pegar cualquier escrow o módulo compatible es un camino de primera clase.
- No persiste claves. No hay telemetría.
