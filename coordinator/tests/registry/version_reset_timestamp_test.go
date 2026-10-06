package registry_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/identitygate"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestDisconnectSourcesAgreeAtVersionResetBoundary(t *testing.T) {
	droppedAt := time.Now()
	for _, resetAt := range []time.Time{droppedAt, droppedAt.Add(-time.Nanosecond)} {
		r, gates, clock := newVersionGateRegistry(droppedAt)
		p := bindVersionedSession(t, r, "disconnect-timestamp", "0.8.1", false)
		// The first recorder resolves a live session; the second resolves the
		// same event through the cache after the real disconnect operation.
		ref := gates.ResolveSession(p.ID, false)
		liveSource := gates.CaptureDisconnectSource(p.ID)
		r.DisconnectWithReason(p.ID, production.DisconnectReasonReadError)
		cachedSource := gates.CaptureDisconnectSource(p.ID)
		if liveSource == cachedSource || cachedSource == (identitygate.DisconnectSource{}) {
			t.Fatal("expected one live reference and one cached disconnect source")
		}
		if !gates.ViewIdentity(versionResetStable).Present() {
			t.Fatal("disconnect lost the stable identity's gate")
		}
		// Replaying the reset at each event timestamp tests the exact cutoff
		// without replacing a timestamp inside the retained identity state.
		clock.set(resetAt)
		bindVersionedSession(t, r, "replacement-timestamp", "0.8.2", false)
		live := gates.SupersedesDisconnect(ref, liveSource)
		cached := gates.SupersedesDisconnect(ref, cachedSource)
		if resetAt.Equal(droppedAt) {
			if !live {
				t.Fatal("disconnect did not date the live reference")
			}
			if !live || !cached {
				t.Fatalf("sources disagree at reset cutoff: live=%v cached=%v live_at=%s cached_at=%s",
					live, cached, resetAt, droppedAt)
			}
		} else if live || cached {
			t.Fatal("a reset before the disconnect suppressed a later flush")
		}
	}
}
