import { createPublicClient, http, createWalletClient } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { RPC_URL } from './contracts'

export const publicClient = createPublicClient({
  transport: http(RPC_URL),
})

export function walletClient(privateKey: `0x${string}`) {
  const account = privateKeyToAccount(privateKey)
  return createWalletClient({
    account,
    transport: http(RPC_URL),
  })
}
