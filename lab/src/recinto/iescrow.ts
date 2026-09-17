/** IEscrow read surface. Kernel does not write deal state through this ABI. */
export const iescrowAbi = [
  {
    type: "function",
    name: "domainSeparator",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "bytes32" }],
  },
  {
    type: "function",
    name: "used",
    stateMutability: "view",
    inputs: [
      { name: "signer", type: "address" },
      { name: "nonce", type: "uint256" },
    ],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    type: "function",
    name: "dealOf",
    stateMutability: "view",
    inputs: [
      { name: "signer", type: "address" },
      { name: "nonce", type: "uint256" },
    ],
    outputs: [{ name: "", type: "bytes32" }],
  },
  {
    type: "function",
    name: "status",
    stateMutability: "view",
    inputs: [{ name: "dealId", type: "bytes32" }],
    outputs: [{ name: "", type: "uint8" }],
  },
  {
    type: "function",
    name: "terms",
    stateMutability: "view",
    inputs: [{ name: "dealId", type: "bytes32" }],
    outputs: [
      {
        name: "",
        type: "tuple",
        components: [
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
        ],
      },
    ],
  },
  {
    type: "function",
    name: "clocks",
    stateMutability: "view",
    inputs: [{ name: "dealId", type: "bytes32" }],
    outputs: [
      {
        name: "",
        type: "tuple",
        components: [
          { name: "activatedAt", type: "uint256" },
          { name: "fiatSentAt", type: "uint256" },
          { name: "disputedAt", type: "uint256" },
          { name: "arbitrationOpenedAt", type: "uint256" },
        ],
      },
    ],
  },
  {
    type: "function",
    name: "subjects",
    stateMutability: "view",
    inputs: [{ name: "dealId", type: "bytes32" }],
    outputs: [
      { name: "holderSubject", type: "bytes32" },
      { name: "providerSubject", type: "bytes32" },
    ],
  },
  {
    type: "function",
    name: "modules",
    stateMutability: "view",
    inputs: [{ name: "dealId", type: "bytes32" }],
    outputs: [
      {
        name: "",
        type: "tuple",
        components: [
          { name: "passport", type: "address" },
          { name: "reputation", type: "address" },
          { name: "bonds", type: "address" },
          { name: "zk", type: "address" },
          { name: "court", type: "address" },
        ],
      },
    ],
  },
  {
    type: "function",
    name: "kinds",
    stateMutability: "view",
    inputs: [{ name: "dealId", type: "bytes32" }],
    outputs: [{ name: "", type: "uint8" }],
  },
  {
    type: "function",
    name: "settlementOf",
    stateMutability: "view",
    inputs: [{ name: "dealId", type: "bytes32" }],
    outputs: [
      { name: "status_", type: "uint8" },
      { name: "holderAmt", type: "uint256" },
      { name: "providerAmt", type: "uint256" },
    ],
  },
  {
    type: "function",
    name: "creditOf",
    stateMutability: "view",
    inputs: [
      { name: "token", type: "address" },
      { name: "beneficiary", type: "address" },
    ],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "postPending",
    stateMutability: "view",
    inputs: [{ name: "dealId", type: "bytes32" }],
    outputs: [{ name: "", type: "uint8" }],
  },
] as const;

export const operatorAbi = [
  {
    type: "function",
    name: "operator",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
] as const;

export const courtAbi = [
  {
    type: "function",
    name: "readRuling",
    stateMutability: "view",
    inputs: [{ name: "dealId", type: "bytes32" }],
    outputs: [{ name: "", type: "uint8" }],
  },
] as const;

export const kernelAbi = [
  {
    type: "function",
    name: "kernel",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
] as const;
