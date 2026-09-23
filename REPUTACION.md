# Reputación verificable

Qué muestra el perfil de una cuenta, qué de eso no se puede falsificar, y qué te toca chequear a vos.

Este archivo está afuera del monolito por la misma razón que `KLEROS_POLICY.md`: su lector no es
quien diseña el protocolo sino quien **consume** esta reputación — un frontend que arma un listado,
otra dapp que la quiere leer, un integrador que necesita saber en qué creer. El detalle normativo
vive en [`PLURISWAP.md`](./PLURISWAP.md) §3.15.7 (divulgación) y §3.15.9 (circuitos); acá está lo
que hace falta para usarla sin leer las 1.200 líneas de la spec.

---

## 1. El problema

Una reputación útil exige historia. Una historia pública exige un registro que cualquiera puede
indexar, y ese registro es exactamente lo que este protocolo existe para no tener: quién comerció
con quién, cuánto, cuándo y con qué wallet.

La salida es que **la cuenta prueba cosas sobre sí misma en vez de que alguien las publique**. No
hay perfil que scrapear. Hay una hoja en un árbol Merkle que sólo el contrato escribe, y su dueña
puede emitir pruebas de lo que esa hoja dice, eligiendo cuánto dice cada una.

De ahí salen dos vistas, y toda la tensión del diseño está en el reparto entre ellas:

> **Lo público son agregados. Lo avanzado es crudo.**

---

## 2. Las dos vistas

| | **Listado** (`attest_base`) | **Perfil** (`reveal_advanced`) |
| --- | --- | --- |
| Quién lo ve | cualquiera, en el listado | sólo a quien se lo entregan |
| Tier | ordinal 1–5 | — |
| Deals completados | cota inferior (`≥ 21`) | **exacto**, si lo elige |
| Volumen | escalón de lotes (`250+`) | **exacto**, si lo elige |
| Castigo | escalón de eventos (band 0–3) | **exacto, siempre** |
| Vencimiento | sí, lo chequea el consumidor | no — la frescura es tu recibo |
| Atado a | el handle | el handle **y la clave del requester** |

Public inputs, en el orden exacto en que los circuitos los declaran (es el orden con el que se
verifica; uno fuera de lugar verifica una afirmación que nadie quiso hacer):

```
attest_base       handle_commit, tier, count, volume_band, penalty_band,
                  expiry, token, decimals, rep_root
reveal_advanced   handle_commit, fields_mask, out_count, out_volume, out_penalty,
                  requester, token, rep_root
```

`handle_commit` es el seudónimo de mercado, y es **rotable a propósito**: otro salt es otro handle,
y el viejo muere sin vínculo. Sin handle no hay consulta — el handle es la capability.

---

## 3. Tres pisos y un techo

La regla que hace que el listado valga la pena leerlo:

| Campo | Dirección honesta | Por qué |
| --- | --- | --- |
| `tier` | **piso** — se puede subestimar | una afirmación verdadera más débil sigue siendo verdadera |
| `count` | **piso** | ídem |
| `volume_band` | **piso** | ídem |
| `penalty_band` | **techo** — se puede exagerar | subestimar un castigo no es más débil: es falso |

Todo lo bueno sólo se puede subestimar. Todo lo malo sólo se puede exagerar. Las dos direcciones se
llaman igual: honestas. En el circuito son literalmente dos comparaciones opuestas
(`attest_base/src/main.nr`), y hay un test que las ancla juntas para que la asimetría no se pierda
en un refactor: `the_listing_shows_floors_and_one_ceiling`.

Que el castigo sea **obligatorio** es la decisión menos obvia y la más importante. El tier ya netea
el castigo dentro del score, así que una cuenta T2 sancionada cae a T1 y se vuelve indistinguible de
una recién llegada — justo la distinción que más necesita una contraparte. El band la restituye sin
publicar el contador.

---

## 4. Los escalones

**Volumen** — los cortes son *lotes*, no números redondos de un token favorito. Un lote es
`UNIT = 250 × 10^decimals`, la misma unidad con la que el score compra tier, así que el escalón se
lee igual en cualquier token y a cualquier escala.

| Band | Lotes | En tokens enteros |
| --- | --- | --- |
| 0 | menos de 1 | *todavía no completó un lote* |
| 1 | 1–3 | 250+ |
| 2 | 4–19 | 1.000+ |
| 3 | 20–79 | 5.000+ |
| 4 | 80–399 | 20.000+ |
| 5 | 400+ | 100.000+ |

El cupo de T5 es **sin límite sólo con bond**: sin él la escalera topea en 5.000. La única exposición
ilimitada del protocolo tiene siempre un lock vivo detrás — al 10% de §3.14.5, respaldada en un 10%
por su propio dueño.

**Castigo** — los cortes son *eventos*: un stalemate o una disputa abandonada suma 5, una derrota en
tribunal suma 15 (§3.14.7).

