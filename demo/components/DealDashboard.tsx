'use client'

import { useState, useEffect } from 'react'
import { type Address, formatEther } from 'viem'
import { CONTRACTS } from '@/lib/contracts'
import { type Deal, DealState, stateLabel, outcomeLabel, isTerminal } from '@/lib/types'
import { publicClient } from '@/lib/client'

interface Props {
  account: Address
  role: 'holder' | 'provider'
  deals: `0x${string}`[]
  selectedDeal: `0x${string}` | null
  onSelectDeal: (id: `0x${string}` | null) => void
  onAction: () => void
}

export default function DealDashboard({ account, role, deals, selectedDeal, onSelectDeal, onAction }: Props) {
  const [dealData, setDealData] = useState<Deal | null>(null)
  const [loading, setLoading] = useState(false)

  useEffect(() => {
    if (!selectedDeal) {
      setDealData(null)
      return
    }
    loadDeal(selectedDeal)
  }, [selectedDeal])

  const loadDeal = async (dealId: `0x${string}`) => {
    try {
      const data = await publicClient.readContract({
        address: CONTRACTS.escrow,
        abi: [
          {
            name: 'getDeal',
            type: 'function',
            stateMutability: 'view',
            inputs: [{ name: 'dealId', type: 'bytes32' }],
            outputs: [
              {
                type: 'tuple',
                components: [
                  { name: 'state', type: 'uint8' },
                  { name: 'outcome', type: 'uint8' },
                  { name: 'holder', type: 'address' },
                  { name: 'provider', type: 'address' },
                  { name: 'holderReceiver', type: 'address' },
                  { name: 'providerReceiver', type: 'address' },
                  { name: 'token', type: 'address' },
                  { name: 'principal', type: 'uint256' },
                  { name: 'activationFee', type: 'uint256' },
                  { name: 'activationFeeRecipient', type: 'address' },
                  { name: 'completionFee', type: 'uint256' },
                  { name: 'completionFeeRecipient', type: 'address' },
                  { name: 'disputeTimeoutProviderBps', type: 'uint16' },
                  { name: 'activatedAt', type: 'uint64' },
                  { name: 'fiatDeadline', type: 'uint64' },
                  { name: 'releaseDuration', type: 'uint64' },
                  { name: 'releaseDeadline', type: 'uint64' },
                  { name: 'disputeDuration', type: 'uint64' },
                  { name: 'disputeDeadline', type: 'uint64' },
                  { name: 'profileFlags', type: 'uint32' },
                  { name: 'termsHash', type: 'bytes32' },
                  { name: 'custodyBoundaryId', type: 'bytes32' },
                  { name: 'modulesHash', type: 'bytes32' },
                  { name: 'terminalHash', type: 'bytes32' },
                ],
              },
            ],
          },
        ] as const,
        functionName: 'getDeal',
        args: [dealId],
      })
      setDealData(data as unknown as Deal)
    } catch (e) {
      console.error('Failed to load deal', e)
    }
  }

  const doAction = async (action: string) => {
    setLoading(true)
    try {
      // Actions would be implemented with wallet client
      alert(`Action ${action} would be executed here`)
      onAction()
    } finally {
      setLoading(false)
    }
  }

  if (deals.length === 0) {
    return (
      <div className="bg-white rounded-xl shadow p-6">
        <h3 className="text-lg font-semibold mb-2">Your Deals</h3>
        <p className="text-gray-500 text-sm">No deals yet. Create one to get started.</p>
      </div>
    )
  }

  return (
    <div className="bg-white rounded-xl shadow p-6">
      <h3 className="text-lg font-semibold mb-4">Your Deals</h3>

      <div className="space-y-3 mb-6">
        {deals.map((id) => (
          <button
            key={id}
            onClick={() => onSelectDeal(id === selectedDeal ? null : id)}
            className={`w-full text-left px-4 py-3 rounded-lg border transition ${
              id === selectedDeal
                ? 'border-blue-500 bg-blue-50'
                : 'border-gray-200 hover:bg-gray-50'
            }`}
          >
            <div className="font-mono text-sm text-gray-600">{id.slice(0, 10)}...{id.slice(-8)}</div>
          </button>
        ))}
      </div>

      {dealData && (
        <div className="border-t pt-4">
          <div className="flex items-center justify-between mb-4">
            <div>
              <span className={`inline-block px-3 py-1 rounded-full text-sm font-medium ${
                isTerminal(dealData.state)
                  ? 'bg-gray-100 text-gray-800'
                  : dealData.state === DealState.Disputed
                  ? 'bg-red-100 text-red-800'
                  : 'bg-green-100 text-green-800'
              }`}>
                {stateLabel(dealData.state)}
              </span>
              {dealData.outcome > 0 && (
                <span className="ml-2 text-sm text-gray-600">
                  ({outcomeLabel(dealData.outcome)})
                </span>
              )}
            </div>
            <div className="text-sm text-gray-500">
              {formatEther(dealData.principal)} MOCK
            </div>
          </div>

          {/* Deadlines */}
          <div className="space-y-2 mb-4 text-sm">
            {dealData.state === DealState.Funded && (
              <div className="flex justify-between">
                <span className="text-gray-600">Fiat deadline:</span>
                <span className="font-mono">{new Date(Number(dealData.fiatDeadline) * 1000).toLocaleString()}</span>
              </div>
            )}
            {dealData.state === DealState.FiatSent && (
              <div className="flex justify-between">
                <span className="text-gray-600">Release deadline:</span>
                <span className="font-mono">{new Date(Number(dealData.releaseDeadline) * 1000).toLocaleString()}</span>
              </div>
            )}
            {dealData.state === DealState.Disputed && (
              <div className="flex justify-between">
                <span className="text-gray-600">Dispute deadline:</span>
                <span className="font-mono">{new Date(Number(dealData.disputeDeadline) * 1000).toLocaleString()}</span>
              </div>
            )}
          </div>

          {/* Actions */}
          {!isTerminal(dealData.state) && (
            <div className="flex flex-wrap gap-2">
              {dealData.state === DealState.Funded && role === 'provider' && (
                <button
                  onClick={() => doAction('markFiatSent')}
                  disabled={loading}
                  className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:opacity-50"
                >
                  Mark Fiat Sent
                </button>
              )}
              {dealData.state === DealState.Funded && (
                <button
                  onClick={() => doAction('fiatTimeoutCancel')}
                  disabled={loading}
                  className="px-4 py-2 bg-gray-600 text-white rounded-lg hover:bg-gray-700 disabled:opacity-50"
                >
                  Cancel (Timeout)
                </button>
              )}
              {dealData.state === DealState.FiatSent && role === 'holder' && (
                <>
                  <button
                    onClick={() => doAction('holderRelease')}
                    disabled={loading}
                    className="px-4 py-2 bg-green-600 text-white rounded-lg hover:bg-green-700 disabled:opacity-50"
                  >
                    Release to Provider
                  </button>
                  <button
                    onClick={() => doAction('openDispute')}
                    disabled={loading}
                    className="px-4 py-2 bg-red-600 text-white rounded-lg hover:bg-red-700 disabled:opacity-50"
                  >
                    Open Dispute
                  </button>
                </>
              )}
              {dealData.state === DealState.FiatSent && (
                <button
                  onClick={() => doAction('claim')}
                  disabled={loading}
                  className="px-4 py-2 bg-gray-600 text-white rounded-lg hover:bg-gray-700 disabled:opacity-50"
                >
                  Claim (Timeout)
                </button>
              )}
              {dealData.state === DealState.Disputed && (
                <button
                  onClick={() => doAction('disputeTimeout')}
                  disabled={loading}
                  className="px-4 py-2 bg-orange-600 text-white rounded-lg hover:bg-orange-700 disabled:opacity-50"
                >
                  Dispute Timeout
                </button>
              )}
            </div>
          )}

          {/* Terminal info */}
          {isTerminal(dealData.state) && (
            <div className="bg-gray-50 rounded-lg p-4 text-sm">
              <div className="font-medium text-gray-700 mb-2">Settlement Complete</div>
              <div className="text-gray-600">
                Terminal hash: <span className="font-mono">{dealData.terminalHash.slice(0, 10)}...</span>
              </div>
              <div className="text-gray-600 mt-1">
                Check "Your Positions" to withdraw funds.
              </div>
            </div>
          )}
        </div>
      )}
    </div>
  )
}
