package liveness

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestSessionTrackerOpenClose(t *testing.T) {
	s := store.NewMemory(store.Config{})
	tr := NewSessionTracker(s, quietLogger(), nil, "coord-A")

	tr.Open("prov-1")
	tr.Open("prov-2")

	// Close prov-1 cleanly. Both store and tracker should reflect that.
	tr.Close("prov-1", store.DisconnectReasonCleanClose, time.Now(), 3, 100)

	// prov-2 is still open; orphan-sweep should pick it up.
	closed, err := tr.CloseOrphans(context.Background())
	if err != nil {
		t.Fatalf("CloseOrphans: %v", err)
	}
	if closed < 1 {
		t.Fatalf("expected ≥1 orphan closed, got %d", closed)
	}

	// Second Close on prov-1 is a no-op (idempotent — tracker dropped the id).
	tr.Close("prov-1", store.DisconnectReasonReadError, time.Now(), 0, 0)
}

func TestSessionTrackerCloseWithoutOpen(t *testing.T) {
	// If we never observed an Open (e.g. coordinator restarted mid-session),
	// Close should be a silent no-op — orphan sweep on the prior boot handles it.
	s := store.NewMemory(store.Config{})
	tr := NewSessionTracker(s, quietLogger(), nil, "coord-A")

	// Should not panic, should not error-log loudly.
	tr.Close("unknown-prov", store.DisconnectReasonStaleHeartbeat, time.Time{}, 0, 0)
}

// closeFailStore wraps a memory store and forces CloseSession to fail. All
// other methods delegate to the embedded store so Open / CloseOrphans / etc.
// behave normally.
type closeFailStore struct {
	store.Store
}

func (closeFailStore) CloseSession(context.Context, int64, string, time.Time, time.Time, int64, int64) error {
	return errors.New("simulated close failure")
}

func TestSessionTrackerCloseFailureCounter(t *testing.T) {
	// When the underlying store fails, the tracker has already forgotten the
	// session (orphan sweep handles eventual recovery). Operators need a
	// counter signal so they can alarm before the next reboot.
	s := closeFailStore{Store: store.NewMemory(store.Config{})}

	var counters []struct {
		name  string
		value int64
	}
	var total atomic.Int64
	count := func(name string, value int64) {
		counters = append(counters, struct {
			name  string
			value int64
		}{name, value})
		total.Add(value)
	}

	tr := NewSessionTracker(s, quietLogger(), count, "coord-A")
	tr.Open("prov-1")
	tr.Close("prov-1", store.DisconnectReasonCleanClose, time.Now(), 0, 0)

	if got := total.Load(); got != 1 {
		t.Fatalf("expected counter total 1 after first close, got %d", got)
	}
	if len(counters) != 1 || counters[0].name != "liveness_session_close_failed_total" {
		t.Fatalf("expected liveness_session_close_failed_total to be incremented, got %+v", counters)
	}

	// Idempotent guard: tracker already deleted the entry on the first call,
	// so a second Close for the same provider must NOT re-bump the counter.
	tr.Close("prov-1", store.DisconnectReasonReadError, time.Now(), 0, 0)
	if got := total.Load(); got != 1 {
		t.Fatalf("expected counter total to stay at 1 after idempotent re-close, got %d", got)
	}
}
