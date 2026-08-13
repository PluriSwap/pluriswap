# Rampas (entrada y salida de Arbitrum)

Una rampa **no** es parte del kernel. Es un composer opt-in que mueve stables hacia el Holder en Arbitrum y, si el usuario quiere, saca el crédito terminal a otra chain. El kernel solo ve lo que está en `STATE_MACHINE.md`: un ERC-20 local, pull exacto, deal en Arbitrum.

Si hay conflicto sobre meter un bridge en el escrow, manda este archivo. Si hay conflicto sobre estados o transiciones, manda `STATE_MACHINE.md`.

```
otra chain  →  rampa (Stargate u otra)  →  Holder en Arbitrum  →  kernel
terminal    →  crédito en Arbitrum      →  rampa out (opt-in)
```

En la práctica casi todo el mundo va a usarla. Eso no la convierte en Core. Un Holder que ya tiene el stable en Arbitrum activa sin rampa, sin fee, sin vendor.

---

## 1. Relación con el kernel

No hay estados `BRIDGING_IN` / `BRIDGING_OUT`. No hay verbo de bridge. No hay `invoice` de rampa.

La rampa termina **antes** de CASE-CORE-01 (deja el token en el Holder y, si compose, dispara la activación) o **después** del terminal (el usuario retira el crédito y puentea). Si Stargate está caído, los deals ya fondeados en Arbitrum siguen el catálogo Core.

Otra rampa (CCTP, Across, la que sirva) es otro composer, otra identidad. No es una versión nueva del kernel.

---

## 2. Superficie v1

Dominio de settlement: **Arbitrum**. El EIP-712 bindea esa chain y ese deployment.

Tokens de la superficie oficial, al comienzo: **stables que Stargate lista** en Arbitrum. ETH queda para después. El kernel no es un catálogo de Stargate: el filtro de máquina sigue siendo pull exacto (fee-on-transfer y rebase no activan). Lo que “soportamos” en producto es ese set de stables; un deal Core-only con un vanilla ERC-20 ya en Arbitrum no está prohibido por la máquina, no está en la superficie oficial.

Si se suma otra rampa, su set se une al de la superficie. No se estrecha el kernel.

---

## 3. Costo

La rampa **no cobra para el protocolo**. Cero bps, cero `invoice`, cero recipient DAO.

El usuario paga solo lo que cobra la infraestructura: fee de Stargate (o de la otra rampa), gas, slippage. Nada más. Un composer que se quede un spread o un “protocol fee” de puente no es esta rampa; es otro producto.

---

## 4. Stargate y las demás

Stargate es la rampa oficial de arranque porque cubre el set de stables con el que queremos operar. No es exclusiva. CCTP u otra rampa que mueva el mismo stable sin renta de protocolo entra igual: composer delante/detrás, mismo deal.

Compose en destino puede, en la misma llegada, acreditar al Holder y llamar la activación. Eso es el composer hablando con CASE-CORE-01. El digest EIP-712 no cambia.

---

## 5. Invariantes

- Arbitrum es el recinto del escrow. Un deal no es omnichain.
- La rampa no escribe estado Core, no custodia principal activo, no elige receivers ni outcomes.
- Ausente / caída / hostil: Core en Arbitrum sigue.
- Protocolo no extrae redito del puente. Solo costo de infraestructura.
- v1 oficial = stables Stargate en Arbitrum. ETH después. Otras rampas, bienvenidas, mismo recorte.
