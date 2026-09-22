# Evaluación PluriSwap — espíritu, diseño, implementación

Revisión completa del 2026-09-22, sobre `4db4d68` (F4 cerrada). Cubre `PLURISWAP.md`, el kernel,
las libraries, los paquetes públicos y privados, los circuitos, el pool, el CI y la suite.
Suite corrida en el momento de la revisión: **558 pass / 0 fail / 10 skipped**.

Todo lo que se afirma acá está verificado contra el bytecode o contra un test adversarial escrito
para la revisión, no contra la spec. Donde hay un número medido, dice cómo se midió.

Este documento es un registro de trabajo, no doctrina: las decisiones que salgan de acá viven en la
Parte IV de `PLURISWAP.md`. Cada ítem se tacha acá cuando cierra, con el commit que lo cerró.

---

## Veredicto

La calidad de ingeniería es alta y —lo que es raro— **el bytecode respeta el espíritu escrito**.
`Escrow.sol` no tiene owner, no tiene pausa, el constructor está vacío, `_close` es credit-first,
`runPostTerminal` es idempotente de verdad, y la ley de TDD se ve en el historial.

Hay dos brechas estructurales:

1. Entre **lo que el protocolo protege** y **lo que promete** (la discusión A).
2. Entre **lo que está probado** y **lo que está desplegado** (la capa privada entera).

La segunda es trabajo. La primera es una decisión de diseño que todavía no se tomó.

---

## Low hanging fruit

### LHF-1 — `PoseidonT3` no entra en EIP-170; el gate de CI está rojo

```
PoseidonT3  runtime 29,315 B   margin −4,739 B
```

El gate de `.github/workflows/ci.yml` aborta con cualquier contrato de margen negativo, y con
`forge 1.5.1` (la versión pineada) `PoseidonT3` aparece en ese JSON. Los tests pasan porque el EVM
de Foundry no aplica EIP-170 en despliegues de test; Arbitrum sí.

Probado con `runs=1` y `runs=200` bajo `via_ir`: 29,314 / 29,315. El build canónico de upstream sí
entra (initcode pre-firmado de 23,548 B). Fix: no compilar la library en este árbol — usar el
deployment determinístico `0x3333333C0A88F9BE4fd23ed0536F9B6c427e3B93`, como se hizo con `verifiers/`.

**Estado: CERRADO** (2026-09-22, Parte IV). `src/packages/libraries/Poseidon.sol` llama el deployment de
upstream por address y selector; las direcciones se derivan por `CREATE2(0x4e59…, salt, initcode)` del
submodule pineado (`bun poseidon:fixture`, con gate de drift en CI), `script/Poseidon.s.sol` las asegura
en una chain nueva, y toda ruta de hash falla cerrada (`PoseidonUnavailable`) donde el singleton no está.
El gate de bytecode queda en cero contratos por encima del límite. Efecto colateral medido: el build
canónico es mucho más barato que el nuestro —

| | antes | ahora |
| --- | ---: | ---: |
| `insert` depth 32 (primero / siguientes) | 2,23M / 1,3M | **0,93M / 0,65M** |
| deploy del árbol | 1,33M | **1,04M** |
| bundle privado de 3 prepares (un lado) | 9,73M | **7,64M** |

Queda pendiente sólo el resto externo: `PoseidonT2` todavía no está en Arbitrum (sí `PoseidonT3`, en One
y Sepolia), así que el deploy de la capa privada arranca corriendo ese script — se enlaza con LHF-2.

### LHF-2 — La capa privada no tiene deploy script ni deployment

`script/` no menciona `Private*` ni `Poseidon`. `deployments/` no tiene nada privado. El lab tampoco
la conoce. F1–F4 están cerradas *en tests*: la capa que es el valor central del producto nunca tocó
una chain. Es el gap más barato de cerrar y el que más información devuelve (gas real, tamaños
reales, LHF-5).

**Estado:** abierto.

### LHF-3 — Los relojes en cero son un arma cargada sin seguro

Verificado con tests propios:

