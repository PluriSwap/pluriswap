# Plan: vault con shares (privado = crowdfunded cerrado)

Reemplaza el owned de `POOL_IMPL.md`. Spec: `POOLS.md` (actualizar §3, §7, §8 en el primer slice). El kernel no gana estados ni verbs de pool. `settlementOf` sí es un bump opt-in del escrow (`STATE_MACHINE.md` §14).

TDD: `PLAN.md`. Un comportamiento, un test rojo, después producción.

---

## Producto (cerrado)

El vault es siempre un fondo con shares internas, no transferibles. “Pool normal” es el mismo contrato con depósitos cerrados.

| | Privado | Abierto |
| --- | --- | --- |
| Quién deposita | `depositors[]` fijo en el `create` | Cualquiera |
| Economía | Shares sobre NAV | Igual |
| Quién redime | Cada LP sus shares | Igual |
| Agentes | Igual (Sponsors + designados) | Igual |

Roles:

- **LP** — tiene shares. Depositar no da derecho a operar deals.
- **Sponsor** — admin. Uno o más, escritos en el `create`. **No se puede mutar el set.** Todo Sponsor es agente (puede ser Controller de un deal) sin designarse.
- **Designado** — wallet extra que un Sponsor pone o saca del roster. No es Sponsor.
- **Controller** — rol del **deal**, no del vault. El kernel snapshottea una address `C` por fill. `C` tiene que ser Sponsor o designado.

Un LP que no es Sponsor y no está designado no puede ser Controller.

Cualquier Sponsor, solo, suma o saca designados. No puede echar a otro Sponsor ni quitarle el rol automático. Otro set de Sponsors = otro pool.

El Controller cobra un fee del vault, no del kernel. Es lo que ganan por operar deals con la liquidez de los LPs. El escrow sigue partiendo solo Holder / Provider.

---

## Qué no es esto

- No es ERC-20 / ERC-4626 de LP. Shares no salen del mapping.
- No es un book on-chain. Marketplace = backend.
- No es custom untrusted. Esta es **nuestra** constitución (un `extcodehash`).
- No crece el `Pool.sol` actual con un flag. Se reemplaza.
- No hay `owner`. Se borra `setController` como función de un dueño único.
- Pools ya desplegados en Sepolia (factory `0xB42d…`) siguen en el bytecode viejo. Oficiales de **esa** factory. Esta es otra impl + otra factory.

---

## Recorte v1

Dentro:

- Shares, NAV, depósito abierto/cerrado, redeem contra idle.
- Sponsors inmutables, roster de designados mutable por cualquier Sponsor.
- Tesorería `idle` / `locked` / `consumed` / `credits`.
- Vida: `ACTIVE` → `DEFICIENT` / `RUNOFF` / `WINDING_DOWN` → `CLOSED`.
- Mismo borde kernel: `authorize` + EIP-1271 + pull + `unlock` + `reconcile`.
- `settlementOf` en el escrow. `reconcile` permissionless, sin `returned` del caller.
- Fee de Controller: bps del principal, reservado de idle, pagado por el vault tras el terminal.
- Factory 1167, `isOfficial` por `extcodehash`. Skill `createPool` actualizado.

Fuera:

- Transferencia de shares, secondary, ERC-4626.
- Oracle/banda, listing fee, POST a backend.
- Fee de aceptación / mandato / bits en el kernel.
- Capital mínimo de Sponsor on-chain.
- Crowdfunded “charter §16” gated por DAO.
- ETH, mainnet, Circle USDC.
- Mutar Sponsors (no existe el verbo).
- Upgrade de proxy del vault o de la factory.

---

## Economía de shares

`nav = idle + credits + locked` (unidades del token). El locked es receivable, no caja.

- Primer depósito: `shares = amount` (1:1). Exigir `amount >= 1e6` (stables 6 dec) para no dejar el vault en share price 0.
- Después: `sharesOut = amount * totalShares / nav` (redondeo hacia abajo, a favor del vault).
- Redeem: `assetsOut = sharesIn * nav / totalShares` (abajo). Revertir si `assetsOut > idle`. No se puede salir “a NAV completo” mientras el locked no vuelva. Eso es `RUNOFF`.
- Un withdrawal no toca `locked`.

