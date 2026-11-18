import { useState, type FormEvent } from 'react'
import { Navigate, useLocation } from 'react-router-dom'
import { supabase } from '../lib/supabase'
import { useAuth } from '../context/AuthContext'
import './css/LoginPage.css'

type Mode = 'login' | 'signup'

export default function LoginPage() {
  const { session, loading } = useAuth()
  const location = useLocation()
  const [mode, setMode] = useState<Mode>('login')
  const [displayName, setDisplayName] = useState('')
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [showPassword, setShowPassword] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)

  // Where to go after login: the page the user was trying to open (a tapped NFC tag,
  // the leaderboard...), otherwise the table menu. The query string is kept, so the
  // team written on a tag survives the login.
  const from = (location.state as { from?: { pathname: string; search: string } } | null)?.from
  const destination = from ? from.pathname + from.search : '/tables'

  // Already logged in (or just logged in / signed up): go to the match page.
  if (!loading && session) return <Navigate to={destination} replace />

  const isLogin = mode === 'login'

  function switchMode(next: Mode) {
    setMode(next)
    setError(null)
    setNotice(null)
  }

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    setBusy(true)
    setError(null)
    setNotice(null)

    if (isLogin) {
      const { error } = await supabase.auth.signInWithPassword({ email, password })
      if (error) setError(error.message)
    } else {
      const { data, error } = await supabase.auth.signUp({
        email,
        password,
        options: { data: { display_name: displayName.trim() } },
      })
      if (error) setError(error.message)
      else if (!data.session) {
        setNotice('Account created. Confirm your email, then sign in.')
      }
    }

    setBusy(false)
  }

  return (
    <main className="auth">
      <section className="auth-hero">
        <div className="rings" aria-hidden="true">
          <span />
          <span />
          <span />
          <i className="tag" />
        </div>

        <p className="brand">NFC Foosball</p>

        <div className="hero-text">
          <p className="tagline">Tap in. Play. Climb the ranking.</p>
          <p className="hero-copy">
            Scan your tag at the table to join a match. Every result updates the leaderboard.
          </p>
        </div>
      </section>

      <section className="auth-panel">
        <div className="auth-card">
          <div className="mode-switch" role="tablist" aria-label="Sign in or sign up">
            <button
              type="button"
              role="tab"
              aria-selected={isLogin}
              className={isLogin ? 'active' : ''}
              onClick={() => switchMode('login')}
            >
              Sign in
            </button>
            <button
              type="button"
              role="tab"
              aria-selected={!isLogin}
              className={!isLogin ? 'active' : ''}
              onClick={() => switchMode('signup')}
            >
              Sign up
            </button>
          </div>

          <h1>{isLogin ? 'Welcome back' : 'Create your account'}</h1>
          <p className="sub">
            {!isLogin
              ? 'Pick a name. It is what other players see on the leaderboard.'
              : destination.startsWith('/leaderboard')
                ? 'Sign in to see the leaderboard.'
                : destination.startsWith('/t/')
                  ? 'Sign in to join the match.'
                  : 'Sign in to pick a table and play.'}
          </p>

          <form onSubmit={handleSubmit}>
            {!isLogin && (
              <div className="field">
                <label htmlFor="displayName">Display name</label>
                <input
                  id="displayName"
                  value={displayName}
                  onChange={e => setDisplayName(e.target.value)}
                  autoComplete="nickname"
                  minLength={2}
                  maxLength={32}
                  required
                />
              </div>
            )}

            <div className="field">
              <label htmlFor="email">Email</label>
              <input
                id="email"
                type="email"
                value={email}
                onChange={e => setEmail(e.target.value)}
                autoComplete="email"
                required
              />
            </div>

            <div className="field">
              <label htmlFor="password">Password</label>
              <div className="password-wrap">
                <input
                  id="password"
                  type={showPassword ? 'text' : 'password'}
                  value={password}
                  onChange={e => setPassword(e.target.value)}
                  autoComplete={isLogin ? 'current-password' : 'new-password'}
                  minLength={6}
                  required
                />
                <button
                  type="button"
                  className="toggle-password"
                  onClick={() => setShowPassword(v => !v)}
                  aria-pressed={showPassword}
                  aria-controls="password"
                  aria-label={showPassword ? 'Hide password' : 'Show password'}
                >
                  {showPassword ? 'Hide' : 'Show'}
                </button>
              </div>
            </div>

            {error && <p className="msg error" role="alert">{error}</p>}
            {notice && <p className="msg notice" role="status">{notice}</p>}

            <button type="submit" className="primary" disabled={busy}>
              {busy ? (isLogin ? 'Signing in…' : 'Signing up…') : isLogin ? 'Sign in' : 'Sign up'}
            </button>
          </form>
        </div>
      </section>
    </main>
  )
}
