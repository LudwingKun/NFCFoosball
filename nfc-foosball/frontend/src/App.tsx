import { Routes, Route, Navigate } from 'react-router-dom'
import LoginPage from './pages/LoginPage'
import TablePage from './pages/TablePage'
import LeaderboardPage from './pages/LeaderboardPage'
import ProtectedRoute from './components/ProtectedRoute'

export default function App() {
  return (
    <Routes>
      <Route path="/login" element={<LoginPage />} />
      {/* This is the URL written on the NFC tag, e.g. /t/main */}
      <Route
        path="/t/:slug"
        element={<ProtectedRoute><TablePage /></ProtectedRoute>}
      />
      <Route
        path="/leaderboard"
        element={<ProtectedRoute><LeaderboardPage /></ProtectedRoute>}
      />
      {/* Home: for now it just opens the match page of the main table */}
      <Route path="/" element={<Navigate to="/t/main" replace />} />
    </Routes>
  )
}
