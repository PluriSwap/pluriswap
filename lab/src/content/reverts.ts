/** Qué significa cada selector que la matriz proyecta, en una frase para el operador. */
const DOCS: Record<string, string> = {
  "Escrow.WrongStatus": "El deal no está en el estado desde el que este verbo es legal.",
  "Escrow.Unauthorized": "El asiento activo no es el rol que el kernel exige para este verbo.",
  "Escrow.EdgeOff": "Deal ZK: esta arista está apagada; el pago se demuestra con verifyProof, no con markFiat/claim/dispute.",
  "Escrow.PackageNotSelected": "El deal no firmó este paquete (kinds no tiene el bit). No es capacidad de este deal.",
  "Escrow.PackageDrift": "El módulo cambió su policy: el id recomputeado ya no está en packageIds. Las salidas Core siguen.",
  "Escrow.NotRuled": "El tribunal todavía no dictó (ruling = 0).",
  "Escrow.DealExists": "Ya hay un deal con este dealId (mismos términos y nonces).",
  "Escrow.DealIdMismatch": "Los dos envelopes dual-sign nombran dealIds distintos.",
  "Escrow.DeadlineMismatch": "Los dos envelopes dual-sign tienen deadlines distintos.",
  "Escrow.DeadlinePassed": "El deadline de autorización del envelope ya pasó (block.timestamp > deadline).",
  "Escrow.BpsMismatch": "providerBps distinto entre las dos copias, o > 10000.",
  "Escrow.IncompatiblePackages": "ZK y ARBITRATION no conviven en un deal.",
  "Escrow.UnknownPackage": "Un slot recomputa a un id que no está en packageIds (o sobra un id firmado sin slot).",
  "Escrow.PackageRequired": "Reputation exige Passport; Bonds exige Passport + Reputation.",
  "Escrow.PeerMismatch": "reputation.passport() o vault.passport() no es el slot passport pegado.",
  "Escrow.TermsMismatch": "Los DealTerms de HA, PA (y CA) no hashean igual.",
  "Escrow.ControllerAcceptanceRequired": "holder != controller y la CA no nombra a ese controller.",
  "Escrow.InvalidControllerSignature": "La firma de la CA no recupera al controller (o el 1271 rechazó).",
  "Escrow.InvalidHolderSignature": "La firma HA no recupera al holder (o el 1271 del pool rechazó).",
  "Escrow.InvalidProviderSignature": "La firma PA no recupera al provider.",
  "Escrow.NonceUsed": "used[signer][nonce] ya es true: firma consumida o cancelada.",
  "Settlement.InexactPull": "allowance o balance del Holder no cubren el pull exacto (principal + activationFee).",
  "KlerosAdapter.InsufficientFee": "msg.value != arbitrationCost(extraData). Kleros exige igualdad exacta.",
  "Clocks.TooEarly": "Todavía no: now < origin + duration. Este verbo espera al reloj.",
  "Clocks.TooLate": "Se cerró la ventana: now >= origin + duration. Con duration = 0 se cierra en el mismo bloque.",
  "Clocks overflow": "origin + duration desborda uint256; el timeout sería irllamable.",
  "Terms.HolderEqualsProvider": "holder == provider no es un deal.",
  "Terms.ZeroPrincipal": "principal = 0.",
  "Terms.UnsortedPackageIds": "packageIds no está ordenado ascendente y único.",
  "Terms.ZeroAddress": "Algún rol o el token es address(0).",
  "Terms.ControllerEqualsProvider": "controller == provider no es válido: el Controller juzga al Provider.",
  "IPassport.NoPassport": "identify(wallet) revierte: la wallet no tiene passport (en Sepolia: setHuman no corrió).",
  "Reputation.CapExceeded": "inFlight + principal supera el cap del sujeto para este token.",
  "Reputation.InsufficientBond": "La cobertura de bond (10%) no alcanza.",
  "BondVault.InsufficientAvailable": "El sujeto no tiene bond libre para el lock (principal + 9) / 10.",
  "BondVault.LockTooSmall": "El lock calculado es 0.",
  "BondVault.LockExists": "Ya hay un lock para (sujeto, dealId).",
  "ArbitrationMock.AlreadyOpen": "El mock ya tiene un caso para este dealId (grief con open()).",
  "draft-empty": "Política de UI: el borrador dual-sign no está completo. No es un revert del kernel.",
  "no-op": "Política de UI: el kernel no revertiría, pero no haría nada (crédito 0).",
  "no-sender": "Política de UI: el asiento activo no tiene address. Pegá una para evaluar Unauthorized.",
  "already used": "Política de UI: el nonce ya está usado; cancelNonce sigue siendo legal (idempotente).",
  "sin proof mock": "Política de UI: no hay payload. Ensamblalo en Laboratorio (mock) y pegalo.",
};

export function revertDoc(reason: string): string {
  if (DOCS[reason]) return DOCS[reason];
  const key = Object.keys(DOCS).find((k) => reason.startsWith(k));
  return key ? DOCS[key]! : "";
}

export function shortReason(reason: string): string {
  return reason.replace(/^(Escrow|Terms|Clocks|Settlement|IPassport|Reputation|BondVault|KlerosAdapter|ArbitrationMock)\./, "");
}
