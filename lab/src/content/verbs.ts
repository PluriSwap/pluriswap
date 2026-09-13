/**
 * Explicación humana de cada entrypoint de Escrow.sol. Chrome en español, identificadores on-chain en inglés.
 * Esto es copy derivado del bytecode (src/Escrow.sol); si el kernel cambia, cambia acá.
 */
export type VerbDoc = {
  verb: string;
  /** Quién debe ser msg.sender. */
  who: string;
  /** Estado(s) desde los que es legal. */
  from: string;
  /** Estado al que lleva. */
  to: string;
  /** Reloj que lo condiciona, si hay. */
  clock?: string;
  /** Qué pasa con el principal. */
  money: string;
  /** Una frase: para qué existe. */
  why: string;
  /** Efecto en paquetes (fee, bonds, score) si el deal los trae. */
  packages?: string;
};

export const VERB_DOCS: Record<string, VerbDoc> = {
  activate: {
    verb: "activate",
    who: "Relayer (cualquiera). Las firmas van en calldata.",
    from: "NONE",
    to: "FUNDED",
    money: "Pull exacto de `principal` (más `activationFee` si hay Reputation) desde el Holder al escrow.",
    why: "Nace el deal: el Holder y el Provider firmaron los mismos DealTerms; si el Controller es distinto, también.",
    packages: "Resuelve PackageMods → recomputa ids → identify/admit/reserve. Un paquete inválido revierte todo.",
  },
  markFiat: {
    verb: "markFiat",
    who: "Provider",
    from: "FUNDED",
    to: "FIAT_SENT",
    money: "Nada se mueve. Arranca el reloj `releaseDuration`.",
    why: "El Provider declara que pagó el fiat offchain. Desde acá el Controller tiene una ventana para liberar o disputar.",
    packages: "Deal ZK: EdgeOff. Con ZK la única salida positiva es verifyProof.",
  },
  cancelByProvider: {
    verb: "cancelByProvider",
    who: "Provider",
    from: "FUNDED",
    to: "CANCELLED",
    money: "100% del principal vuelve al Holder. Sin completion fee.",
    why: "El Provider se baja antes de pagar. Nadie queda mal: cierre Silent, bonds unlock.",
  },
  timeoutFiat: {
    verb: "timeoutFiat",
    who: "Cualquiera",
    from: "FUNDED",
    to: "CANCELLED",
    clock: "due: now >= activatedAt + fiatDuration",
    money: "100% del principal vuelve al Holder. Sin completion fee.",
    why: "El Provider nunca marcó el fiat. El Holder recupera su plata sin depender de nadie.",
  },
  release: {
    verb: "release",
    who: "Controller",
    from: "FIAT_SENT",
    to: "RELEASED",
    money: "Principal al Provider. Si hay Reputation, completion fee sobre el total antes de pagar.",
    why: "El Controller confirma que el fiat llegó. Cierre Peaceful para ambos; bonds unlock.",
  },
  claim: {
    verb: "claim",
    who: "Cualquiera",
    from: "FIAT_SENT",
    to: "CLAIMED",
    clock: "due: now >= fiatSentAt + releaseDuration",
    money: "Principal al Provider (completion fee sobre el total si hay Reputation, igual que release).",
    why: "El Controller no liberó ni disputó a tiempo. El Provider cobra; el Holder queda Silent (ausencia no es culpa probada).",
    packages: "Deal ZK: EdgeOff.",
  },
  openDisputed: {
    verb: "openDisputed",
    who: "Controller",
    from: "FIAT_SENT",
    to: "DISPUTED",
    clock: "strictly-before: now < fiatSentAt + releaseDuration",
    money: "Nada se mueve. Arranca `disputeDuration`.",
    why: "El Controller niega que el fiat llegó. Abre la ventana para acordar (dual-sign) o ir a tribunal.",
    packages: "Deal ZK: EdgeOff. releaseDuration = 0 ⇒ TooLate para siempre.",
  },
  forceStalemate: {
    verb: "forceStalemate",
    who: "Cualquiera",
    from: "DISPUTED",
    to: "STALEMATE",
    clock: "due: now >= disputedAt + disputeDuration",
    money: "50/50. Completion fee sobre el total (el Provider recibe algo).",
    why: "Nadie acordó ni fue a tribunal. El kernel parte la diferencia; ambos bonds se queman (Stalemate).",
  },
  mutualCancel: {
    verb: "mutualCancel",
    who: "Relayer envía; firman Provider y Controller (dos envelopes `MutualCancel`).",
    from: "FUNDED | FIAT_SENT | DISPUTED | ARBITRATION_ACTIVE",
    to: "CANCELLED",
    money: "100% al Holder. Sin fee.",
    why: "Las partes deshacen el trato de común acuerdo, incluso con un caso abierto.",
  },
  coSignedRelease: {
    verb: "coSignedRelease",
    who: "Relayer envía; firman Provider y Controller (`CoSignedRelease`).",
    from: "FIAT_SENT | DISPUTED | ARBITRATION_ACTIVE",
    to: "RELEASED",
    money: "Principal al Provider, completion fee sobre el total si hay Reputation.",
    why: "Resolver una disputa liberando, sin esperar al Controller solo ni al tribunal.",
  },
  mutualSplit: {
    verb: "mutualSplit",
    who: "Relayer envía; firman Provider y Controller (`MutualSplit`, mismo providerBps).",
    from: "FIAT_SENT | DISPUTED | ARBITRATION_ACTIVE",
    to: "RESOLVED_SPLIT",
    money: "Completion fee sobre el total primero; luego `providerBps` del resto al Provider, el remanente al Holder.",
    why: "Acuerdo parcial. providerBps = 10000 sigue siendo un split, no un release.",
  },
  verifyProof: {
    verb: "verifyProof",
    who: "Cualquiera (el payload lo fabrica el Provider; en Sepolia es un mock LAB)",
    from: "FUNDED",
    to: "RELEASED",
    money: "verifyFee al módulo ZK, completion fee sobre el resto, lo que queda al Provider.",
    why: "El pago fiat se demuestra con una prueba, no con la palabra del Provider ni del Controller.",
    packages: "Exige PKG_ZK y que el id recomputeado siga en packageIds (PackageDrift si no).",
  },
  openCourt: {
    verb: "openCourt",
    who: "Controller (paga el costo del tribunal)",
    from: "FIAT_SENT | DISPUTED",
    to: "ARBITRATION_ACTIVE",
    clock: "strictly-before del reloj del estado actual (releaseDuration o disputeDuration)",
    money: "Nada del principal. msg.value = arbitrationCost exacto (Kleros) o approve del courtFee al mock.",
    why: "Escalar a un tercero. Con Kleros: PluriSwap solo abre el caso; la evidencia se sube en la dapp de Kleros.",
    packages: "Exige PKG_ARB. Incompatible con ZK.",
  },
  readRuling: {
    verb: "readRuling",
    who: "Cualquiera",
    from: "ARBITRATION_ACTIVE",
    to: "RESOLVED_BY_ARBITRATION | STALEMATE",
    money: "1 = Holder gana (refund, bond del Provider al Holder). 2 = Provider gana (payout, bond del Holder al Provider). 3 = tribunal no decide: 50/50, bonds unlock.",
    why: "Trae la sentencia al kernel. Es la única cosa que PluriSwap hace con Kleros después de abrir.",
  },
  forceArbitrationTimeout: {
    verb: "forceArbitrationTimeout",
    who: "Cualquiera",
    from: "ARBITRATION_ACTIVE",
    to: "STALEMATE",
    clock: "due: now >= arbitrationOpenedAt + arbitrationDuration",
    money: "50/50. Bonds unlock, scores Silent.",
    why: "El tribunal nunca respondió. Eso no es culpa de las partes.",
  },
  withdraw: {
    verb: "withdraw",
    who: "El beneficiario del crédito",
    from: "cualquier estado",
    to: "—",
    money: "Paga `creditOf(token, msg.sender)`. Con crédito 0 no revierte: no-op.",
    why: "Credit-first: si el push falló al cerrar, la plata queda acreditada y se retira acá.",
  },
  cancelNonce: {
    verb: "cancelNonce",
    who: "msg.sender sobre su propio nonce",
    from: "cualquier estado",
    to: "—",
    money: "Nada.",
    why: "Invalida una firma que todavía no se consumió (por ejemplo una HolderAuthorization que ya no querés honrar).",
  },
};

export function verbDoc(verb: string): VerbDoc | undefined {
  return VERB_DOCS[verb];
}
