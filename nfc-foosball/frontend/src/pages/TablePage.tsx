import { useCallback, useEffect, useRef, useState, type FormEvent } from 'react'
import { Link, useParams } from 'react-router-dom'
import { callApi, type ApiError } from '../lib/api'
import { useAuth } from '../context/AuthContext'
import AppHeader from '../components/AppHeader'
import './TablePage.css'

type Format = 'singles' | 'doubles'

type Participant = {
  player_id: string
  team: 'A' | 'B'
  profile: { display_name: string } | null
}

type Match = {
  id: string
  status: string
  format: Format
  team_a_score: number | null
  team_b_score: number | null
  allows_draws: boolean
  k_multiplier: number
  competition?: { name: string } | null
  table?: { name: string } | null
  participants: Participant[]
}

// Why the player is no longer in a match (shown instead of the match card).
type Ended = 'left' | 'closed'

function describe(e: unknown) {
  const err = e as ApiError
  if (err.status === 404) {
    // A wrong or retired tag/link points to a table that does not exist.
    return err.message.startsWith('Table not found')
      ? 'This table does not exist or is not active. Check the tag or the link.'
      : 'This match no longer exists.'
  }
  if (err.status === 409) {
    return 'This table is busy or the match just changed. Try again in a moment.'
  }
  return err.message || 'Something went wrong'
}

export default function TablePage() {
  const { slug = 'main' } = useParams()
  const { session } = useAuth()
  const me = session?.user.id

  const [matchId, setMatchId] = useState<string | null>(null)
  const [match, setMatch] = useState<Match | null>(null)
  const [ended, setEnded] = useState<Ended | null>(null)
  const [choosing, setChoosing] = useState(false) // nobody is playing: ask singles or doubles
  const [error, setError] = useState<string | null>(null)
  const [working, setWorking] = useState(false) // a leave/cancel request is running
  const [refresh, setRefresh] = useState(0) // bump to reload the match right away
  const joining = useRef(false) // also protects against StrictMode running the effect twice

  // Joins the table's match. The format is only used when nobody is playing yet and
  // the match has to be created; if a match already exists the player just joins it.
  const join = useCallback(async (format: Format) => {
    if (joining.current) return
    joining.current = true
    setError(null)
    try {
      // Several people tapping at once can collide (match created or deleted at the
      // same moment). On 404/409, wait a moment and retry once.
      let active: { id: string } | null = null
      for (let attempt = 0; attempt < 2; attempt++) {
        try {
          active = await callApi<{ id: string } | null>('join_table', {
            table_slug: slug,
            format,
          })
          break
        } catch (e) {
          const status = (e as ApiError).status
          if ((status !== 409 && status !== 404) || attempt === 1) throw e
          await new Promise(resolve => setTimeout(resolve, 600))
        }
      }
      if (!active) throw new Error('No match available on this table')
      setMatchId(active.id)
    } catch (e) {
      setError(describe(e))
      joining.current = false
    }
  }, [slug])

  // What happens when the page opens (an NFC tap): if a match is waiting, join it;
  // if the table is free, let the player choose singles or doubles first.
  const start = useCallback(async () => {
    setError(null)
    try {
      const active = await callApi<{ id: string } | null>('get_table_match', { table_slug: slug })
      if (active) await join('doubles') // format ignored: the existing match decides
      else setChoosing(true)
    } catch (e) {
      setError(describe(e))
    }
  }, [slug, join])

  useEffect(() => {
    void start()
  }, [start])

  function pick(format: Format) {
    setChoosing(false)
    void join(format)
  }

  // Poll the match every 3s until it is over.
  const status = match?.status
  useEffect(() => {
    if (!matchId || status === 'completed' || status === 'cancelled') return
    let stopped = false
    const load = async () => {
      try {
        const m = await callApi<Match>('get_match', { match_id: matchId })
        if (!stopped) setMatch(m)
      } catch (e) {
        if (stopped) return
        if ((e as ApiError).status === 404) {
          // The lobby was removed (nobody started it in time).
          setMatch(null)
          setMatchId(null)
          setEnded('closed')
        } else {
          setError(describe(e))
        }
      }
    }
    void load()
    const timer = setInterval(load, 3000)
    return () => {
      stopped = true
      clearInterval(timer)
    }
  }, [matchId, status, refresh])

  function playAgain() {
    setMatch(null)
    setMatchId(null)
    setEnded(null)
    setChoosing(false)
    joining.current = false
    void start()
  }

  async function leaveMatch() {
    if (!match) return
    setWorking(true)
    setError(null)
    try {
      await callApi('leave_match', { match_id: match.id })
      setMatch(null)
      setMatchId(null)
      setEnded('left')
    } catch (e) {
      setError(describe(e))
    }
    setWorking(false)
  }

  async function cancelMatch() {
    if (!match) return
    if (!window.confirm('Cancel this match? Nobody’s rating will change.')) return
    setWorking(true)
    setError(null)
    try {
      await callApi('cancel_match', { match_id: match.id })
      setRefresh(n => n + 1)
    } catch (e) {
      setError(describe(e))
    }
    setWorking(false)
  }

  const size = match ? (match.format === 'doubles' ? 2 : 1) : 0
  const teamPlayers = (t: 'A' | 'B') => match?.participants.filter(p => p.team === t) ?? []
  const joined = match?.participants.length ?? 0
  const iAmIn = !!match?.participants.some(p => p.player_id === me)

  return (
    <main className="table-page">
      <AppHeader playTo={`/t/${slug}`} />
      <p className="table-name">Table: {match?.table?.name ?? slug}</p>

      {error && (
        <div className="msg error" role="alert">
          <p>{error}</p>
          {!matchId && !ended && <button onClick={() => void start()}>Try again</button>}
        </div>
      )}

      {!match && !ended && !error && !choosing && <p className="status">Joining the table…</p>}

      {choosing && !match && (
        <section className="card">
          <p className="status">Nobody is playing at this table. What do you want to play?</p>
          <div className="format-choice">
            <button className="primary" onClick={() => pick('singles')}>
              Singles
              <span>1 vs 1</span>
            </button>
            <button className="primary" onClick={() => pick('doubles')}>
              Doubles
              <span>2 vs 2</span>
            </button>
          </div>
          <p className="hint">The others who tap this table will join your match.</p>
        </section>
      )}

      {ended && (
        <section className="card">
          <p className="status">
            {ended === 'left'
              ? 'You left the match.'
              : 'This match was closed because it never started.'}
          </p>
          <div className="actions">
            <button className="primary" onClick={playAgain}>Join a match</button>
            <Link to="/leaderboard">Leaderboard</Link>
          </div>
        </section>
      )}

      {match && (
        <section className="card">
          {match.competition && (
            <p className="badge">
              {match.competition.name}: ratings count ×{Number(match.k_multiplier)}
            </p>
          )}
          <p className="status">
            {match.status === 'open' &&
              `Waiting for players: ${joined} of ${size * 2} joined`}
            {match.status === 'in_progress' && 'Match in progress. Enter the score when you finish.'}
            {match.status === 'completed' &&
              (match.team_a_score === match.team_b_score
                ? `Draw: ${match.team_a_score} to ${match.team_b_score}`
                : `Final score: ${match.team_a_score} to ${match.team_b_score}`)}
            {match.status === 'cancelled' && 'This match was cancelled.'}
            {!['open', 'in_progress', 'completed', 'cancelled'].includes(match.status) && match.status}
          </p>

          <div className="teams">
            <TeamColumn name="Team A" players={teamPlayers('A')} size={size} me={me} />
            <TeamColumn name="Team B" players={teamPlayers('B')} size={size} me={me} />
          </div>

          {match.status === 'open' && iAmIn && (
            <div className="lobby-actions">
              <p className="hint">The match starts by itself when everyone has joined. Empty lobbies close after 30 minutes.</p>
              <button className="secondary" onClick={() => void leaveMatch()} disabled={working}>
                {working ? 'Leaving…' : 'Leave match'}
              </button>
            </div>
          )}

          {match.status === 'in_progress' && iAmIn && (
            <>
              <ResultForm
                matchId={match.id}
                allowsDraws={match.allows_draws}
                onSubmitted={() => setRefresh(n => n + 1)}
              />
              <div className="lobby-actions">
                <button className="secondary" onClick={() => void cancelMatch()} disabled={working}>
                  {working ? 'Cancelling…' : 'Cancel match'}
                </button>
              </div>
            </>
          )}

          {(match.status === 'completed' || match.status === 'cancelled') && (
            <div className="actions">
              <button className="primary" onClick={playAgain}>Play again</button>
              <Link to="/leaderboard">Leaderboard</Link>
            </div>
          )}
        </section>
      )}
    </main>
  )
}

