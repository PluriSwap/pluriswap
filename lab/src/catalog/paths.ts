export type PathNeed = "core" | "packages" | "labVerbs" | "zkArb" | "pool" | "ramp";

export type SpaceId =
  | "guide"
  | "recinto"
  | "deal"
  | "consent"
  | "packages"
  | "pool"
  | "credits"
  | "catalog"
  | "lab"
  | "ramp";

export type Seat = "Holder" | "Provider" | "Controller" | "Relayer" | "anyone" | "LAB" | "Pool";

/** Un paso = una tx (o una firma). El Path no oculta la matriz: solo resalta el verbo. */
export type PathStep = {
  /** Nombre on-chain del verbo o acción (`markFiat`, `sign HA`, `setHuman`…). */
  verb: string;
  /** Asiento que debe ser msg.sender (o firmante). */
  seat: Seat;
  /** Espacio de la consola donde se ejecuta. */
  space: SpaceId;
  /** Qué observar después. */
  expect?: string;
  /** Advertencia o detalle. */
  note?: string;
};

export type PathGroup = "core" | "dual-sign" | "negativo" | "paquetes" | "tribunal" | "pool" | "rampa";

export type PathTemplate = {
  id: string;
  group: PathGroup;
  /** Qué enseña este Path, en una frase. */
  teaches: string;
  recintoHint: string;
  fiatDuration: string;
  releaseDuration: string;
  disputeDuration: string;
  arbitrationDuration: string;
  p2p: boolean;
  needs: PathNeed[];
  /** Resumen de una línea (compat). */
  sequence: string;
  assertion: string;
  steps: PathStep[];
};

const T = (f: string, r: string, d: string, a = "0") => ({
  fiatDuration: f,
  releaseDuration: r,
  disputeDuration: d,
  arbitrationDuration: a,
});

const STD = T("3600", "1800", "7200");
const DISPUTE = T("3600", "100", "7200");

const activateP2P: PathStep[] = [
  { verb: "approve(escrow, principal)", seat: "Holder", space: "lab", note: "El digest no cubre el approve. Sin allowance: InexactPull." },
  { verb: "sign HolderAuthorization", seat: "Holder", space: "consent" },
  { verb: "sign ProviderAgreement", seat: "Provider", space: "consent" },
  { verb: "activate (6 args, CA dummy)", seat: "Relayer", space: "consent", expect: "status = FUNDED" },
];

const markFiat: PathStep = { verb: "markFiat", seat: "Provider", space: "deal", expect: "FIAT_SENT; arranca releaseDuration" };

const dual = (type: string, from: string, to: string, bps?: string): PathStep[] => [
  { verb: `compose ${type}${bps ? ` providerBps=${bps}` : ""}`, seat: "anyone", space: "deal", note: `Desde ${from}. Mismo dealId y deadline en ambas copias.` },
  { verb: `sign ${type} (P)`, seat: "Provider", space: "deal" },
  { verb: `sign ${type} (C)`, seat: "Controller", space: "deal", note: "P2P: el Controller es el Holder." },
  { verb: `relay ${type[0]!.toLowerCase()}${type.slice(1)}`, seat: "Relayer", space: "deal", expect: to },
];

