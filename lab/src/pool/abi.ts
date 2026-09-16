export const LIFE = ["NONE", "ACTIVE", "DEFICIENT", "RUNOFF", "WINDING_DOWN", "CLOSED"] as const;

export const poolAbi = [
  { type: "function", name: "escrow", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "token", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "life", stateMutability: "view", inputs: [], outputs: [{ type: "uint8" }] },
  { type: "function", name: "idle", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "locked", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "credits", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "consumed", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "totalShares", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "nav", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "controllerFeeBps", stateMutability: "view", inputs: [], outputs: [{ type: "uint16" }] },
  {
    type: "function",
    name: "isAgent",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ type: "bool" }],
  },
  {
    type: "function",
    name: "deposit",
    stateMutability: "nonpayable",
    inputs: [{ name: "amount", type: "uint256" }],
    outputs: [],
  },
  {
    type: "function",
    name: "authorize",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "ha",
        type: "tuple",
        components: [
          {
            name: "terms",
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
          { name: "nonce", type: "uint256" },
          { name: "deadline", type: "uint256" },
        ],
      },
      { name: "reputation", type: "address" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "unlock",
    stateMutability: "nonpayable",
    inputs: [{ name: "nonce", type: "uint256" }],
    outputs: [],
  },
  {
    type: "function",
    name: "reconcile",
    stateMutability: "nonpayable",
    inputs: [
      { name: "nonce", type: "uint256" },
      { name: "providerNonce", type: "uint256" },
      { name: "controllerNonce", type: "uint256" },
    ],
    outputs: [],
  },
] as const;
