# PluriSwap

Escrow P2P de principal cripto contra fiat offchain. Kernel neutral (sin dueño, sin pausa, sin allowlist), paquetes opt-in, pools de terceros, rampas cero-bps. La privacidad es un valor de diseño.

**Toda la documentación del protocolo vive en [`PLURISWAP.md`](./PLURISWAP.md)**: visión, espíritu, diseño, decisiones e implementación. Empezá ahí.

Artefactos operativos (fuera del monolito por necesidad, no por fragmentación):

- [`KLEROS_POLICY.md`](./KLEROS_POLICY.md) — policy que leen los jurados; se pinea a IPFS como `KLEROS_POLICY_URI` (PLURISWAP.md §5.8)
- [`LAB_UI.md`](./LAB_UI.md) — referencia de la consola de laboratorio

## Stack

Foundry, Solidity `0.8.28`, Cancun, `via_ir`. OpenZeppelin v5. Arbitrum (Sepolia `421614` hoy). Sin proxy, sin `Pausable` / `Ownable` sobre settlement.

## Build y test

```shell
forge build
forge test                       # unit + fuzz (256 runs) + invariants (32 x 256)
FOUNDRY_PROFILE=ci forge test    # fuzz 2048, invariants 128 x 512
```

CI (push y PR): `forge fmt --check`, `forge build --sizes` con gate de margen de bytecode, `forge test`, Slither (`--fail-medium`), Aderyn (`--fail-high`), consola del lab (vitest + build), gates de drift de fixtures (bun regenera los vectors de los circuits y el fixture de los singletons Poseidon, y exige `git diff --exit-code`) + suite JS del consumer side de F4 (verify/chain, semántica con stubs); CI nunca necesita nargo/bb — proofs, verifiers y VKs viven como fixtures comprometidos. Nightly con perfil `ci`. Detalle y ley de TDD en `PLURISWAP.md` §5.4.

## Layout

```
src/Escrow.sol              kernel
src/interfaces/IEscrow.sol  superficie de lectura (packages, pools, ramps)
src/libraries/              Consent, Terms, Settlement, Clocks, Types, PackageId, Packages (external)
src/packages/               módulos opt-in detrás de interfaces
src/pools/                  Holder-contrato vault + factory
src/ramps/                  composers (Stargate)
circuits/                   la capa ZK: 11 circuitos Noir + el twin JS + la lib de consumer side F4 (verify/chain; ver circuits/README.md)
verifiers/                  subproyecto de los verifiers Honk generados (via_ir off)
lab/                        consola de operador (read-only)
script/                     deploy y deal scripts
deployments/                addresses, no secrets
test/                       un área de catálogo por archivo (+ fuzz/, invariant/, fork/)
mocks/                      stand-ins de test; nunca identidad de producción
```

Diseño, decisiones y detalle normativo: [`PLURISWAP.md`](./PLURISWAP.md).