/** LAB_UI.md §7. CASE-CORE-11 never clones zeros into releaseDuration. */
export const PATHS: PathTemplate[] = [
  {
    id: "PATH-CORE-ONLY",
    group: "core",
    teaches: "Core-only es un modo, no un deal al que le faltan paquetes: packageIds = [], kinds = 0, un solo pull.",
    recintoHint: "sepolia.json / 31337.json",
    ...STD,
    p2p: true,
    needs: ["core"],
    sequence: "packageIds=[] activate P2P 6-arg dummy CA",
    assertion: "kinds==0, subjects==0",
    steps: [...activateP2P, { verb: "inspeccionar kinds / subjects", seat: "anyone", space: "deal", expect: "kinds = 0, subjects = 0x0" }],
  },
  {
    id: "CASE-CORE-01-P2P",
    group: "core",
    teaches: "Dos firmas bastan cuando holder == controller. El kernel igual recibe una CA vacía (overload de 6 args).",
    recintoHint: "core + su testToken",
    ...STD,
    p2p: true,
    needs: ["core"],
    sequence: "HA+PA, dummy CA, activate",
    assertion: "FUNDED",
    steps: activateP2P,
  },
  {
    id: "CASE-CORE-01-CTRL",
    group: "core",
    teaches: "Con Controller distinto hay tres envelopes y tres nonces consumidos; el dealId incluye controllerNonce.",
    recintoHint: "core",
    ...STD,
    p2p: false,
    needs: ["core"],
    sequence: "HA+PA+CA hashed",
    assertion: "FUNDED, 3 used",
    steps: [
      { verb: "approve(escrow, principal)", seat: "Holder", space: "lab" },
      { verb: "sign HolderAuthorization", seat: "Holder", space: "consent" },
      { verb: "sign ProviderAgreement", seat: "Provider", space: "consent" },
      { verb: "sign ControllerAcceptance", seat: "Controller", space: "consent", note: "Real, no dummy." },
      { verb: "activate (6 args, CA real)", seat: "Relayer", space: "consent", expect: "FUNDED; used = true para los tres" },
    ],
  },
  {
    id: "CASE-CORE-02",
    group: "core",
    teaches: "markFiat no mueve plata: solo declara y arranca el reloj del Controller.",
    recintoHint: "core",
    ...STD,
    p2p: true,
    needs: ["core"],
    sequence: "markFiat",
    assertion: "FIAT_SENT",
    steps: [...activateP2P, markFiat],
  },
  {
    id: "CASE-CORE-03",
    group: "core",
    teaches: "El Provider puede bajarse antes de pagar; el Holder recupera el 100% sin fee.",
    recintoHint: "core",
    ...STD,
    p2p: true,
    needs: ["core"],
    sequence: "cancelByProvider",
    assertion: "CANCELLED, holderAmt=principal",
    steps: [...activateP2P, { verb: "cancelByProvider", seat: "Provider", space: "deal", expect: "CANCELLED; holderAmt = principal" }],
  },
  {
    id: "CASE-CORE-04",
    group: "core",
    teaches: "duration = 0 hace un requireDue exigible en el mismo bloque: no hace falta warp para probar timeoutFiat.",
    recintoHint: "core",
    ...T("0", "1800", "7200"),
    p2p: true,
    needs: ["core"],
    sequence: "timeoutFiat due inmediato",
    assertion: "CANCELLED",
    steps: [...activateP2P, { verb: "timeoutFiat", seat: "anyone", space: "deal", expect: "CANCELLED; el Holder recupera todo" }],
  },
  {
    id: "CASE-CORE-05",
    group: "dual-sign",
    teaches: "Dual-sign = dos envelopes + una tx de Relayer. Funciona ya en FUNDED.",
    recintoHint: "core",
    ...STD,
    p2p: true,
    needs: ["core"],
    sequence: "composer mutualCancel FUNDED",
    assertion: "CANCELLED",
    steps: [...activateP2P, ...dual("MutualCancel", "FUNDED", "CANCELLED")],
  },
  {
    id: "CASE-CORE-06",
    group: "core",
    teaches: "El camino feliz: markFiat → release. Con Reputation, acá se cobra el completion fee sobre el total.",
    recintoHint: "core",
    ...STD,
    p2p: true,
    needs: ["core"],
    sequence: "markFiat → release",
    assertion: "RELEASED; Core-only providerAmt=principal",
    steps: [...activateP2P, markFiat, { verb: "release", seat: "Controller", space: "deal", expect: "RELEASED; providerAmt = principal (Core-only)" }],
  },
  {
    id: "CASE-CORE-07",
    group: "core",
    teaches: "Si el Controller no responde, el Provider cobra igual: CLAIMED. releaseDuration = 0 lo hace inmediato (y openDisputed queda TooLate).",
    recintoHint: "core",
    ...T("3600", "0", "7200"),
    p2p: true,
    needs: ["core"],
    sequence: "markFiat → claim due inmediato",
    assertion: "CLAIMED; providerAmt=principal (Core-only). Con reputación: completion fee sobre el pot, Provider Peaceful, Holder Silent",
    steps: [
      ...activateP2P,
      markFiat,
      { verb: "mirar la matriz", seat: "anyone", space: "deal", expect: "claim ENABLED (due), openDisputed TooLate" },
      { verb: "claim", seat: "anyone", space: "deal", expect: "CLAIMED; providerAmt = principal" },
    ],
  },
  {
    id: "CASE-CORE-08",
    group: "dual-sign",
    teaches: "mutualCancel también deshace un deal ya en FIAT_SENT.",
    recintoHint: "core",
    ...STD,
    p2p: true,
    needs: ["core"],
    sequence: "composer mutualCancel FIAT_SENT",
    assertion: "CANCELLED",
    steps: [...activateP2P, markFiat, ...dual("MutualCancel", "FIAT_SENT", "CANCELLED")],
  },
  {
    id: "CASE-CORE-09",
    group: "dual-sign",
    teaches: "mutualSplit reparte: fee sobre el total primero, después providerBps del resto.",
    recintoHint: "core",
    ...STD,
    p2p: true,
    needs: ["core"],
    sequence: "composer split bps=2500",
    assertion: "RESOLVED_SPLIT",
    steps: [...activateP2P, markFiat, ...dual("MutualSplit", "FIAT_SENT", "RESOLVED_SPLIT; providerAmt = 25%", "2500")],
  },
  {
    id: "CASE-CORE-10",
    group: "dual-sign",
    teaches: "coSignedRelease libera con dos firmas, sin esperar al Controller solo.",
    recintoHint: "core",
    ...STD,
    p2p: true,
    needs: ["core"],
    sequence: "composer coSignedRelease",
    assertion: "RELEASED",
    steps: [...activateP2P, markFiat, ...dual("CoSignedRelease", "FIAT_SENT", "RELEASED")],
  },
  {
    id: "CASE-CORE-11",
    group: "core",
    teaches: "openDisputed es strictly-before: exige releaseDuration > 0. Con 100 s hay ventana; con 0 está cerrada desde el primer bloque.",
    recintoHint: "core",
    ...DISPUTE,
    p2p: true,
    needs: ["core"],
    sequence: "openDisputed strictly-before",
    assertion: "DISPUTED. releaseDuration no es 0",
    steps: [
      ...activateP2P,
      markFiat,
      { verb: "openDisputed", seat: "Controller", space: "deal", expect: "DISPUTED; arranca disputeDuration", note: "Antes de 100 s. En Anvil, si te pasaste, ya es TooLate: nuevo deal." },
    ],
  },
  {
    id: "CASE-CORE-12",
    group: "dual-sign",
    teaches: "Una disputa se puede deshacer por acuerdo.",
    recintoHint: "core",
    ...DISPUTE,
    p2p: true,
    needs: ["core"],
    sequence: "composer mutualCancel DISPUTED",
    assertion: "CANCELLED",
    steps: [...activateP2P, markFiat, { verb: "openDisputed", seat: "Controller", space: "deal" }, ...dual("MutualCancel", "DISPUTED", "CANCELLED")],
  },
  {
    id: "CASE-CORE-13",
    group: "dual-sign",
    teaches: "Una disputa se puede cerrar liberando.",
    recintoHint: "core",
    ...DISPUTE,
    p2p: true,
    needs: ["core"],
    sequence: "composer coSigned DISPUTED",
    assertion: "RELEASED",
    steps: [...activateP2P, markFiat, { verb: "openDisputed", seat: "Controller", space: "deal" }, ...dual("CoSignedRelease", "DISPUTED", "RELEASED")],
  },
  {
    id: "CASE-CORE-14",
    group: "dual-sign",
    teaches: "Una disputa se puede cerrar partiendo.",
    recintoHint: "core",
    ...DISPUTE,
    p2p: true,
    needs: ["core"],
    sequence: "composer split bps=4000",
    assertion: "RESOLVED_SPLIT",
    steps: [...activateP2P, markFiat, { verb: "openDisputed", seat: "Controller", space: "deal" }, ...dual("MutualSplit", "DISPUTED", "RESOLVED_SPLIT; providerAmt = 40%", "4000")],
  },
  {
    id: "CASE-CORE-15",
    group: "core",
    teaches: "Disputa vencida sin acuerdo ni tribunal: 50/50 y ambos bonds quemados. disputeDuration = 0 lo hace inmediato.",
    recintoHint: "core",
    ...T("3600", "100", "0"),
    p2p: true,
    needs: ["core"],
    sequence: "openDisputed luego forceStalemate due",
    assertion: "STALEMATE 50/50",
    steps: [
      ...activateP2P,
      markFiat,
      { verb: "openDisputed", seat: "Controller", space: "deal", note: "Dentro de los 100 s." },
      { verb: "forceStalemate", seat: "anyone", space: "deal", expect: "STALEMATE; holderAmt = providerAmt = principal/2" },
    ],
  },
  {
    id: "CASE-CORE-16",
    group: "negativo",
    teaches: "La matriz no oculta lo ilegal: release y claim en DISPUTED se ven con WrongStatus.",
    recintoHint: "core",
    ...DISPUTE,
    p2p: true,
    needs: ["core"],
    sequence: "release/claim en DISPUTED",
    assertion: "matriz WrongStatus",
    steps: [
      ...activateP2P,
      markFiat,
      { verb: "openDisputed", seat: "Controller", space: "deal" },
      { verb: "leer release / claim en la matriz", seat: "anyone", space: "deal", expect: "DISABLED Escrow.WrongStatus (no se envían)" },
    ],
  },
  {
    id: "CASE-CORE-17",
    group: "negativo",
    teaches: "Un terminal es terminal: todo verbo de estado proyecta WrongStatus.",
    recintoHint: "core",
    ...STD,
    p2p: true,
    needs: ["core"],
    sequence: "verbo de estado en terminal",
    assertion: "WrongStatus",
    steps: [
      ...activateP2P,
      { verb: "cancelByProvider", seat: "Provider", space: "deal", expect: "CANCELLED" },
      { verb: "leer la matriz", seat: "anyone", space: "deal", expect: "todo WrongStatus salvo withdraw / cancelNonce" },
    ],
  },
  {
    id: "PATH-TRIO",
    group: "paquetes",
    teaches: "Passport + Reputation + Bonds: identify, cap, lock del 10%, activationFee en activate y completionFee en release.",
    recintoHint: "packages + su testToken",
    ...STD,
    p2p: true,
    needs: ["packages", "labVerbs"],
    sequence: "LAB setHuman ×2, vault.deposit, slots P+R+B, activate, markFiat, release",
    assertion: "activationFee; completionFee en release; Peaceful; bonds unlock",
    steps: [
      { verb: "PassportMock.setHuman(holder)", seat: "LAB", space: "lab", note: "Mock sin auth. No es humanidad." },
      { verb: "PassportMock.setHuman(provider)", seat: "LAB", space: "lab" },
      { verb: "mint + approve(vault)", seat: "LAB", space: "lab" },
      { verb: "vault.deposit(subject, token, ≥ (principal+9)/10)", seat: "Holder", space: "lab", note: "Ambos sujetos necesitan bond disponible." },
      { verb: "pegar slots passport / reputation / bonds", seat: "anyone", space: "packages", expect: "3 ids match; peer OK; operator == escrow" },
      { verb: "approve(escrow, principal + activationFee)", seat: "Holder", space: "lab" },
      { verb: "sign HA + PA", seat: "Holder", space: "consent" },
      { verb: "activate (7 args)", seat: "Relayer", space: "consent", expect: "FUNDED; kinds = 7; locks en el vault" },
      markFiat,
      { verb: "release (no claim)", seat: "Controller", space: "deal", expect: "RELEASED; providerAmt = principal − completionFee; bonds unlock" },
    ],
  },
  {
    id: "PATH-ZK-PROOF",
    group: "paquetes",
    teaches: "Con ZK el pago se demuestra con verifyProof; markFiat / claim / openDisputed quedan EdgeOff.",
    recintoHint: "packages",
    ...STD,
    p2p: true,
    needs: ["packages", "labVerbs", "zkArb"],
    sequence: "slot ZK, FUNDED, LAB abi.encode(dealId,nullifier), verifyProof",
    assertion: "RELEASED; markFiat EdgeOff",
    steps: [
      { verb: "pegar slot zk", seat: "anyone", space: "packages", expect: "id match; operator == escrow" },
      ...activateP2P.map((s) => (s.verb.startsWith("activate") ? { ...s, verb: "activate (7 args)", expect: "FUNDED; kinds = 8" } : s)),
      { verb: "leer la matriz", seat: "anyone", space: "deal", expect: "markFiat / claim / openDisputed = EdgeOff; timeoutFiat sigue" },
      { verb: "ensamblar abi.encode(dealId, nullifier)", seat: "LAB", space: "lab", note: "VerifierMock. No es un circuito." },
      { verb: "verifyProof", seat: "anyone", space: "deal", expect: "RELEASED; verifyFee al módulo" },
    ],
  },
  {
    id: "PATH-ZK-TIMEOUT",
    group: "paquetes",
    teaches: "KERNEL-04: un deal ZK sin proof igual se cancela por timeout. Sin fee del módulo.",
    recintoHint: "packages",
    ...T("0", "1800", "7200"),
    p2p: true,
    needs: ["packages", "zkArb"],
    sequence: "ZK, timeoutFiat",
    assertion: "CANCELLED, sin fee ZK",
    steps: [
      { verb: "pegar slot zk", seat: "anyone", space: "packages" },
      ...activateP2P.map((s) => (s.verb.startsWith("activate") ? { ...s, verb: "activate (7 args)" } : s)),
      { verb: "timeoutFiat", seat: "anyone", space: "deal", expect: "CANCELLED; holderAmt = principal" },
    ],
  },
  {
    id: "PATH-ARB-MOCK",
    group: "tribunal",
    teaches: "openCourt kernel → impl. El mock cobra courtFee en ERC-20 al court (approve al módulo, no al escrow); msg.value = 0.",
    recintoHint: "packages",
    ...T("3600", "1800", "7200", String(86_400)),
    p2p: true,
    needs: ["packages", "labVerbs", "zkArb"],
    sequence: "court=ArbitrationMock; approve court; msg.value=0; markFiat; openCourt; LAB submitRuling; readRuling",
    assertion: "arbitrationDuration=1 days, no mezclar con disputeDuration",
    steps: [
      { verb: "pegar slot court (ArbitrationMock)", seat: "anyone", space: "packages", expect: "id match; operator == escrow" },
      ...activateP2P.map((s) => (s.verb.startsWith("activate") ? { ...s, verb: "activate (7 args)", expect: "FUNDED; kinds = 16" } : s)),
      markFiat,
      { verb: "approve(court, courtFee)", seat: "Controller", space: "lab", note: "Sin esto la matriz proyecta InexactPull." },
      { verb: "openCourt (msg.value = 0)", seat: "Controller", space: "deal", expect: "ARBITRATION_ACTIVE" },
      { verb: "ArbitrationMock.submitRuling(dealId, 1|2|3)", seat: "LAB", space: "lab", note: "Sin auth. No es un tribunal." },
      { verb: "readRuling", seat: "anyone", space: "deal", expect: "RESOLVED_BY_ARBITRATION (1|2) o STALEMATE (3)" },
    ],
  },
  {
    id: "PATH-KLEROS",
    group: "tribunal",
    teaches: "Kleros V2 real: PluriSwap abre el caso con msg.value = arbitrationCost exacto y después solo lee la sentencia. La evidencia va por la dapp de Kleros.",
    recintoHint: "kleros-packages",
    ...T("3600", "1800", "7200", String(7 * 86_400)),
    p2p: true,
    needs: ["packages", "zkArb"],
    sequence: "P2P dummy CA; kernel() vs Recinto; msg.value == arbitrationCost; markFiat; openCourt",
    assertion: "ARBITRATION_ACTIVE; no submitRuling",
    steps: [
      { verb: "pegar slot court (KlerosAdapter)", seat: "anyone", space: "packages", expect: "kernel() == Recinto (no hay operator)" },
      ...activateP2P.map((s) => (s.verb.startsWith("activate") ? { ...s, verb: "activate (7 args)" } : s)),
      markFiat,
      { verb: "openCourt {value: arbitrationCost(extraData)}", seat: "Controller", space: "deal", expect: "ARBITRATION_ACTIVE; DisputeRequest emitido" },
      { verb: "evidencia y votación en court.kleros.io", seat: "anyone", space: "deal", note: "Fuera de PluriSwap." },
      { verb: "readRuling", seat: "anyone", space: "deal", expect: "RESOLVED_BY_ARBITRATION o STALEMATE" },
    ],
  },
  {
    id: "PATH-POOL-HOLDER",
    group: "pool",
    teaches: "Un pool es Holder con los mismos DealTerms: holderSig vacío (EIP-1271), Controller agente distinto ⇒ CA real.",
    recintoHint: "pool.json cuyo escrow == Recinto",
    ...STD,
    p2p: false,
    needs: ["pool"],
    sequence: 'deposit; authorize(ha); holder=pool; holderSig=""; CA hashed; PA; markFiat; release; reconcile',
    assertion: "Holder=pool; dummy CA revierte",
    steps: [
      { verb: "pool.deposit", seat: "Holder", space: "pool", note: "LP deposita idle." },
      { verb: "componer terms con holder = pool, controller = agente", seat: "anyone", space: "consent" },
      { verb: "pool.authorize(ha)", seat: "Controller", space: "pool", expect: "idle → locked; 1271 aceptará el digest" },
      { verb: "sign ProviderAgreement", seat: "Provider", space: "consent" },
      { verb: "sign ControllerAcceptance", seat: "Controller", space: "consent", note: "Real: holder != controller." },
      { verb: 'activate (holderSig = "")', seat: "Relayer", space: "consent", expect: "FUNDED; Holder = pool" },
      markFiat,
      { verb: "release", seat: "Controller", space: "deal", expect: "RELEASED" },
      { verb: "pool.reconcile(nonce, nonceP, nonceC)", seat: "anyone", space: "pool", expect: "locked → consumed" },
    ],
  },
  {
    id: "PATH-RAMP-TAXI",
    group: "rampa",
    teaches: "La rampa es taxi-only: quote/send de USDC después del deal. No hay compose → activate.",
    recintoHint: "ramp.json (USDC, no TestToken)",
    ...STD,
    p2p: true,
    needs: ["ramp"],
    sequence: "deal Core con USDC ya en Holder, release, IRamp.send",
    assertion: "sin compose",
    steps: [
      ...activateP2P.map((s) => ({ ...s, note: s.verb.startsWith("approve") ? "Token = USDC del ramp.json." : s.note })),
      markFiat,
      { verb: "release", seat: "Controller", space: "deal", expect: "RELEASED" },
      { verb: "withdraw si quedó crédito", seat: "Provider", space: "credits" },
      { verb: "quote → send", seat: "Provider", space: "ramp", expect: "nativeFee y amountOut; sin estado Core" },
    ],
  },
  {
    id: "PATH-DRIFT",
    group: "negativo",
    teaches: "Si un módulo cambia su policy después de activate, el id vivo deja de coincidir: badge DRIFT, fee omitido, salidas Core intactas.",
    recintoHint: "packages",
    ...STD,
    p2p: true,
    needs: ["packages"],
    sequence: "recompute vivo vs packageIds",
    assertion: "Core exits enabled; badge DRIFT",
    steps: [
      { verb: "abrir un deal con paquetes", seat: "anyone", space: "deal" },
      { verb: "leer Kinds y módulos", seat: "anyone", space: "deal", expect: "recompute vivo == firmado (sin DRIFT)" },
      { verb: "si hay DRIFT: timeoutFiat / dual-sign siguen ENABLED", seat: "anyone", space: "deal" },
    ],
  },
  {
    id: "PATH-NEGATIVE-ZK-ARB",
    group: "negativo",
    teaches: "El preflight respeta el orden del bytecode: UnknownPackage antes que IncompatiblePackages.",
    recintoHint: "packages",
    ...STD,
    p2p: true,
    needs: ["packages"],
    sequence: "slots ZK+ARB, ambos ids en packageIds",
    assertion: "IncompatiblePackages; un id → UnknownPackage primero",
    steps: [
      { verb: "pegar slots zk + court", seat: "anyone", space: "packages", expect: "preflight: Escrow.IncompatiblePackages" },
      { verb: "override packageIds con un solo id", seat: "anyone", space: "packages", expect: "preflight: Escrow.UnknownPackage (antes)" },
    ],
  },
  {
    id: "PATH-NEGATIVE-UNSORTED",
    group: "negativo",
    teaches: "packageIds debe ser único y ascendente; Terms lo revisa antes de comparar HA vs PA.",
    recintoHint: "core",
    ...STD,
    p2p: true,
    needs: ["packages"],
    sequence: "packageIds no canónicos",
    assertion: "Terms.UnsortedPackageIds antes de TermsMismatch",
    steps: [{ verb: "override packageIds desordenado", seat: "anyone", space: "packages", expect: "preflight: Terms.UnsortedPackageIds" }],
  },
];

export function pathById(id: string): PathTemplate | undefined {
  return PATHS.find((p) => p.id === id);
}

export const PATH_GROUPS: { id: PathGroup; title: string; blurb: string }[] = [
  { id: "core", title: "Core", blurb: "La máquina de tres roles sin paquetes. Empezá acá." },
  { id: "dual-sign", title: "Dual-sign", blurb: "Provider y Controller firman; un Relayer envía una tx." },
  { id: "negativo", title: "Negativos", blurb: "Lo que debe fallar y con qué selector." },
  { id: "paquetes", title: "Paquetes", blurb: "Passport, Reputation, Bonds, ZK. Mocks en Sepolia, etiquetados LAB." },
  { id: "tribunal", title: "Tribunal", blurb: "ArbitrationMock y Kleros V2." },
  { id: "pool", title: "Pool", blurb: "Holder contrato vía EIP-1271." },
  { id: "rampa", title: "Rampa", blurb: "Taxi StargateV2 después del deal." },
];
