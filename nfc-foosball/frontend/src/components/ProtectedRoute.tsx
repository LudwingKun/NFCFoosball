import { Navigate, useLocation } from 'react-router-dom'
import type { ReactNode } from 'react'
import { useAuth } from '../context/AuthContext'

export default function ProtectedRoute({ children }: { children: ReactNode }) {
  const { session, loading } = useAuth()
  const location = useLocation()

  if (loading) return <p>Loading...</p>

  // Remember where the user was going (e.g. /t/main) so login can send them back.
  if (!session) return <Navigate to="/login" replace state={{ from: location }} />

  return <>{children}</>
}
