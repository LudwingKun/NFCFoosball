import { useEffect, useState } from 'react'
import { callApi } from '../lib/api'
import { supabase } from '../lib/supabase'

export default function LeaderboardPage() {
  const [rows, setRows] = useState<unknown[] | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    callApi<unknown[]>('get_leaderboard', { format: 'singles', limit: 20 })
      .then(setRows)
      .catch(e => setError(e.message))
  }, [])

  return (
    <div>
      <button onClick={() => supabase.auth.signOut()}>Sign out</button>
      <h1>Leaderboard</h1>
      {error && <p style={{ color: 'crimson' }}>{error}</p>}
      <pre>{JSON.stringify(rows, null, 2)}</pre>
    </div>
  )
}