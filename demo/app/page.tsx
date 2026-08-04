'use client'

import { useState, useEffect } from 'react'
import { type Address } from 'viem'
import ConnectWallet from '@/components/ConnectWallet'
import DealCreator from '@/components/DealCreator'
import DealDashboard from '@/components/DealDashboard'
import PositionList from '@/components/PositionList'
import EventFeed from '@/components/EventFeed'
import TimeTravel from '@/components/TimeTravel'
import { CONTRACTS } from '@/lib/contracts'

export default function Home() {
  const [account, setAccount] = useState<Address | null>(null)
  const [role, setRole] = useState<'holder' | 'provider'>('holder')
  const [deals, setDeals] = useState<`0x${string}`[]>([])
  const [selectedDeal, setSelectedDeal] = useState<`0x${string}` | null>(null)
  const [refreshKey, setRefreshKey] = useState(0)

  const refresh = () => setRefreshKey((k) => k + 1)

  if (!account) {
    return (
      <main className="min-h-screen flex items-center justify-center p-8">
        <div className="w-full max-w-md">
          <div className="text-center mb-8">
            <h1 className="text-4xl font-bold text-gray-900 mb-2">PluriSwap</h1>
            <p className="text-gray-600">Mandatory Core Protocol Demo</p>
          </div>
          <ConnectWallet onConnect={setAccount} />
        </div>
      </main>
    )
  }

  return (
    <main className="min-h-screen p-8">
      <div className="max-w-7xl mx-auto">
        {/* Header */}
        <div className="flex items-center justify-between mb-8">
          <div>
            <h1 className="text-3xl font-bold text-gray-900">PluriSwap Core</h1>
            <p className="text-gray-600">
              Connected as <span className="font-mono text-sm">{account}</span>
            </p>
          </div>
          <div className="flex items-center gap-4">
            <div className="flex rounded-lg border border-gray-300 overflow-hidden">
              <button
                onClick={() => setRole('holder')}
                className={`px-4 py-2 text-sm font-medium ${
                  role === 'holder'
                    ? 'bg-blue-600 text-white'
                    : 'bg-white text-gray-700 hover:bg-gray-50'
                }`}
              >
                Holder
              </button>
              <button
                onClick={() => setRole('provider')}
                className={`px-4 py-2 text-sm font-medium ${
                  role === 'provider'
                    ? 'bg-blue-600 text-white'
                    : 'bg-white text-gray-700 hover:bg-gray-50'
                }`}
              >
                Provider
              </button>
            </div>
            <button
              onClick={() => setAccount(null)}
              className="px-4 py-2 text-sm text-gray-600 hover:text-gray-900"
            >
              Disconnect
            </button>
          </div>
        </div>

        <div className="grid grid-cols-1 lg:grid-cols-3 gap-8">
          {/* Left column: Actions */}
          <div className="lg:col-span-2 space-y-8">
            <TimeTravel onTimeChange={refresh} />

            {role === 'holder' && (
              <DealCreator
                account={account}
                onDealCreated={(dealId) => {
                  setDeals((d) => [...d, dealId])
                  refresh()
                }}
              />
            )}

            <DealDashboard
              account={account}
              role={role}
              deals={deals}
              selectedDeal={selectedDeal}
              onSelectDeal={setSelectedDeal}
              onAction={refresh}
              key={refreshKey}
            />
          </div>

          {/* Right column: Positions & Events */}
          <div className="space-y-8">
            <PositionList account={account} key={`pos-${refreshKey}`} onWithdraw={refresh} />
            <EventFeed key={`evt-${refreshKey}`} />
          </div>
        </div>
      </div>
    </main>
  )
}
