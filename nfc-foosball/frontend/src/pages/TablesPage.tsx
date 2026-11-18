import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { callApi } from '../lib/api'
import AppHeader from '../components/AppHeader'
import './css/TablesPage.css'

type TableRow = {
  slug: string
  name: string
  competition_name: string | null
  match_status: 'open' | 'in_progress' | null
  format: 'singles' | 'doubles' | null
  players: number
  capacity: number | null
}

function statusOf(r: TableRow) {
  if (r.match_status === 'open') {
    return {
      kind: 'waiting',
      pill: 'Waiting for players',
      text: `${r.players} of ${r.capacity} joined (${r.format})`,
      action: 'Join',
    }
  }
  if (r.match_status === 'in_progress') {
    return { kind: 'busy', pill: 'In progress', text: `Match running (${r.format})`, action: 'Open' }
  }
  return { kind: 'free', pill: 'Free', text: 'Nobody is playing. Start a match.', action: 'Play' }
}

export default function TablesPage() {
  const [rows, setRows] = useState<TableRow[] | null>(null)
  const [error, setError] = useState<string | null>(null)

  // Refresh every 5 seconds so the list follows the tables.
  useEffect(() => {
    let stopped = false
    const load = async () => {
      try {
        const r = await callApi<TableRow[]>('list_tables')
        if (!stopped) {
          setRows(r)
          setError(null)
        }
      } catch (e) {
        if (!stopped) setError((e as Error).message)
      }
    }
    void load()
    const timer = setInterval(load, 5000)
    return () => {
      stopped = true
      clearInterval(timer)
    }
  }, [])

  return (
    <main className="tables-page">
      <AppHeader />
      <h1>Choose a table</h1>
      <p className="sub">
        Tapping the NFC tag on a table takes you straight there. Use this list when you are not at
        the table.
      </p>

      {error && <p className="msg error" role="alert">{error}</p>}
      {!rows && !error && <p className="status">Loading…</p>}
      {rows && rows.length === 0 && <p className="status">No tables are available yet.</p>}

      <ul className="table-list">
        {rows?.map(r => {
          const st = statusOf(r)
          return (
            <li key={r.slug}>
              <Link to={`/t/${r.slug}`} className="table-card">
                <div className="info">
                  <span className="name">{r.name}</span>
                  {r.competition_name && <span className="badge">{r.competition_name}</span>}
                  <span className="text">{st.text}</span>
                </div>
                <div className="side">
                  <span className={`pill ${st.kind}`}>{st.pill}</span>
                  <span className="action">{st.action}</span>
                </div>
              </Link>
            </li>
          )
        })}
      </ul>
    </main>
  )
}
