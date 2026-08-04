'use client'

import { useState } from 'react'
import { type Address, createWalletClient, http, publicActions } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { ANVIL_ACCOUNTS, RPC_URL } from '@/lib/contracts'

interface Props {
  onConnect: (address: Address) => void
}

export default function ConnectWallet({ onConnect }: Props) {
  const [privateKey, setPrivateKey] = useState('')
  const [error, setError] = useState('')

  const connectWithKey = async (key: string) => {
    try {
      const account = privateKeyToAccount(key as `0x${string}`)
      const client = createWalletClient({
        account,
        transport: http(RPC_URL),
      }).extend(publicActions)
      const balance = await client.getBalance({ address: account.address })
      if (balance === 0n) {
        setError('Account has no ETH. Is Anvil running?')
        return
      }
      onConnect(account.address)
    } catch (e) {
      setError('Invalid private key')
    }
  }

  return (
    <div className="bg-white rounded-2xl shadow-lg p-8">
      <h2 className="text-xl font-semibold mb-6">Connect to Anvil</h2>

      <div className="space-y-4">
        <div>
          <label className="block text-sm font-medium text-gray-700 mb-2">
            Private Key
          </label>
          <input
            type="password"
            value={privateKey}
            onChange={(e) => setPrivateKey(e.target.value)}
            placeholder="0x..."
            className="w-full px-4 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-transparent"
          />
          <button
            onClick={() => connectWithKey(privateKey)}
            className="mt-3 w-full bg-blue-600 text-white py-2 px-4 rounded-lg hover:bg-blue-700 transition"
          >
            Connect
          </button>
        </div>

        <div className="relative">
          <div className="absolute inset-0 flex items-center">
            <div className="w-full border-t border-gray-300" />
          </div>
          <div className="relative flex justify-center text-sm">
            <span className="px-2 bg-white text-gray-500">Or quick-select</span>
          </div>
        </div>

        <div className="space-y-2">
          {ANVIL_ACCOUNTS.map((acc) => (
            <button
              key={acc.index}
              onClick={() => connectWithKey(acc.privateKey)}
              className="w-full text-left px-4 py-3 border border-gray-200 rounded-lg hover:bg-gray-50 transition"
            >
              <div className="font-medium text-gray-900">Account #{acc.index}</div>
              <div className="text-sm text-gray-500 font-mono">{acc.address}</div>
            </button>
          ))}
        </div>

        {error && (
          <div className="p-3 bg-red-50 border border-red-200 rounded-lg text-red-700 text-sm">
            {error}
          </div>
        )}
      </div>
    </div>
  )
}
