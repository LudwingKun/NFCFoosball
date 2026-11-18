import { Routes, Route, Navigate } from 'react-router-dom'
import LoginPage from './pages/LoginPage'
import TablePage from './pages/TablePage'
import LeaderboardPage from './pages/LeaderboardPage'
import TablesPage from './pages/TablesPage'
import ProtectedRoute from './components/ProtectedRoute'

export default function App() {
  return (
    <Routes>
      <Route path="/login" element={<LoginPage />} />
      {/* The URL written on the NFC tags: /t/main?team=A and /t/main?team=B */}
      <Route
        path="/t/:slug"
        element={<ProtectedRoute><TablePage /></ProtectedRoute>}
      />
      <Route
        path="/leaderboard"
        element={<ProtectedRoute><LeaderboardPage /></ProtectedRoute>}
      />
      {/* Table menu: for people who did not tap a tag */}
      <Route
        path="/tables"
        element={<ProtectedRoute><TablesPage /></ProtectedRoute>}
      />
      <Route path="/" element={<Navigate to="/tables" replace />} />
    </Routes>
  )
}