Deficiencia: `onHand < idle + credits` → `DEFICIENT`. Recap = `deposit` que cubre. `onHand = token.balanceOf(this) + escrow.creditOf(token, this)`.

Ataque de inflación en abierto: primer depósito chico + donate. Mitigación v1 = piso `1e6` en el primer mint. No virtual shares.

---

## Vida del servicio

```
ACTIVE ──deficiencia objetiva──► DEFICIENT
DEFICIENT ──recap exacta──► ACTIVE
ACTIVE ──cualquier Sponsor──► RUNOFF
DEFICIENT ──cualquier Sponsor──► RUNOFF
ACTIVE | DEFICIENT ──cualquier Sponsor──► WINDING_DOWN
RUNOFF ──cualquier Sponsor──► WINDING_DOWN
RUNOFF ──locked == 0, Sponsor endRunoff──► ACTIVE   (si quedan shares)
RUNOFF | WINDING_DOWN ──locked == 0 y totalShares == 0──► CLOSED
```

`CLOSED` no reabre. Otra actividad = identidad nueva.

| Estado | Digest / deals nuevos | `deposit` | `redeem` |
| --- | --- | --- | --- |
| `ACTIVE` | Sí, si hay idle exacto | Según gate | Sí, si `assetsOut <= idle` |
| `DEFICIENT` | No | Sí (recap) | No |
| `RUNOFF` | No | No | Sí, si `assetsOut <= idle`; NAV sigue moviéndose hasta `locked == 0` |
| `WINDING_DOWN` | No | No | Igual |
| `CLOSED` | No | No | No |

`endRunoff` solo si `locked == 0` y `life == RUNOFF`. Si `totalShares == 0`, va a `CLOSED` en vez de `ACTIVE`.

---

## Agentes (roster)

```
isAgent(c) = sponsor[c] || designated[c]
```

- `authorize`: `terms.controller` debe ser agente. Caller = ese `C` o cualquier Sponsor.
- `isValidSignature`: igual que hoy (digest pre-autorizado). No re-lee el roster: el digest ya bindeó a `C`. Kick futuro = no hay `authorize` nuevo para ese `C`.
- `setController(c, allowed)`: solo Sponsor. Revertir si `sponsor[c]` (no se designa ni se destituye un Sponsor).
- `reconcile`: cualquiera, una vez, cuando el deal es terminal y `settlementOf` existe. Ahí se paga el fee reservado, si corresponde.

---

## Fee de Controller

No entra al escrow. `POOLS.md` §9: el Core parte Holder / Provider; el vault paga al agente después de leer el record.

`controllerFeeBps` vive en el pool (0 = el agente no cobra). Mismo bps para todos los agentes. Se escribe en el `create`. Cualquier Sponsor puede cambiarlo para **deals nuevos**. El `authorize` snapshottea el fee en el `Auth`; un cambio de bps no toca deals ya lockeados.

```
fee = principal * controllerFeeBps / 10000
```

`bps <= 10000`. En `authorize`, `idle >= principal + fee`. Se lockea los dos: el principal va al escrow; el fee se queda en el vault (caja, no pull). `nav` incluye esa reserva (está en `locked`).

| Momento | Fee reservado |
| --- | --- |
| `unlock` (el deal no se usó) | Vuelve a idle. El agente no cobra. |
| `reconcile` y `holderAmt == principal` (retorno entero) | Vuelve a idle. Operar no gastó liquidez. |
| `reconcile` y `holderAmt < principal` | Se paga a `terms.controller`. `consumed += fee`. |

Pago: `transfer` al Controller (o crédito local si el push falla — mismo criterio credit-first, en el vault, no en el escrow). Nunca se toma del holder-gross del kernel: el `holderAmt` entra a idle; el fee sale de la reserva que nunca salió del pool.

Así un deal que usa el 100 % del idle todavía puede pagar: el fee se apartó **antes** del pull. Sin reserva, RELEASED dejaría `idle == 0` y el agente no cobraría.