- `releaseDuration = 0` → el Provider hace `markFiat` + `claim` **en el mismo bloque**, sin fiat y sin
  ventana de disputa. `CLAIMED`, 100% al Provider.
- `fiatDuration = 0` → cualquiera cancela al instante; el Provider que ya pagó fiat se queda sin nada.

El kernel lo permite por diseño (§3.8, "único bound: `duration >= 0`"). Pero el lab no advierte nada:
`ConsentPanel.ts` son dos `<input>` de texto con defaults 3600/1800 — y 1800 s para una transferencia
bancaria ya es de por sí muy pro-Provider. Una librería `SaneTerms` del lado cliente más un warning
duro en el firmador cuesta una tarde.

**Estado:** abierto.

### LHF-4 — `ROOT_HISTORY = 64` es demasiado chico para un árbol compartido

`src/packages/PoseidonTree.sol:19`. El árbol de cuentas es global: cada `prepare` y cada `claim`
insertan una hoja. Un deal con reputación de dos lados son ~4 inserts. A 64 raíces un proof queda
stale después de **16 deals** — en Arbitrum, potencialmente menos de un minuto entre generar el proof
y landearlo. Es una constante inmutable por deployment: cambiarla ahora cuesta cero.

**Estado: CERRADO** (2026-09-22, Parte IV). Subir la constante sola no alcanzaba: `isKnownRoot`
escaneaba la ventana entera —**139.630 gas medidos** con N=64, lineal desde ahí— en el camino caliente
de siete call sites on-chain, así que una ventana más grande se pagaba a sí misma. Van los dos cambios
juntos: membership por mapping (el ring queda sólo para la evicción) → **3.854 gas**, constante en la
ventana; y `rootHistory` pasa a parámetro inmutable por árbol, acotado a [64, 65536], con default de
protocolo 4096 (~1000 deals de tolerancia). Costo: +6% en el insert (633.927 → 672.018 a depth 32),
que corre ~4 veces por deal contra 6–8 lecturas. Los circuitos no cambian: la prueba sigue siendo
contra *una* raíz; quién la acepta es del contrato. Que agrandar no debilita nada quedó explícito en
§3.15.3 — la ventana es liveness, el replay lo cortan los nullifiers.

### LHF-5 — El bundle de activación privada es enorme

Medido con proofs reales instrumentando `test/VaultRealProof.t.sol`:

```
BUNDLE 3-prepare gas (un solo lado): 7,638,535   (9,729,712 antes de cerrar LHF-1)
```

Un deal privado de dos lados exige los seis prepares **más** `activate` en una sola tx atómica
(§3.15.4): **~15M de gas** y ~54 KB de calldata (seis proofs UltraHonk de ~9 KB cada uno,
`test/fixtures/proofs/*.json`). Para un deal T1 con cap de 250 USDC, el costo de la privacidad puede
acercarse al valor del trade. No es un bug: es consecuencia del diseño atómico. Pero es un dato que
falta al lado de las cotas de gas de `verify` en §3.15.11, porque decide si la capa privada es usable
en el segmento que más la necesita.

**Estado:** abierto.

### LHF-6 — Kleros: whitelist y pineado son camino crítico y son externos

`openCourt` revierte en Arbitrum One hasta que la gobernanza de Kleros liste el adapter: semanas de
calendario ajeno. `KLEROS_POLICY.md` está listo para pinear. Empezar el trámite ahora, no al final.

**Estado:** abierto (externo).

### LHF-7 — El verifier del slot ZK del kernel sigue siendo un mock

`VerifierMock` acepta cualquier `abi.encode(dealId, nullifier)`. Once circuitos Noir construidos,
ninguno es el *payment proof*. No es una tarea: es la decisión de prioridad de la discusión B.

**Estado:** abierto.

### LHF-8 — Warts menores

- El lab ofrece `markFiat`/`claim`/`openDisputed` en deals ZK; revierten `EdgeOff` (§5.6).
- `attest_base`/`reveal_advanced` solo se verifican corriendo el binario `bb` pineado. Para un listado
  en browser falta el path bb.js/WASM.
