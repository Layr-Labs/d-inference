package memory

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// Prune drops the oldest entries from append-only history slices so they
// don't grow unboundedly in long-running processes. Entries are kept in
// append order, so this is equivalent to a bounded ring buffer.
//
// This is a no-op when the PostgresStore is used — Postgres has its own
// retention story (SQL DELETE or partitioning).
//
// maxEntries <= 0 uses DefaultPruneMaxEntries.
func (s *MemoryStore) Prune(maxEntries int) {
	if maxEntries <= 0 {
		maxEntries = store.DefaultPruneMaxEntries
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	if n := len(s.usage); n > maxEntries {
		s.usage = append([]store.UsageRecord(nil), s.usage[n-maxEntries:]...)
	}
	if n := len(s.ledgerEntries); n > maxEntries {
		s.ledgerEntries = append([]store.LedgerEntry(nil), s.ledgerEntries[n-maxEntries:]...)
	}
	if n := len(s.providerEarnings); n > maxEntries {
		s.providerEarnings = append([]store.ProviderEarning(nil), s.providerEarnings[n-maxEntries:]...)
	}
	if n := len(s.providerSessions); n > maxEntries {
		s.providerSessions = append([]store.ProviderSession(nil), s.providerSessions[n-maxEntries:]...)
	}
	if n := len(s.logReports); n > maxEntries {
		s.logReports = append([]store.LogReport(nil), s.logReports[n-maxEntries:]...)
	}
	// Floor-draw audit rows are bounded, but the floorDrawKeys idempotency map is
	// intentionally NOT pruned — it is the authoritative dedupe guard and dropping
	// it could let a re-settle double-credit.
	if n := len(s.providerFloorDraws); n > maxEntries {
		s.providerFloorDraws = append([]store.ProviderFloorDraw(nil), s.providerFloorDraws[n-maxEntries:]...)
	}
	// System profiler slices. The write-once key set is rebuilt from the kept
	// rows so a pruned (request_id, attempt) can be written again later, as it
	// can in Postgres after the retention DELETE.
	if n := len(s.requestProfiles); n > maxEntries {
		s.requestProfiles = append([]store.RequestProfileRecord(nil), s.requestProfiles[n-maxEntries:]...)
		s.rebuildRequestProfileKeysLocked()
	}
	if n := len(s.fleetSnapshots); n > maxEntries {
		s.fleetSnapshots = append([]store.FleetSnapshotRow(nil), s.fleetSnapshots[n-maxEntries:]...)
	}
	// Expired device codes can be dropped outright.
	now := time.Now()
	for code, dc := range s.deviceCodesByCode {
		if now.After(dc.ExpiresAt) {
			delete(s.deviceCodesByCode, code)
			delete(s.deviceCodesByUserCode, dc.UserCode)
		}
	}
}