| Band | Puntos | Qué significa |
| --- | --- | --- |
| 0 | 0 | nunca pasó nada |
| 1 | 1–5 | un stalemate o una disputa abandonada |
| 2 | 6–15 | varios de esos, o una derrota probada en tribunal |
| 3 | 16+ | más de una derrota |

Un band y no la cifra porque **un número crudo en una pantalla pública es una huella digital**:
"47 deals, 12.350 de volumen" identifica más de lo que informa. Quien quiera el número exacto pide
el perfil, y ahí el dueño decide.

**Qué mide este número.** Desde 2026-09-23 un deal completado suma **una vez por contraparte**: el
primero con cada cuenta cuenta, los siguientes con la misma no. Los castigos no se deduplican nunca.
Así que `count` no es "cuántos deals hizo" sino **cuánta gente distinta operó con él** — amplitud, no
actividad. Un cliente habitual deja de sumar después del primer trato, y eso es deliberado: es lo que
hace que una camarilla cerrada sature en su propio tamaño en vez de comprar la escalera con fees.

El **tier** y su cupo salen de la misma tabla (§3.14.7):
`score = satSub(count + volumen/UNIT, castigo)`, con umbrales 10 / 25 / 50 / 100 y cupos de
250 / 500 / 1.000 / 2.000 / 5.000 tokens (400 / 700 / 1.500 / 5.000 / sin límite con bond). El cupo
acota `inFlight + principal`: es **exposición concurrente**, no tamaño máximo de un deal. Y el que
ata es **el más chico de los dos lados**, así que una posición grande necesita una contraparte que
también se la haya ganado.

---

## 5. Qué no se puede falsificar

Todo esto lo prueba el circuito. No hay que confiar en ningún servidor, ni en el nuestro:

- **La cuenta existe y es una sola.** La hoja tiene que ser miembro del árbol bajo `rep_root`, y el
  handle deriva del mismo secreto que la hoja. Un handle sin cuenta atrás no tiene prueba.
- **El tier sale de los stats propios, computado adentro.** No es un número que alguien declare: el
  score se calcula en el circuito desde count/volumen/castigo **con el castigo ya restado**.
- **Los stats son por token.** Una prueba de USDC no puede montarse sobre una hoja de otro token.
- **La escala no se elige.** `decimals` es público justamente porque `UNIT = 250 × 10^decimals`: con
  una escala privada, polvo compraría el band de volumen más alto (hay un test que lo ancla — el
  mismo número crudo es band 1 a 6 decimales y band 0 a 18).
- **El perfil es exacto, no una cota.** `out = mask × campo`: el valor propio de la hoja o cero.
- **El castigo no tiene interruptor.** `out_penalty == penalty`, incondicional, aunque el perfil
  esconda todo lo demás. Un perfil puede publicarse bajo el handle sin listado detrás; si el castigo
  fuera opcional acá, el band del listado tendría una puerta trasera.
- **Una prueba no se reusa.** Cada public input es parte de la afirmación: editar uno rompe la
  verificación. Está pineado empíricamente con tamper tests contra el `bb` real — tier exagerado,
  requester re-apuntado, band subestimado, castigo puesto en cero.

---

## 6. Qué tenés que chequear vos

El circuito no tiene reloj, no lee la chain y no sabe qué token es cuál. Cuatro chequeos quedan del
lado del consumidor, y los cuatro fallan cerrado:

| Chequeo | Por qué no puede hacerlo el circuito |
| --- | --- |
| `expiry` contra tu reloj | una prueba no sabe qué hora es |
| `rep_root` vivo (`isKnownRoot`) | la prueba afirma sobre *una* raíz; si sigue viva lo dice el contrato |
| `decimals` contra el ERC-20 servido | el circuito sólo ve un número, no el contrato |
| la prueba misma, con el `bb` pineado | es el verificador |

La lib de referencia los hace todos y devuelve **errores nombrados, no un booleano**:

```ts
import {
  ATTEST_BASE_PUBS, splitAttestation, verifyAttestationBase,
  type AttestBasePubs,
} from "./circuits/js/lib/verify.ts";

const { proof, pubs } = splitAttestation(blob, ATTEST_BASE_PUBS.length);
const named = Object.fromEntries(
  ATTEST_BASE_PUBS.map((n, i) => [n, pubs[i]]),
) as AttestBasePubs;

const r = await verifyAttestationBase({ proof, pubs: named, vk }, {
  now: BigInt(Math.floor(Date.now() / 1000)),
  decimalsOf: async (token) => BigInt(await erc20(token).read.decimals()),
  rootAlive: (root) => accountTree.read.isKnownRoot([toBytes32(root)]),
});

if (!r.ok) return rechazar(r.errors);   // ["attestation expired: ...", "rep_root not live: ..."]
mostrar(r.checks);                       // ["proof verified", "volume 1000 tokens+ moved", ...]
```