- `postPending` de reputación nunca llega a cero si el módulo rechaza permanentemente
  (`AlreadyPending`). Es deliberado (§3.12.4), pero no hay evento ni métrica que lo exponga.

**Estado:** abierto.

---

## Las discusiones largas

### A. El stalemate 50/50 le paga al que no puso nada, y el Provider no tiene escalación

Verificado con un test adversarial:

```
Provider paga fiat → markFiat
Controller abre DISPUTED (gratis en Core, ~1% con el paquete oficial)
Provider intenta openCourt  → revert (Unauthorized; §3.12.2: "Sólo el Controller abre corte")
Provider intenta claim      → revert (DISPUTED mata el claim)
Provider fuerza stalemate   → STALEMATE, holderAmt 500000, providerAmt 500000
```

El máximo que un Provider que **cumplió al 100%** puede forzar unilateralmente es el 50%. El camino
hacia ahí es unilateral y barato para el otro lado: `openDisputed` es una opción sin bond que
convierte una victoria del Provider en un 50/50. Con BONDS el atacante pierde su 10% y sigue ganando
~40% del principal. Con ARBITRATION seleccionada **tampoco cambia**: abrir corte también es
Controller-only, así que el Controller controla el freeze *y* la escalación.

El principio II.6 lo justifica con *"ambas partes tenían salida y ninguna la tomó"*. Pero la única
salida del Provider requiere la firma de su contraparte. La simetría que justifica el 50/50 no existe.

Y el 50/50 no es neutral en un escrow: el Holder puso el 100% del capital, el Provider puso cero
on-chain. Un default de 50/50 en un he-said-she-said transfiere sistemáticamente valor del que
custodia al que reclama, en las dos direcciones.

Salidas posibles, ninguna gratis:

1. **Dejar que el Provider abra corte** (bump de kernel). La más directa y la que menos rompe el
   espíritu: el catálogo de rulings sigue cerrado, el adapter sigue sin mover custodia.
2. **Bonds simétricos y grandes** (≥50%) como condición del set oficial. Mata el ataque
   económicamente y mata también el acceso: un T1 con cap 250 tendría que trabar 125.
3. **Stalemate no-50/50**, función de quién tenía la carga. Más honesto respecto de "el dinero se
   mueve con culpa probada", pero abre otros juegos.
4. **Declarar Core-only no apto para trade real** y hacer ARBITRATION o ZK efectivamente obligatorias
   en el set oficial. Coherente con la arquitectura opt-in, pero choca de frente con II.2
   (*"Core no es un modo degradado: es el recinto"*).

Hoy Core **sí** es un modo degradado y la spec dice lo contrario. Esa es la entrada que falta en la
Parte IV.

### B. El único cuadrante limpio es el que no está construido

`PAYMENT_PROOF` (§3.12.1) es el único perfil sin 50/50: proof → `RELEASED`, sin proof → `CANCELLED`.
Determinista, pre-acordado, sin tribunal, sin doxxeo. Es la respuesta a la discusión A.

Y es lo único que no tiene circuito. Once circuitos Noir para reputación privada, bonds privados y
attestations; cero para probar un pago fiat. La razón es entendible (zkEmail / TLSNotary sobre rails
que cambian es lo más difícil del stack), pero la consecuencia estratégica es dura: **el esfuerzo de
privacidad se invirtió en ocultar la reputación, que es el activo menos valioso, mientras el
mecanismo que elimina la disputa sigue en mock.**

### C. La raíz anti-sybil contradice el motivo del protocolo

La Parte I.2 existe contra el KYC y el debanking. La raíz de humanidad es Human Passport: un decoder
**proxy upgradeable y pausable de un tercero** (`0x2050…B43`), cuyos stamps de mayor peso vienen
justamente de exchanges centralizados y proveedores de identidad.

- **Kill switch externo declarado.** Passport puede pausar el decoder y congelar toda admisión nueva.
  Está en §5.6 como hallazgo abierto; para un protocolo cuya tesis es "nadie puede cerrar el recinto",
  es una contradicción viva. El vault privado la elimina para `withdraw`, no para `enroll`.
