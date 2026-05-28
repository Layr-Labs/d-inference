package liveness

import (
	"context"
	"encoding/json"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// Synthetic provider session traces and the features they should produce.
// Built so each math path (uptime, MTBF, percentiles, P(stays N hours)) is
// exercised by at least one provider.
func TestComputeFeaturesBasic(t *testing.T) {
	// Window: 14 days; "now" anchored for determinism.
	now := time.Date(2026, 5, 22, 12, 0, 0, 0, time.UTC)
	windowDays := 14
	since := now.Add(-time.Duration(windowDays) * 24 * time.Hour)

	// Provider with three completed sessions of 5h, 1h, 9h plus one open.
	rows := []store.SessionRow{
		{ProviderID: "p", ConnectedAt: since.Add(1 * time.Hour), DisconnectedAt: since.Add(6 * time.Hour), DisconnectReason: store.DisconnectReasonCleanClose},   // 5h
		{ProviderID: "p", ConnectedAt: since.Add(48 * time.Hour), DisconnectedAt: since.Add(49 * time.Hour), DisconnectReason: store.DisconnectReasonReadError},  // 1h
		{ProviderID: "p", ConnectedAt: since.Add(72 * time.Hour), DisconnectedAt: since.Add(81 * time.Hour), DisconnectReason: store.DisconnectReasonCleanClose}, // 9h
		{ProviderID: "p", ConnectedAt: now.Add(-30 * time.Minute)}, // still open
	}

	f := computeFeatures("p", rows, since, now, windowDays)

	if f.SessionsCount != 4 {
		t.Fatalf("sessions_count: want 4, got %d", f.SessionsCount)
	}
	// Two of 4 sessions are ≥ 4h → 50%; one is ≥ 8h → 25%.
	if f.PStays4h != 0.5 {
		t.Fatalf("p_stays_4h: want 0.5, got %v", f.PStays4h)
	}
	if f.PStays8h != 0.25 {
		t.Fatalf("p_stays_8h: want 0.25, got %v", f.PStays8h)
	}
	// Percentile sanity: sorted durations are 1800s (open), 3600s, 18000s, 32400s.
	if f.MedianSessionSeconds < 3000 || f.MedianSessionSeconds > 20000 {
		t.Fatalf("median_session_seconds out of plausible range: %d", f.MedianSessionSeconds)
	}
	// Uptime: 5+1+9+0.5 = 15.5h on a 14d window = 15.5/336 ≈ 0.046.
	if f.UptimePct < 0.04 || f.UptimePct > 0.05 {
		t.Fatalf("uptime_pct off: %v", f.UptimePct)
	}
	// Disconnect reasons present in JSON for the 3 closed sessions.
	var reasons map[string]int
	if err := json.Unmarshal(f.DisconnectReasons, &reasons); err != nil {
		t.Fatalf("disconnect_reasons not valid JSON: %v", err)
	}
	if reasons[store.DisconnectReasonCleanClose] != 2 {
		t.Fatalf("expected 2 clean_close, got %v", reasons)
	}
	if reasons[store.DisconnectReasonReadError] != 1 {
		t.Fatalf("expected 1 read_error, got %v", reasons)
	}
	// Last disconnect: from the 9h session ending at since+81h.
	wantLastDisc := since.Add(81 * time.Hour)
	if !f.LastDisconnectAt.Equal(wantLastDisc) {
		t.Fatalf("last_disconnect_at: want %v, got %v", wantLastDisc, f.LastDisconnectAt)
	}
	// MTBF: gaps between (close → next open) are (48-6)=42h and (72-49)=23h.
	// Mean = 32.5h = 117000s.
	if f.MTBFSeconds < 100000 || f.MTBFSeconds > 130000 {
		t.Fatalf("mtbf_seconds off: %d (want ~117000)", f.MTBFSeconds)
	}
}

// featuresFake captures rollup output for verifying the loop wiring.
type featuresFake struct {
	mu       sync.Mutex
	sessions []store.SessionRow
	failList bool
	upserts  []store.ReliabilityFeatures
}

func (f *featuresFake) ListSessionsSince(_ context.Context, _ time.Time) ([]store.SessionRow, error) {
	if f.failList {
		return nil, errors.New("simulated list failure")
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make([]store.SessionRow, len(f.sessions))
	copy(out, f.sessions)
	return out, nil
}

func (f *featuresFake) UpsertReliabilityFeatures(_ context.Context, row store.ReliabilityFeatures) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.upserts = append(f.upserts, row)
	return nil
}

// One run of the rollup should upsert one row per provider seen.
func TestFeaturesRollupOneRowPerProvider(t *testing.T) {
	now := time.Now()
	q := &featuresFake{
		sessions: []store.SessionRow{
			{ProviderID: "a", ConnectedAt: now.Add(-time.Hour), DisconnectedAt: now.Add(-30 * time.Minute), DisconnectReason: store.DisconnectReasonCleanClose},
			{ProviderID: "b", ConnectedAt: now.Add(-2 * time.Hour)}, // still open
			{ProviderID: "b", ConnectedAt: now.Add(-5 * time.Hour), DisconnectedAt: now.Add(-3 * time.Hour), DisconnectReason: store.DisconnectReasonStaleHeartbeat},
		},
	}
	runFeatures(context.Background(), q, quietLogger(), nil, FeaturesConfig{WindowDays: 14})

	q.mu.Lock()
	defer q.mu.Unlock()
	if len(q.upserts) != 2 {
		t.Fatalf("expected 2 upserts (one per provider), got %d", len(q.upserts))
	}
	seen := map[string]bool{}
	for _, r := range q.upserts {
		seen[r.ProviderID] = true
	}
	if !seen["a"] || !seen["b"] {
		t.Fatalf("missing providers: %v", q.upserts)
	}
}

// On query error the loop logs + counts + does not write upserts.
func TestFeaturesRollupStopsOnListError(t *testing.T) {
	q := &featuresFake{failList: true}
	var (
		mu       sync.Mutex
		counters []string
	)
	count := func(name string, _ int64) {
		mu.Lock()
		counters = append(counters, name)
		mu.Unlock()
	}
	runFeatures(context.Background(), q, quietLogger(), count, FeaturesConfig{WindowDays: 14})

	if len(q.upserts) != 0 {
		t.Fatalf("expected no upserts on list error, got %d", len(q.upserts))
	}
	mu.Lock()
	defer mu.Unlock()
	found := false
	for _, c := range counters {
		if c == "liveness_features_errors_total" {
			found = true
		}
	}
	if !found {
		t.Fatalf("expected error counter to fire, got %v", counters)
	}
}
