import { type Address } from 'viem'
import { ABIS } from './abis'

// ── Anvil default accounts ───────────────────────────────────────────────────

export const ANVIL_ACCOUNTS = [
  {
    index: 0,
    address: '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266' as Address,
    privateKey: '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80' as const,
  },
  {
    index: 1,
    address: '0x70997970C51812dc3A010C7d01b50e0d17dc79C8' as Address,
    privateKey: '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d' as const,
  },
  {
    index: 2,
    address: '0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC' as Address,
    privateKey: '0x5de4111ada573a2a9a14b2b9b5ae3f39b38d2a3b2b3c3c3c3c3c3c3c3c3c3c3c' as const,
  },
] as const

// ── Chain config ─────────────────────────────────────────────────────────────

export const CHAIN_ID = 31337n
export const PROTOCOL_VERSION = 2
export const RPC_URL = 'http://localhost:8545'

// ── Contract addresses (populated after deploy) ──────────────────────────────

export interface DeployedContracts {
  deployer: Address
  escrow: Address
  ledger: Address
  coordinator: Address
  token: Address
}

// Default to zero; will be overwritten by deploy script or env
export const CONTRACTS: DeployedContracts = {
  deployer: (process.env.NEXT_PUBLIC_DEPLOYER_ADDRESS || '0x0000000000000000000000000000000000000000') as Address,
  escrow: (process.env.NEXT_PUBLIC_ESCROW_ADDRESS || '0x0000000000000000000000000000000000000000') as Address,
  ledger: (process.env.NEXT_PUBLIC_LEDGER_ADDRESS || '0x0000000000000000000000000000000000000000') as Address,
  coordinator: (process.env.NEXT_PUBLIC_COORDINATOR_ADDRESS || '0x0000000000000000000000000000000000000000') as Address,
  token: (process.env.NEXT_PUBLIC_TOKEN_ADDRESS || '0x0000000000000000000000000000000000000000') as Address,
}

// ── Contract getters ─────────────────────────────────────────────────────────

export function getEscrowContract(address: Address) {
  return {
    address,
    abi: ABIS.CoreEscrow,
  } as const
}

export function getLedgerContract(address: Address) {
  return {
    address,
    abi: ABIS.CreditLedger,
  } as const
}

export function getCoordinatorContract(address: Address) {
  return {
    address,
    abi: ABIS.Coordinator,
  } as const
}

export function getTokenContract(address: Address) {
  return {
    address,
    abi: ABIS.MockERC20,
  } as const
}

// ── Anvil RPC helpers ────────────────────────────────────────────────────────

export async function anvilIncreaseTime(seconds: number): Promise<void> {
  await fetch(RPC_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      jsonrpc: '2.0',
      method: 'evm_increaseTime',
      params: [seconds],
      id: 1,
    }),
  })
}

export async function anvilMine(): Promise<void> {
  await fetch(RPC_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      jsonrpc: '2.0',
      method: 'evm_mine',
      params: [],
      id: 1,
    }),
  })
}

export async function anvilSnapshot(): Promise<string> {
  const res = await fetch(RPC_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      jsonrpc: '2.0',
      method: 'evm_snapshot',
      params: [],
      id: 1,
    }),
  })
  const data = await res.json()
  return data.result
}

export async function anvilRevert(snapshotId: string): Promise<void> {
  await fetch(RPC_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      jsonrpc: '2.0',
      method: 'evm_revert',
      params: [snapshotId],
      id: 1,
    }),
  })
}