function TeamColumn({
  name,
  players,
  size,
  me,
}: {
  name: string
  players: Participant[]
  size: number
  me?: string
}) {
  const empty = Math.max(0, size - players.length)
  return (
    <div className="team">
      <h2>{name}</h2>
      <ul>
        {players.map(p => (
          <li key={p.player_id} className="slot">
            {p.profile?.display_name ?? 'Player'}
            {p.player_id === me && <span className="you">you</span>}
          </li>
        ))}
        {Array.from({ length: empty }).map((_, i) => (
          <li key={`empty-${i}`} className="slot empty">Waiting for a player</li>
        ))}
      </ul>
    </div>
  )
}

function ResultForm({
  matchId,
  allowsDraws,
  onSubmitted,
}: {
  matchId: string
  allowsDraws: boolean
  onSubmitted: () => void
}) {
  const [a, setA] = useState('')
  const [b, setB] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    setError(null)
    if (Number(a) === Number(b) && !allowsDraws) {
      setError('A draw is not allowed in this match. Someone has to win.')
      return
    }
    setBusy(true)
    try {
      await callApi('submit_result', {
        match_id: matchId,
        team_a_score: Number(a),
        team_b_score: Number(b),
      })
      onSubmitted() // reload the match: it is now completed
    } catch (err) {
      setError(describe(err))
    }
    setBusy(false)
  }

  return (
    <form className="result" onSubmit={handleSubmit}>
      <div className="scores">
        <label>
          Team A score
          <input type="number" min={0} step={1} value={a} onChange={e => setA(e.target.value)} required />
        </label>
        <label>
          Team B score
          <input type="number" min={0} step={1} value={b} onChange={e => setB(e.target.value)} required />
        </label>
      </div>
      {allowsDraws && <p className="hint">Equal scores count as a draw.</p>}
      {error && <p className="msg error" role="alert">{error}</p>}
      <button type="submit" className="primary" disabled={busy}>
        {busy ? 'Submitting…' : 'Submit result'}
      </button>
    </form>
  )
}
