'use client'

import { useState } from 'react'
import { type Address, parseEther, keccak256, toHex } from 'viem'
import { CONTRACTS, CHAIN_ID, PROTOCOL_VERSION } from '@/lib/contracts'
import { type DealTerms, FundingPurpose, FundingSourceMode } from '@/lib/types'
import { custodyBoundaryId, hashDealTerms, hashFundingSpec } from '@/lib/hashing'
import { planDealTerminal } from '@/lib/planner'

interface Props {
  account: Address
  onDealCreated: (dealId: `0x${string}`) => void
}

export default function DealCreator({ account, onDealCreated }: Props) {
  const [principal, setPrincipal] = useState('1000')
  const [activationFee, setActivationFee] = useState('0')
  const [completionFee, setCompletionFee] = useState('50')
  const [fiatDuration, setFiatDuration] = useState('24')
  const [releaseDuration, setReleaseDuration] = useState('48')
  const [disputeDuration, setDisputeDuration] = useState('24')
  const [disputeBps, setDisputeBps] = useState('5000')
  const [provider, setProvider] = useState('')
  const [loading, setLoading] = useState(false)
  const [preview, setPreview] = useState<{
    providerGets: bigint
    holderGets: bigint
    feeGets: bigint
  } | null>(null)

  const updatePreview = () => {
    const p = parseEther(principal || '0')
    const cf = parseEther(completionFee || '0')
    const bps = parseInt(disputeBps || '5000')
    const providerGross = (p * BigInt(bps)) / 10000n
    const holderGross = p - providerGross
    const fee = cf > providerGross ? providerGross : cf
    setPreview({
      providerGets: providerGross - fee,
      holderGets: holderGross,
      feeGets: fee,
    })
  }

  const createDeal = async () => {
    setLoading(true)
    try {
      // This is a simplified preview — full activation requires counterparty signature
      alert('Deal creation requires counterparty signature. Use the dashboard to activate with a second account.')
    } finally {
      setLoading(false)
    }
  }

  return (
    <div className="bg-white rounded-xl shadow p-6">
      <h3 className="text-lg font-semibold mb-4">Create New Deal</h3>

      <div className="grid grid-cols-2 gap-4 mb-4">
        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">Provider Address</label>
          <input
            type="text"
            value={provider}
            onChange={(e) => setProvider(e.target.value)}
            placeholder="0x..."
            className="w-full px-3 py-2 border border-gray-300 rounded-lg text-sm"
          />
        </div>
        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">Token</label>
          <select className="w-full px-3 py-2 border border-gray-300 rounded-lg text-sm">
            <option>MOCK</option>
          </select>
        </div>
      </div>

      <div className="grid grid-cols-3 gap-4 mb-4">
        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">Principal (MOCK)</label>
          <input
            type="number"
            value={principal}
            onChange={(e) => { setPrincipal(e.target.value); updatePreview() }}
            className="w-full px-3 py-2 border border-gray-300 rounded-lg text-sm"
          />
        </div>
        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">Completion Fee</label>
          <input
            type="number"
            value={completionFee}
            onChange={(e) => { setCompletionFee(e.target.value); updatePreview() }}
            className="w-full px-3 py-2 border border-gray-300 rounded-lg text-sm"
          />
        </div>
        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">Activation Fee</label>
          <input
            type="number"
            value={activationFee}
            onChange={(e) => setActivationFee(e.target.value)}
            className="w-full px-3 py-2 border border-gray-300 rounded-lg text-sm"
          />
        </div>
      </div>

      <div className="grid grid-cols-4 gap-4 mb-4">
        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">Fiat (hrs)</label>
          <input
            type="number"
            value={fiatDuration}
            onChange={(e) => setFiatDuration(e.target.value)}
            className="w-full px-3 py-2 border border-gray-300 rounded-lg text-sm"
          />
        </div>
        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">Release (hrs)</label>
          <input
            type="number"
            value={releaseDuration}
            onChange={(e) => setReleaseDuration(e.target.value)}
            className="w-full px-3 py-2 border border-gray-300 rounded-lg text-sm"
          />
        </div>
        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">Dispute (hrs)</label>
          <input
            type="number"
            value={disputeDuration}
            onChange={(e) => setDisputeDuration(e.target.value)}
            className="w-full px-3 py-2 border border-gray-300 rounded-lg text-sm"
          />
        </div>
        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">Dispute BPS</label>
          <input
            type="number"
            value={disputeBps}
            onChange={(e) => { setDisputeBps(e.target.value); updatePreview() }}
            className="w-full px-3 py-2 border border-gray-300 rounded-lg text-sm"
          />
        </div>
      </div>

      {preview && (
        <div className="bg-gray-50 rounded-lg p-4 mb-4">
          <h4 className="text-sm font-medium text-gray-700 mb-2">Dispute Timeout Preview</h4>
          <div className="text-sm text-gray-600 space-y-1">
            <div>Provider gets: <span className="font-mono">{preview.providerGets.toString()}</span> MOCK</div>
            <div>You get back: <span className="font-mono">{preview.holderGets.toString()}</span> MOCK</div>
            <div>Completion fee: <span className="font-mono">{preview.feeGets.toString()}</span> MOCK</div>
          </div>
        </div>
      )}

      <button
        onClick={createDeal}
        disabled={loading || !provider}
        className="w-full bg-blue-600 text-white py-2 px-4 rounded-lg hover:bg-blue-700 transition disabled:opacity-50"
      >
        {loading ? 'Creating...' : 'Create Deal (requires counterparty)'}
      </button>
    </div>
  )
}
