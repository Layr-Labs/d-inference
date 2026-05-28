package liveness

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// retentionFakeStore wraps an in-memory store and lets the test count
// DeleteHeartbeatsBefore invocations + force errors.
type retentionFakeStore struct {
	*store.MemoryStore
	mu      sync.Mutex
	calls   int
	failN   int
	deleted atomic.Int64
}

func (s *retentionFakeStore) DeleteHeartbeatsBefore(ctx context.Context, before time.Time, limit int) (int64, error) {
	s.mu.Lock()
	s.calls++
	if s.failN > 0 {
		s.failN--
		s.mu.Unlock()
		return 0, errors.New("simulated delete failure")
	}
	s.mu.Unlock()
	n, err := s.MemoryStore.DeleteHeartbeatsBefore(ctx, before, limit)
	s.deleted.Add(n)
	return n, err
}

func (s *retentionFakeStore) callCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.calls
}

func seedHeartbeats(t *testing.T, s store.Store, providerID string, age time.Duration, n int) {
	t.Helper()
	now := time.Now().Add(-age)
	events := make([]store.HeartbeatEvent, n)
	for i := range events {
		events[i] = store.HeartbeatEvent{
			ProviderID:   providerID,
			At:           now.Add(time.Duration(i) * time.Millisecond),
			Status:       "idle",
			ThermalState: "nominal",
		}
	}
	if err := s.AppendHeartbeats(context.Background(), events); err != nil {
		t.Fatalf("AppendHeartbeats: %v", err)
	}
}

// runRetention drains in batches until 0 or budget elapses.
func TestRetentionDrainsBacklog(t *testing.T) {
	fs := &retentionFakeStore{MemoryStore: store.NewMemory(store.Config{})}
	seedHeartbeats(t, fs, "p", 48*time.Hour, 25)
	seedHeartbeats(t, fs, "p", time.Minute, 5) // fresh, must survive

	cfg := RetentionConfig{
		Interval: time.Hour, // not used directly here; we call runRetention once
		Window:   24 * time.Hour,
		Batch:    7,
	}.withDefaults()

	runRetention(context.Background(), fs, quietLogger(), nil, cfg)

	if got := fs.deleted.Load(); got != 25 {
		t.Fatalf("expected 25 rows deleted, got %d", got)
	}
	// At Batch=7, drains in ceil(25/7)=4 successful calls + 1 zero-return call = 5
	if calls := fs.callCount(); calls < 4 {
		t.Fatalf("expected at least 4 DELETE calls to drain backlog, got %d", calls)
	}
}

// A delete error should be logged + counted, not crash; loop exits cleanly.
func TestRetentionStopsOnError(t *testing.T) {
	fs := &retentionFakeStore{
		MemoryStore: store.NewMemory(store.Config{}),
		failN:       1,
	}
	seedHeartbeats(t, fs, "p", 48*time.Hour, 5)

	var (
		mu       sync.Mutex
		counters []string
	)
	count := func(name string, _ int64) {
		mu.Lock()
		counters = append(counters, name)
		mu.Unlock()
	}

	cfg := RetentionConfig{Window: 24 * time.Hour, Batch: 100}.withDefaults()
	runRetention(context.Background(), fs, quietLogger(), count, cfg)

	mu.Lock()
	defer mu.Unlock()
	sawErr := false
	for _, c := range counters {
		if c == "liveness_retention_errors_total" {
			sawErr = true
		}
	}
	if !sawErr {
		t.Fatalf("expected error counter to fire, got %v", counters)
	}
}

// StartRetentionLoop spins the goroutine, runs once on boot, then again on
// the ticker. Cancelling the context exits cleanly.
func TestStartRetentionLoopRunsAndStops(t *testing.T) {
	fs := &retentionFakeStore{MemoryStore: store.NewMemory(store.Config{})}
	seedHeartbeats(t, fs, "p", 48*time.Hour, 3)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	StartRetentionLoop(ctx, fs, quietLogger(), nil, RetentionConfig{
		Interval: 50 * time.Millisecond,
		Window:   24 * time.Hour,
		Batch:    100,
	})

	// Wait for the eager-on-boot run + at least one ticker fire.
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if fs.callCount() >= 2 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if fs.callCount() < 2 {
		t.Fatalf("expected ≥2 calls (boot + tick), got %d", fs.callCount())
	}

	cancel()
	// Loop should exit without panicking — nothing more to assert; the test
	// would hang if the goroutine leaked, which `go test -race` would also
	// surface.
}