Omitir `decimalsOf` o `rootAlive` no rompe: la lib los saltea y **lo dice en `checks`**, para que
nadie crea que chequeó algo que no chequeó. `now` es la excepción: sin reloj se niega a verificar.

---

## 7. Cuatro trampas al mostrarlo

Las cuatro son fáciles de cometer y las cuatro difaman a alguien:

1. **Un campo oculto llega en cero.** Cuando el bit de la máscara está apagado, `out_volume` vale 0
   *por construcción*. Mostrarlo como "0 de volumen" es acusar a alguien de no haber operado nunca.
   Tiene que decir **no revelado**.
2. **Band 0 de volumen no es "cero".** Significa *menos de un lote*. Una cuenta nueva no es una
   cuenta que no movió nada.
3. **Los pisos no son cifras.** `count` y `volume_band` son cotas inferiores: mostralos con `≥`, o
   estás publicando como hecho algo que la prueba no dice.
4. **El cupo es concurrente.** El tier acota `inFlight + principal`, no el tamaño de un deal: "hasta
   1.000 USDC en juego a la vez", no "por deal".

---

## 8. Series entregadas

Un historial acá es **una secuencia que su dueño arma y entrega**, no algo que exista del lado de
nadie más. El árbol es la cadena: sus raíces son los bloques, y cada attestation es una foto de una
raíz — sin fecha propia. La fecha es tu recibo.

`circuits/js/lib/chain.ts` certifica lo entregado:

- una sola `handleCommit` en toda la serie (si no, son dos cuentas pegadas);
- los contadores crudos nunca bajan — `count` del listado y `out_count` del perfil son **el mismo
  contador**, y el castigo y el escalón de volumen tampoco bajan;
- el band de castigo de un listado no puede quedar **por debajo** de un castigo exacto que la misma
  serie ya reveló (al revés sí: exagerar es verdadero y sólo le cuesta al autor).

Y dos cosas que deliberadamente **no** hace:

- **No chequea el tier.** El tier baja cuando hay castigo, y una cadena honesta muestra exactamente
  eso. Exigirlo monótono rechazaría el caso honesto que el diseño quiere visible.
- **No pone precio a los huecos.** Cuánto vale un silencio de tres meses es tu política. El protocolo
  no codifica sospecha por ausencia.

---

## 9. Qué se ve y qué no

**No se ve:** quién es la persona, con qué wallet opera, cuáles deals de la chain son suyos, si el
handle tuvo otro nombre antes, cuánto tiene en bonds. Lo único que vincula un handle con una cuenta
es la prueba, y la emite su dueña.

**Sí se ve** (y se acepta, §3.15.8): montos, timings y eventos de cada deal; los fees; el
`dealSubject` de cada deal; los depósitos al vault con su wallet.

**El costo de esta capa, dicho:** cada campo público angosta el conjunto de anonimato. `count` y
`volume_band` juntos insinúan el ticket promedio. Y hay un caso que conviene tener presente: como el
castigo va crudo en el perfil y es un número poco común, **rotar el handle protege bien a una cuenta
limpia y peor a una sancionada** — dos perfiles del mismo dueño con el mismo castigo exacto
correlacionan. Es el precio directo de que el castigo no sea ocultable, y nos parece el correcto.

---

## 10. Lo que todavía no está

- **Un attestation ata `repRoot` pero no ata deployment.** Si vas a leer esta reputación desde otra
  dapp, chequeá la raíz contra el árbol canónico: contra un clon del contrato, una prueba
  perfectamente válida afirma sobre otro árbol. Hoy no hay identificador de deployment en los public
  inputs; agregarlo es un campo más y está anotado como pendiente.
- **La verificación corre el binario `bb` pineado.** Para un listado en browser falta el camino
  bb.js/WASM.
- **Nada de esto está desplegado con usuarios todavía.**

---

## 11. Dónde está cada cosa

```
circuits/crates/attest_base/        el listado: los tres pisos y el techo
circuits/crates/reveal_advanced/    el perfil: la máscara y el castigo crudo
circuits/crates/pluri_commitments/  tiers.nr — la tabla §3.14.7 y los dos bands
circuits/js/lib/verify.ts           consumer side: bb + los cuatro chequeos
circuits/js/lib/chain.ts            series entregadas
circuits/js/lib/tiers.ts            el twin JS de la tabla (volumeBand, penaltyBand, tierOf)
circuits/js/lib/account.ts          recuperar una cuenta desde el secreto y la chain
test/fixtures/proofs/ + vks/        pruebas y VKs comprometidas: no hace falta el toolchain para leer
```

```sh
cd circuits && nargo test --workspace   # 49 tests: cortes, cotas, y los negativos que importan
bun test circuits/js                    # 79: semántica del consumer, con bb real cuando está
```

El toolchain de Noir/Barretenberg está pineado por sha256 en [`circuits/README.md`](./circuits/README.md).
CI no lo necesita: las pruebas viajan comprometidas.
