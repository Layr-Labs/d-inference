package liveness

import (
	"context"
	"time"
)

// MemoryStore is an in-memory liveness store used in dev/test. Returns empty
// results unless test code calls one of the Seed helpers — there is no
// background ingestion in memory mode.
type MemoryStore struct {
	rows       map[string]*ReliabilityRow
	sessions   map[string][]SessionRow
	heartbeats map[string][]HeartbeatRow
}

func NewMemoryStore() *MemoryStore {
	return &MemoryStore{
		rows:       make(map[string]*ReliabilityRow),
		sessions:   make(map[string][]SessionRow),
		heartbeats: make(map[string][]HeartbeatRow),
	}
}

func (m *MemoryStore) Backend() string                { return "memory" }
func (m *MemoryStore) Ping(_ context.Context) error    { return nil }
func (m *MemoryStore) Close()                          {}

// SeedReliability lets tests inject pre-aggregated rows.
func (m *MemoryStore) SeedReliability(row ReliabilityRow) {
	cp := row
	m.rows[row.ProviderID] = &cp
}

// SeedSessions lets tests inject per-provider session history.
func (m *MemoryStore) SeedSessions(providerID string, rows ...SessionRow) {
	m.sessions[providerID] = append(m.sessions[providerID], rows...)
}

// SeedHeartbeats lets tests inject per-provider heartbeat history.
func (m *MemoryStore) SeedHeartbeats(providerID string, rows ...HeartbeatRow) {
	m.heartbeats[providerID] = append(m.heartbeats[providerID], rows...)
}

func (m *MemoryStore) GetReliabilityFeatures(_ context.Context, providerID string) (*ReliabilityRow, error) {
	r, ok := m.rows[providerID]
	if !ok {
		return nil, nil
	}
	cp := *r
	return &cp, nil
}

func (m *MemoryStore) ListRecentSessions(_ context.Context, providerID string, since time.Time, limit int) ([]SessionRow, error) {
	all := m.sessions[providerID]
	out := make([]SessionRow, 0, len(all))
	for _, s := range all {
		if s.ConnectedAt.Before(since) {
			continue
		}
		out = append(out, s)
	}
	if len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

func (m *MemoryStore) ListRecentHeartbeats(_ context.Context, providerID string, since time.Time, limit int) ([]HeartbeatRow, error) {
	all := m.heartbeats[providerID]
	out := make([]HeartbeatRow, 0, len(all))
	for _, h := range all {
		if h.At.Before(since) {
			continue
		}
		out = append(out, h)
	}
	if len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

func (m *MemoryStore) ListReliable(_ context.Context, filter ReliabilityFilterInput) ([]ReliabilityRow, error) {
	out := make([]ReliabilityRow, 0, len(m.rows))
	for _, r := range m.rows {
		if r.UptimePct < filter.MinUptimePct {
			continue
		}
		if r.PStays4h < filter.MinPStays4h {
			continue
		}
		if r.PStays8h < filter.MinPStays8h {
			continue
		}
		out = append(out, *r)
	}
	if filter.Limit > 0 && len(out) > filter.Limit {
		out = out[:filter.Limit]
	}
	return out, nil
}

func (m *MemoryStore) FleetSummary(_ context.Context) (FleetAvailability, error) {
	rows := make([]ReliabilityRow, 0, len(m.rows))
	for _, r := range m.rows {
		rows = append(rows, *r)
	}
	return computeFleet(rows), nil
}
