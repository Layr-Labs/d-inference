package registry

import (
	"testing"
	"time"
)

func TestDisconnectSourcesAgreeAtVersionResetBoundary(t *testing.T) {
	r := New(testLogger())
	p := bindVersionedSession(t, r, "disconnect-timestamp", "0.8.1", false)
	// A recorder can resolve the live Provider before Disconnect, then reach
	// the gate after another recorder has resolved the disconnect cache.
	liveSource := r.captureDisconnectSource(p.ID)
	r.DisconnectWithReason(p.ID, DisconnectReasonReadError)
	cachedSource := r.captureDisconnectSource(p.ID)
	if liveSource.p != p || cachedSource.p != nil || cachedSource.at.IsZero() {
		t.Fatal("expected one live reference and one cached disconnect source")
	}
	droppedNS := p.gateDisconnectedAtNS.Load()
	if droppedNS == 0 {
		t.Fatal("disconnect did not date the live reference")
	}
	g := r.lookupGateForKey(versionResetStable)
	if g == nil {
		t.Fatal("disconnect lost the stable identity's gate")
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	// Model the exact cutoff of a reset concurrent with detachment. With two
	// clock reads, the live source is superseded here but the later cache
	// timestamp lets the same old 502 poison the reset gate. A single event
	// timestamp gives both recorder paths the same decision at the boundary.
	g.versionResetAt = time.Unix(0, droppedNS)
	if !liveSource.supersededBy(g) || !cachedSource.supersededBy(g) {
		t.Fatalf("sources disagree at reset cutoff: live=%v cached=%v live_at=%s cached_at=%s",
			liveSource.supersededBy(g), cachedSource.supersededBy(g), g.versionResetAt, cachedSource.at)
	}
	// A reset preceding that disconnect must retain both strikes, preserving
	// same-version churn and the version-reset throttle's later-fault rule.
	g.versionResetAt = time.Unix(0, droppedNS-1)
	if liveSource.supersededBy(g) || cachedSource.supersededBy(g) {
		t.Fatal("a reset before the disconnect suppressed a later flush")
	}
}
