//go:build pilotload

package store

// PilotPoolStats is compiled only into pilot-load binaries. Production builds
// have no counter surface or pool-introspection method.
func (s *PostgresStore) PilotPoolStats() (used, capacity int) {
	stats := s.pool.Stat()
	return int(stats.AcquiredConns()), int(stats.MaxConns())
}