- **El conjunto de anonimato es el padrón de enrolados.** Con montos, timings, token y `dealSubject`
  públicos (§3.15.8), la desvinculación es una propiedad de multitud. Con 200 cuentas registradas no
  hay privacidad. Eso no es crítica al diseño: es una condición de lanzamiento que debería estar
  escrita — *por debajo de N cuentas, el modelo de amenaza de §3.15.8 no aplica*.

### D. Disputar te doxxea, y el que se doxxea es la víctima

"Disputar = salir a la luz" (II.4) está aceptado como decisión. Operativamente: la evidencia de Kleros
es pública, permanente y en IPFS, y la evidencia que gana un caso de pago fiat *es* un extracto
bancario con nombre, cuenta y fechas. Quien la publica es la parte estafada. `KLEROS_POLICY.md` pide
redactar lo innecesario, pero lo necesario ya identifica a la persona.

El protocolo protege tu privacidad en todos los deals que salen bien y te la quita exactamente cuando
te estafan. Para el mercado objetivo declarado es el peor momento posible para aparecer en un registro
público permanente. ¿Evidencia sellada? ¿Committee? ¿Pruebas ZK de propiedades del recibo?

### E. No hay mercado

Motor de settlement extraordinario, sin auto. No hay capa de descubrimiento, order book, matching ni
canal de comunicación. Labs es read-only por diseño y explícitamente "sin matching" (Parte IV,
2026-09-20). El "listado" aparece en §3.15.7 como consumidor de attestations, pero ningún componente
lo implementa.

Los competidores directos son 90% marketplace y 10% escrow. La decisión de que Labs no haga matching
es legalmente coherente, pero deja un agujero que alguien va a llenar — y quien lo llene se convierte
en la plataforma de facto que el protocolo dice no tener. Conviene decidir a propósito quién es ese.

### F. Pérdida de `sk_id` = pérdida total, sin recuperación

Listado como riesgo abierto ("recuperación = trabajo futuro"). Para "toda la humanidad" no es un
riesgo abierto: es descalificante a escala. Perder el secreto pierde reputación **y** los bonds
depositados. Cualquier producto de consumo pierde 1–5% de usuarios por año a claves perdidas. Social
recovery sobre `sk_id`, o al menos separar custodia del bond de custodia de la identidad, es
arquitectura, no UX.

### G. Farmeo de reputación por auto-trading

El score es `successCount + volume/UNIT − penalty`. Un deal entre dos wallets propias con dos juegos
de stamps disjuntos genera `+1/+1` a **ambos** sujetos y el principal vuelve a casa; el costo es gas
más `activationFee`. Cinco vueltas de 250 → score 10 → T2. La raíz anti-sybil limita cuántas
identidades, no cuántas veces te tradeás a vos mismo. El keying por token ayuda pero no cierra.

### H. Neutralidad del kernel vs. plataforma de facto

El argumento legal del kernel muerto es sólido. Pero el conjunto real que un usuario toca es:
paquetes oficiales de Labs + frontend de Labs + backend de Labs + fees a la DAO. La neutralidad
protege a `Escrow.sol`; no está claro que proteja a Labs, que por diseño "absorbe la exposición legal
que el kernel no puede tener". Asegurarse de que Labs sepa cuánta exposición absorbe, en qué
jurisdicción, antes del mainnet.

---

## Orden de ataque propuesto

1. LHF-1 (CI verde), LHF-4 (constante), LHF-2 (capa privada en Sepolia), LHF-6 (arrancar el trámite).
2. LHF-3 (guardas de reloj en el lab), LHF-5 (medir el bundle de dos lados en Sepolia, número a la spec).
3. **Antes de cualquier otra cosa:** abrir la discusión A con una entrada nueva en la Parte IV. No se
   puede auditar ni lanzar un escrow cuyo equilibrio de disputa le paga el 50% al que defecciona.
4. Después: decidir si el próximo circuito es un payment proof de un rail fiat real (discusión B).
