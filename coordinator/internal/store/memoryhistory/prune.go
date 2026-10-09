package memoryhistory

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
func (s *State) Prune(maxEntries int) {
	if maxEntries <= 0 {
		maxEntries = store.DefaultPruneMaxEntries
	}

	if n := len(s.Usage); n > maxEntries {
		s.Usage = append([]store.UsageRecord(nil), s.Usage[n-maxEntries:]...)
	}
	if n := len(s.LedgerEntries); n > maxEntries {
		s.LedgerEntries = append([]store.LedgerEntry(nil), s.LedgerEntries[n-maxEntries:]...)
	}
	if n := len(s.ProviderEarnings); n > maxEntries {
		for _, earning := range s.ProviderEarnings[:n-maxEntries] {
			if earning.Model == "base_reward" || earning.AmountMicroUSD == 0 {
				continue
			}
			source := EarningSource{earning.AccountID, earning.ProviderID, earning.ProviderKey}
			if prior, ok := s.EarningsPrunedThrough[source]; !ok || earning.CreatedAt.After(prior) {
				s.EarningsPrunedThrough[source] = earning.CreatedAt
			}
		}
		s.ProviderEarnings = append([]store.ProviderEarning(nil), s.ProviderEarnings[n-maxEntries:]...)
	}
	if n := len(s.ProviderSessions); n > maxEntries {
		for _, session := range s.ProviderSessions[:n-maxEntries] {
			if session.AccountID != "" && session.ProviderKey != "" {
				s.ProviderKeysPruned[session.AccountID] = true
			}
			window := SessionUptimeWindow{AccountID: session.AccountID, Start: session.ConnectedAt}
			if session.DisconnectedAt != nil {
				window.End = *session.DisconnectedAt
				if graceEnd := session.LastSeen.Add(90 * time.Second); graceEnd.Before(window.End) {
					window.End = graceEnd
				}
			}
			if prior, exists := s.ProviderUptimePruned[session.SessionID]; exists {
				if prior.Start.Before(window.Start) {
					window.Start = prior.Start
				}
				if prior.End.IsZero() || !window.End.IsZero() && prior.End.After(window.End) {
					window.End = prior.End
				}
			}
			s.ProviderUptimePruned[session.SessionID] = window
		}
		s.ProviderSessions = append([]store.ProviderSession(nil), s.ProviderSessions[n-maxEntries:]...)
	}
	if n := len(s.LogReports); n > maxEntries {
		s.LogReports = append([]store.LogReport(nil), s.LogReports[n-maxEntries:]...)
	}
	// Floor-draw audit rows are bounded, but the floorDrawKeys idempotency map is
	// intentionally NOT pruned — it is the authoritative dedupe guard and dropping
	// it could let a re-settle double-credit.
	if n := len(s.ProviderFloorDraws); n > maxEntries {
		s.ProviderFloorDraws = append([]store.ProviderFloorDraw(nil), s.ProviderFloorDraws[n-maxEntries:]...)
	}
	// System profiler slices. The write-once key set is rebuilt from the kept
	// rows so a pruned (request_id, attempt) can be written again later, as it
	// can in Postgres after the retention DELETE.
	if n := len(s.RequestProfiles); n > maxEntries {
		s.RequestProfiles = append([]store.RequestProfileRecord(nil), s.RequestProfiles[n-maxEntries:]...)
		s.rebuildRequestProfileKeysLocked()
	}
	if n := len(s.FleetSnapshots); n > maxEntries {
		s.FleetSnapshots = append([]store.FleetSnapshotRow(nil), s.FleetSnapshots[n-maxEntries:]...)
	}
	// Expired device codes can be dropped outright.
	now := time.Now()
	for code, dc := range s.DeviceCodesByCode {
		if now.After(dc.ExpiresAt) {
			delete(s.DeviceCodesByCode, code)
			delete(s.DeviceCodesByUserCode, dc.UserCode)
		}
	}
}
