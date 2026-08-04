'use client'

import { useState, useEffect } from 'react'
import { type Address, formatEther } from 'viem'
import { CONTRACTS } from '@/lib/contracts'
import { type PositionView, PayoutResultCode } from '@/lib/types'
import { publicClient } from '@/lib/client'

interface Props {
  account: Address
  onWithdraw: () => void
}

export default function PositionList({ account, onWithdraw }: Props) {
  const [positions, setPositions] = useState<PositionView[]>([])
  const [loading, setLoading] = useState(false)

  // In a real app, we'd index events to find positions. For demo, we track known position IDs.
  const [knownPositionIds, setKnownPositionIds] = useState<`0x${string}`[]>([])

  useEffect(() => {
    // Load positions for known IDs
    const load = async () => {
      const loaded: PositionView[] = []
      for (const id of knownPositionIds) {
        try {
          const pos = await publicClient.readContract({
            address: CONTRACTS.ledger,
            abi: [
              {
                name: 'getPosition',
                type: 'function',
                stateMutability: 'view',
                inputs: [{ name: 'positionId', type: 'bytes32' }],
                outputs: [
                  {
                    type: 'tuple',
                    components: [
                      { name: 'positionId', type: 'bytes32' },
                      { name: 'exists', type: 'bool' },
                      { name: 'consumed', type: 'bool' },
                      { name: 'replaced', type: 'bool' },
                      { name: 'replacementRoundingDust', type: 'uint256' },
                      { name: 'kind', type: 'uint8' },
                      { name: 'sourceId', type: 'bytes32' },
                      { name: 'terminalHash', type: 'bytes32' },
                      { name: 'beneficiary', type: 'address' },
                      { name: 'token', type: 'address' },
                      {
                        name: 'components',
                        type: 'tuple',
                        components: [
                          { name: 'nominalUnits', type: 'uint256' },
                          { name: 'nominalRemaining', type: 'uint256' },
                          { name: 'paidAssets', type: 'uint256' },
                          { name: 'fundedEntitlement', type: 'uint256' },
                          { name: 'unfundedGap', type: 'uint256' },
                        ],
                      },
                      { name: 'deficitHistory', type: 'uint256' },
                      { name: 'deficitGeneration', type: 'uint256' },
                      { name: 'boundaryCheckpointId', type: 'bytes32' },
                      { name: 'boundaryMode', type: 'uint8' },
                    ],
                  },
                ],
              },
            ] as const,
            functionName: 'getPosition',
            args: [id],
          })
          if (pos.exists && pos.beneficiary.toLowerCase() === account.toLowerCase()) {
            loaded.push(pos as PositionView)
          }
        } catch (e) {
          // Position doesn't exist
        }
      }
      setPositions(loaded)
    }
    load()
  }, [knownPositionIds, account])

  const withdraw = async (positionId: `0x${string}`) => {
    setLoading(true)
    try {
      // Would use wallet client to send tx
      alert(`Withdraw ${positionId} would be executed here`)
      onWithdraw()
    } finally {
      setLoading(false)
    }
  }

  if (positions.length === 0) {
    return (
      <div className="bg-white rounded-xl shadow p-6">
        <h3 className="text-lg font-semibold mb-2">Your Positions</h3>
        <p className="text-gray-500 text-sm">No claimable positions yet.</p>
      </div>
    )
  }

  return (
    <div className="bg-white rounded-xl shadow p-6">
      <h3 className="text-lg font-semibold mb-4">Your Positions</h3>
      <div className="space-y-3">
        {positions.map((pos) => (
          <div
            key={pos.positionId}
            className="border border-gray-200 rounded-lg p-4"
          >
            <div className="flex justify-between items-start mb-2">
              <div className="font-mono text-sm text-gray-600">
                {pos.positionId.slice(0, 10)}...
              </div>
              <span className={`px-2 py-1 rounded text-xs font-medium ${
                pos.consumed
                  ? 'bg-gray-100 text-gray-600'
                  : 'bg-green-100 text-green-700'
              }`}>
                {pos.consumed ? 'Consumed' : 'Matured'}
              </span>
            </div>
            <div className="text-sm text-gray-700 mb-3">
              Amount: <span className="font-mono font-medium">
                {formatEther(pos.components.nominalRemaining)} MOCK
              </span>
            </div>
            {!pos.consumed && pos.components.nominalRemaining > 0n && (
              <button
                onClick={() => withdraw(pos.positionId)}
                disabled={loading}
                className="w-full px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:opacity-50 text-sm"
              >
                Withdraw
              </button>
            )}
          </div>
        ))}
      </div>
    </div>
  )
}
