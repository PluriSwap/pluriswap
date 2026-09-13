/** Borrador de DealTerms + nonces + deadline de autorización. Sesión, no protocolo. */
export type ConsentDraft = {
  p2p: boolean;
  holder: string;
  controller: string;
  provider: string;
  token: string;
  principal: string;
  fiatDuration: string;
  releaseDuration: string;
  disputeDuration: string;
  arbitrationDuration: string;
  holderNonce: string;
  providerNonce: string;
  controllerNonce: string;
  deadline: string;
};

export const defaultDraft = (token: string): ConsentDraft => ({
  p2p: true,
  holder: "",
  controller: "",
  provider: "",
  token,
  principal: "1000000",
  fiatDuration: "3600",
  releaseDuration: "1800",
  disputeDuration: "7200",
  arbitrationDuration: "0",
  holderNonce: "1",
  providerNonce: "1",
  controllerNonce: "1",
  deadline: String(Math.floor(Date.now() / 1000) + 86_400),
});
