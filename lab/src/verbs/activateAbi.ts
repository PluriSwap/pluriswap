const dealTermsComponents = [
  { name: "holder", type: "address" },
  { name: "controller", type: "address" },
  { name: "provider", type: "address" },
  { name: "token", type: "address" },
  { name: "principal", type: "uint256" },
  { name: "fiatDuration", type: "uint256" },
  { name: "releaseDuration", type: "uint256" },
  { name: "disputeDuration", type: "uint256" },
  { name: "arbitrationDuration", type: "uint256" },
  { name: "packageIds", type: "bytes32[]" },
] as const;

const envelopeComponents = [
  { name: "terms", type: "tuple", components: dealTermsComponents },
  { name: "nonce", type: "uint256" },
  { name: "deadline", type: "uint256" },
] as const;

/** 6-arg Core overload only. P2P still encodes dummy ControllerAcceptance + bytes(""). */
export const activateAbi = [
  {
    type: "function",
    name: "activate",
    stateMutability: "nonpayable",
    inputs: [
      { name: "ha", type: "tuple", components: envelopeComponents },
      { name: "holderSig", type: "bytes" },
      { name: "pa", type: "tuple", components: envelopeComponents },
      { name: "providerSig", type: "bytes" },
      { name: "ca", type: "tuple", components: envelopeComponents },
      { name: "controllerSig", type: "bytes" },
    ],
    outputs: [{ name: "id", type: "bytes32" }],
  },
] as const;

export const erc20Abi = [
  {
    type: "function",
    name: "allowance",
    stateMutability: "view",
    inputs: [
      { name: "owner", type: "address" },
      { name: "spender", type: "address" },
    ],
    outputs: [{ name: "", type: "uint256" }],
  },
] as const;
