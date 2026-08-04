'use client'

import { useState, useEffect } from 'react'
import { CONTRACTS } from '@/lib/contracts'
import { publicClient } from '@/lib/client'

interface Event {
  blockNumber: bigint
  transactionHash: string
  eventName: string
  args: Record<string, unknown>
}

export default function EventFeed() {
  const [events, setEvents] = useState<Event[]>([])

  useEffect(() => {
    // In a real app, we'd subscribe to logs. For demo, we poll recent events.
    const fetchEvents = async () => {
      try {
        const blockNumber = await publicClient.getBlockNumber()
        const logs = await publicClient.getLogs({
          address: [CONTRACTS.escrow, CONTRACTS.ledger],
          fromBlock: blockNumber - 100n > 0n ? blockNumber - 100n : 0n,
          toBlock: 'latest',
        })
        // Parse and set events
        setEvents(logs.slice(-10).map((log) => ({
          blockNumber: log.blockNumber,
          transactionHash: log.transactionHash,
          eventName: log.topics[0]?.slice(0, 10) || 'Unknown',
          args: log,
        })))
      } catch (e) {
        console.error('Failed to fetch events', e)
      }
    }
    fetchEvents()
    const interval = setInterval(fetchEvents, 5000)
    return () => clearInterval(interval)
  }, [])

  return (
    <div className="bg-white rounded-xl shadow p-6">
      <h3 className="text-lg font-semibold mb-4">Event Feed</h3>
      <div className="space-y-2 max-h-96 overflow-y-auto">
        {events.length === 0 ? (
          <p className="text-gray-500 text-sm">No recent events.</p>
        ) : (
          events.map((evt, i) => (
            <div key={i} className="text-sm border-b border-gray-100 pb-2">
              <div className="font-mono text-xs text-gray-500">
                Block {evt.blockNumber.toString()}
              </div>
              <div className="text-gray-700 font-mono text-xs">
                {evt.transactionHash.slice(0, 16)}...
              </div>
            </div>
          ))
        )}
      </div>
    </div>
  )
}
