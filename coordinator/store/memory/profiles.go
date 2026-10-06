package memory

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *MemoryStore) RecordRequestProfiles(records []*store.RequestProfileRecord) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.history.RecordRequestProfiles(records)
}
func (s *MemoryStore) RequestProfilesSinceFiltered(since time.Time, filter store.RequestProfileFilter) []store.RequestProfileRecord {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.history.RequestProfilesSinceFiltered(since, filter)
}
func (s *MemoryStore) RecordFleetSnapshots(rows []store.FleetSnapshotRow) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.history.RecordFleetSnapshots(rows)
}
func (s *MemoryStore) FleetSnapshotsSince(since time.Time) []store.FleetSnapshotRow {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.history.FleetSnapshotsSince(since)
}
func (s *MemoryStore) PruneTelemetry(ctx context.Context, profilesBefore, snapshotsBefore time.Time, batch int) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.history.PruneTelemetry(ctx, profilesBefore, snapshotsBefore, batch)
}