No es success-fee sobre el spread. Es take de operador sobre principal cuando el deal consumió algo. `0 bps` cubre el desk que no cobra on-chain.

---

## `create` / factory

```solidity
function createPool(
    address[] calldata sponsors,     // >= 1, no zero, únicos
    address token,
    address escrow,
    address[] calldata controllers,  // designados; puede ser []
    bool openDeposits,
    address[] calldata depositors,   // si !open: >= 1; si open: debe ser []
    uint16 controllerFeeBps          // 0..10000
) external returns (address pool);
```

Evento: `PoolCreated(address pool, address token, address escrow, bool openDeposits)`.

`controllers[]` vacío es válido: los únicos agentes son los Sponsors.

Impl: constructor `initialized = true`. Clone + `initialize(...)`. `implementation` y `officialCodehash` `immutable`.

---

## Kernel: `settlementOf`

Hoy `_finish` paga `holderAmt` / `providerAmt` y no los guarda. `deals` es `internal`. El pool no puede leer el holder-gross.

En `Deal` persistir `holderAmt` y `providerAmt` en `_finish`. View:

```solidity
function settlementOf(bytes32 dealId)
    external
    view
    returns (Status status, uint256 holderAmt, uint256 providerAmt);
```

`reconcile` deja de recibir `returned`. Lee `holderAmt`. Sigue comprobando `onHand` (credit-first: el token puede estar en `creditOf`).

Esto es **nueva implementación de escrow**, mismo recinto, deals viejos en el deploy anterior intactos. Los tests del repo usan el `Escrow.sol` nuevo. Domain EIP-712 sigue `"PluriSwap" / "1"`; la address nueva ya separa el dominio.

No es un estado ni un verb. Encaja en EP-POST / EXT-06.

---

## Piezas

| Pieza | Cambio |
| --- | --- |
| `POOLS.md` | Unificar tipos. Sponsors inmutables. Vida compartida. Privado = gate de depósito. Fee de Controller como regla del vault (§9). |
| `src/Escrow.sol` | Guardar montos en `_finish`. `settlementOf`. |
| `src/pools/Pool.sol` | Reescribir. Sin `owner`. Shares + roles + vida de arriba. |
| `src/pools/PoolFactory.sol` | Nueva firma `createPool`. Evento sin `owner`. |
| `test/Pool.t.sol` | Reescribir contra el vault nuevo. |
| `test/PoolFactory.t.sol` | Sponsors, `openDeposits`, `isOfficial`. |
| `test/Escrow` (el que cubra close) | `settlementOf` en RELEASED / refund / cancel / arb. |
| `script/DeployPoolFactory.s.sol` | Igual, nueva ABI. |
| `script/PoolDeal.s.sol` | `createPool` nuevo; `reconcile` sin `returned`. |
| `.cursor/skills/deploy-pool/SKILL.md` | Params nuevos. |
| `test/PoolHolder.t.sol` | No tocar (Mock1271). |

`IEscrowView` en el pool: `domainSeparator`, `used`, `status`, `creditOf`, `settlementOf`.

---

## Orden (TDD)

Cada ítem: test rojo → mínimo verde.

### 1. Constitución

Actualizar `POOLS.md` §3 (un tipo, dos gates), §7–8 (una vida, Sponsors inmutables, designados), §9 (bps, reserva, pago en `reconcile`). Apuntar `POOL_IMPL.md` a este archivo como reemplazo.

### 2. `settlementOf`

Test: close RELEASED → `holderAmt == 0`; refund/expire → holder-gross; cancel → `principal/2`; arb → lo que pagó `_finish`. View no muta.

Después: campos en `Deal`, escritura en `_finish`, getter público.

### 3. Vault sin deals

Tests, en este orden:

1. `create` privado: solo `depositors` depositan; Sponsor no listado no deposita.
2. `create` abierto: cualquiera deposita; `depositors` debe ser `[]`.
3. Primer mint 1:1; segundo mint proporcional a NAV.
4. Redeem quema shares y saca idle; revertir si pediría más que idle.
5. Piso `1e6` en el primer depósito.
6. `sponsors[]` inmutable: no hay setter; `setController(sponsor, false)` revierte.
7. Designado: Sponsor lo agrega; LP no agente no pasa `isAgent`.
8. `DEFICIENT` si se saca token por debajo de `idle + credits`; `deposit` recapita.

### 4. Borde kernel

Reusar los casos de `test/Pool.t.sol` que ya existen, adaptados:

1. `authorize` lockea `principal + fee` y `forceApprove` solo del principal (el escrow no ve el fee).
2. Rechaza `C` que no es agente. `idle < principal + fee` revierte.
3. Sponsor no designado **sí** puede ser `terms.controller`.
4. Kick de designado: deal vivo sigue; `authorize` nuevo de ese `C` falla.
5. 1271 + `activate` con holder sig vacía.
6. `unlock` si deadline pasó y nonce libre: principal y fee vuelven a idle.
7. `reconcile` lee `settlementOf`; RELEASED → `holderAmt = 0`, `consumed = principal + fee`, token del fee en el Controller.
8. `reconcile` con retorno entero: fee vuelve a idle; Controller balance no cambia.
9. Cambio de `controllerFeeBps` no altera un `Auth` ya abierto.
10. `RUNOFF`: no `authorize` nuevo; redeem cuando hay idle; `endRunoff` con `locked == 0`.
11. `WINDING_DOWN` → `CLOSED` con `locked == 0` y `totalShares == 0`.

### 5. Factory + skill + script

`isOfficial` sigue siendo `extcodehash` del clone. Skill: pregunta `sponsors`, `controllers`, `openDeposits`, `depositors`, `controllerFeeBps`, `token`, `escrow`. Un `cast send`. Sin forge. Sin POST.

`PoolDeal.s.sol`: pool privado de un Sponsor-LP, un deal, reconcile sin `returned`.

### 6. Sepolia (cuando el código esté verde)

Deploy escrow nuevo si este recinto aún no tiene `settlementOf`. Deploy factory nueva. Un pool privado + un deal. JSON en `deployments/`. La factory vieja no se toca.

---

## Superficie del vault (referencia)

```
initialize(sponsors, token, escrow, controllers, openDeposits, depositors, controllerFeeBps)
deposit(uint256 amount)           // gate
redeem(uint256 shares)            // assetsOut <= idle
setController(address, bool)      // solo Sponsor; no sobre Sponsors
setControllerFeeBps(uint16)       // solo Sponsor; deals futuros
authorize(HolderAuthorization)
isValidSignature(bytes32, bytes) view
unlock(uint256 nonce)
reconcile(uint256 nonce, uint256 providerNonce, uint256 controllerNonce)
sync()
startRunoff()                     // Sponsor
endRunoff()                       // Sponsor, locked == 0
windDown()                        // Sponsor
```

Sin `withdraw(uint256 amount)` al estilo owner. Sin `owner`. Sin `finalize` que asuma un dueño residual: `CLOSED` cuando no quedan shares ni locked.

---

## Invariantes a testear

- El set de Sponsors en storage es el del `initialize`. Cero writers después.
- `isAgent(sponsor) == true` siempre.
- `authorize` con `C` no agente revierte.
- Holder-gross nunca sale hacia un Controller. El fee sale de la reserva del vault, no del payout del escrow.
- El escrow nunca hace pull del fee.
- `redeem` nunca decrementa `locked`.
- `reconcile` no acepta un `returned` del caller.
- Clone oficial: `factory.isOfficial(pool)`.
- Callback del pool no corre en `_finish`.

---

## Compatibilidad

| Deploy | Qué es |
| --- | --- |
| Escrow + factory actuales (Sepolia) | Owned v1. Siguen vivos. No son este vault. |
| Este plan | Nuevo `Escrow` (si falta el getter) + nueva `PoolFactory` + nuevo `Pool`. |

El skill apunta al JSON de la factory **nueva** cuando exista. Hasta entonces, no mezclar ABIs.
