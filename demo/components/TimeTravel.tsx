'use client'

import { useState } from 'react'
import { anvilIncreaseTime, anvilMine } from '@/lib/contracts'

interface Props {
  onTimeChange: () => void
}

export default function TimeTravel({ onTimeChange }: Props) {
  const [loading, setLoading] = useState(false)

  const travel = async (seconds: number) => {
    setLoading(true)
    try {
      await anvilIncreaseTime(seconds)
      await anvilMine()
      onTimeChange()
    } finally {
      setLoading(false)
    }
  }

  return (
    <div className="bg-white rounded-xl shadow p-6">
      <h3 className="text-lg font-semibold mb-4">Time Travel</h3>
      <div className="flex flex-wrap gap-2">
        <button
          onClick={() => travel(3600)}
          disabled={loading}
          className="px-4 py-2 bg-gray-100 hover:bg-gray-200 rounded-lg text-sm font-medium disabled:opacity-50"
        >
          +1 hour
        </button>
        <button
          onClick={() => travel(86400)}
          disabled={loading}
          className="px-4 py-2 bg-gray-100 hover:bg-gray-200 rounded-lg text-sm font-medium disabled:opacity-50"
        >
          +1 day
        </button>
        <button
          onClick={() => travel(604800)}
          disabled={loading}
          className="px-4 py-2 bg-gray-100 hover:bg-gray-200 rounded-lg text-sm font-medium disabled:opacity-50"
        >
          +1 week
        </button>
        <button
          onClick={async () => {
            setLoading(true)
            try {
              await anvilMine()
              onTimeChange()
            } finally {
              setLoading(false)
            }
          }}
          disabled={loading}
          className="px-4 py-2 bg-blue-100 hover:bg-blue-200 text-blue-700 rounded-lg text-sm font-medium disabled:opacity-50"
        >
          Mine block
        </button>
      </div>
    </div>
  )
}
