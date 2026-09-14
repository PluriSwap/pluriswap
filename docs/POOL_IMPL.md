# Plan de implementación: Pools (owned v1 — hecho)

Reemplazado por `POOL_SHARES_IMPL.md` (vault con shares; privado = depósitos cerrados). Este archivo es el recorte que ya se desplegó.

Acordado en su momento. El kernel no se tocó. Spec: `POOLS.md`.

## Producto

- Idle vive en el pool (Holder-contrato). El kernel solo custodia el deal vivo.
- No hay book on-chain de LPs. El marketplace es el backend.
- Reputación de conducta: terminal del escrow / paquete `Reputation`. Fill rate: backend.
- Cualquiera puede tener un pool. Fee de listing: después.
- Oficial vs custom: `extcodehash` del clone. Factory inmutable (mismo criterio que el kernel). Registro en backend: otra factory, cuando exista el servicio.

## Recorte v1

Owned completo: tesorería `idle` / `locked` / `consumed` / `credits` y máquina `ACTIVE` → `DEFICIENT` / `CLOSING` → `CLOSED`.

`authorize` lockea idle→locked y aprueba al escrow **antes** de `activate`. `isValidSignature` es `view`. `unlock` si el authorize expiró y el nonce no se usó. `reconcile` lee `status` + `creditOf`; el caller pasa el holder-gross (`returned`) porque el escrow no expone el payout.

Crowdfunded, oracle, book, fee de listing, registro en backend: fuera.

## Piezas

| Pieza | Rol |
| --- | --- |
| `src/pools/Pool.sol` | Constitución owned. Config en storage. Impl no se inicializa. |
| `src/pools/PoolFactory.sol` | EIP-1167 `createPool`. Evento `PoolCreated`. `isOfficial`. |
| `script/DeployPoolFactory.s.sol` | Publica impl+factory (nosotros). |
| `.cursor/skills/deploy-pool/` | Skill del trader: `createPool`. Sin forge/Anvil. Sin POST. |

## Prueba de oficial

Clone 1167 de nuestra impl. `factory.isOfficial(pool)` compara `extcodehash`. Custom = otro bytecode. Impl y hash son `immutable`; un template o un hook de registro nuevos son otro deploy de factory, no un upgrade.

## Skill

Pregunta owner, token, escrow, controllers. `cast send` a la factory. Parsea `PoolCreated`. No registra en backend.

## Testing

`test/Pool.t.sol`, `test/PoolFactory.t.sol`. No romper `test/PoolHolder.t.sol`.
