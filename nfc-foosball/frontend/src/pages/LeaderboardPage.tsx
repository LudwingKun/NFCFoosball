import { useEffect, useMemo, useState } from 'react'
import { callApi } from '../lib/api'
import { useAuth } from '../context/AuthContext'
import AppHeader from '../components/AppHeader'
import './css/LeaderboardPage.css'

type Format = 'singles' | 'doubles'

type Row = {
  player_id: string
  display_name: string
  format: Format
  rating: number
  games_played: number
  wins: number
  draws: number
  losses: number
  win_percentage: number
}

export default function LeaderboardPage() {
  const { session } = useAuth()
  const me = session?.user.id

  const [format, setFormat] = useState<Format>('singles')
  const [rows, setRows] = useState<Row[] | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let stale = false
    setRows(null)
    setError(null)
    callApi<Row[]>('get_leaderboard', { format, limit: 100 })
      .then(r => {
        if (!stale) setRows(r)
      })
      .catch((e: Error) => {
        if (!stale) setError(e.message)
      })
    return () => {
      stale = true
    }
  }, [format])

  // Only players who have played at least one match of this format are ranked.
  const ranked = useMemo(
    () =>
      (rows ?? [])
        .filter(r => r.games_played > 0)
        .sort(
          (a, b) =>
            b.rating - a.rating ||
            b.wins - a.wins ||
            a.display_name.localeCompare(b.display_name),
        ),
    [rows],
  )

  const mine = rows?.find(r => r.player_id === me)
  const myRank = mine && mine.games_played > 0 ? ranked.findIndex(r => r.player_id === me) + 1 : 0

  return (
    <main className="leaderboard-page">
      <AppHeader />

      <div className="format-switch" role="tablist" aria-label="Match format">
        {(['singles', 'doubles'] as const).map(f => (
          <button
            key={f}
            type="button"
            role="tab"
            aria-selected={format === f}
            className={format === f ? 'active' : ''}
            onClick={() => setFormat(f)}
          >
            {f === 'singles' ? 'Singles' : 'Doubles'}
          </button>
        ))}
      </div>

      {error && <p className="msg error" role="alert">{error}</p>}
      {!rows && !error && <p className="status">Loading…</p>}

      {rows && (
        <>
          <section className="my-stats" aria-label="Your stats">
            {mine && mine.games_played > 0 ? (
              <>
                <Stat label="Rating" value={mine.rating} />
                <Stat label="Rank" value={`#${myRank}`} />
                <Stat label="Record (W–D–L)" value={`${mine.wins}–${mine.draws}–${mine.losses}`} />
                <Stat label="Win rate" value={`${Number(mine.win_percentage)}%`} />
              </>
            ) : (
              <p className="empty">
                Play your first {format} match to get a rank. Everyone starts at 1200.
              </p>
            )}
          </section>

          {ranked.length === 0 ? (
            <p className="empty">No {format} matches have been played yet.</p>
          ) : (
            <div className="table-scroll">
              <table>
                <thead>
                  <tr>
                    <th>#</th>
                    <th>Player</th>
                    <th>Rating</th>
                    <th>Games</th>
                    <th>W</th>
                    <th>D</th>
                    <th>L</th>
                    <th>Win %</th>
                  </tr>
                </thead>
                <tbody>
                  {ranked.map((r, i) => (
                    <tr key={r.player_id} className={r.player_id === me ? 'me' : ''}>
                      <td>{i + 1}</td>
                      <td>
                        {r.display_name}
                        {r.player_id === me && <span className="you">you</span>}
                      </td>
                      <td className="rating">{r.rating}</td>
                      <td>{r.games_played}</td>
                      <td>{r.wins}</td>
                      <td>{r.draws}</td>
                      <td>{r.losses}</td>
                      <td>{Number(r.win_percentage)}%</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </>
      )}
    </main>
  )
}

function Stat({ label, value }: { label: string; value: string | number }) {
  return (
    <div className="stat">
      <span className="stat-value">{value}</span>
      <span className="stat-label">{label}</span>
    </div>
  )
}
