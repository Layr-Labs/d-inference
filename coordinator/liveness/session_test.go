package liveness

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestSessionTrackerOpenClose(t *testing.T) {
	s := store.NewMemory("")
	tr := NewSessionTracker(s, quietLogger(), "coord-A")

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
	s := store.NewMemory("")
	tr := NewSessionTracker(s, quietLogger(), "coord-A")

	// Should not panic, should not error-log loudly.
	tr.Close("unknown-prov", store.DisconnectReasonStaleHeartbeat, time.Time{}, 0, 0)
}
