import { NavLink } from 'react-router-dom'
import { supabase } from '../lib/supabase'
import './AppHeader.css'

export default function AppHeader({ playTo = '/t/main' }: { playTo?: string }) {
  return (
    <header className="app-header">
      <p className="brand">NFC Foosball</p>
      <nav>
        <NavLink to={playTo}>Play</NavLink>
        <NavLink to="/leaderboard">Leaderboard</NavLink>
        <button type="button" onClick={() => supabase.auth.signOut()}>Sign out</button>
      </nav>
    </header>
  )
}
