package registry

import (
	"fmt"
	"testing"
	"time"
)

func TestVersionHistoryRetentionKeepsLiveRecentAndQuarantinedIdentities(t *testing.T) {
	r := New(testLogger())
	live := bindVersionedSession(t, r, "live-history", "0.9.0", false)
	now := time.Now()
	stale := now.Add(-identityVersionRetention - time.Minute)
	for _, id := range []string{versionResetStable, "departed", "recent", "quarantined", "recent-reset", "fault-window"} {
		withGateForKey(r, id, func(g *gateState) {
			g.identityVersion = "0.9.0"
			g.touched = stale
		})
	}
	withGateForKey(r, "recent", func(g *gateState) { g.touched = now })
	withGateForKey(r, "departed", func(g *gateState) { g.versionResetAt = stale })
	withGateForKey(r, "recent-reset", func(g *gateState) { g.versionResetAt = now })
	withGateForKey(r, "quarantined", func(g *gateState) { g.breakerUntil = now.Add(time.Minute) })
	withGateForKey(r, "fault-window", func(g *gateState) { g.healthWindowLocked().recordFault(now, false) })
	r.sweepGates(now)
	for _, id := range []string{versionResetStable, "recent", "quarantined", "recent-reset", "fault-window"} {
		if rawGateForKey(r, id) == nil {
			t.Errorf("active or recent identity %q was removed", id)
		}
	}
	if rawGateForKey(r, "departed") != nil {
		t.Error("departed version/reset history was retained")
	}
	// The reconnect grace starts at disconnect, even if the live provider's
	// last version observation and outcome were older than the retention.
	r.Disconnect(live.ID)
	r.sweepGates(now.Add(time.Minute))
	if rawGateForKey(r, versionResetStable) == nil {
		t.Fatal("disconnect did not preserve the recent reconnect window")
	}
}

func TestVersionHistoryChurnDoesNotRetainDepartedVersionsForever(t *testing.T) {
	r := New(testLogger())
	now := time.Now()
	for minute := range 120 {
		at := now.Add(time.Duration(minute) * time.Minute)
		for i := range 100 {
			id := fmt.Sprintf("departed-%d-%d", minute, i)
			withGateForKey(r, id, func(g *gateState) {
				g.identityVersion = "0.9.1"
				g.touched = at
				g.versionResetAt = at
			})
		}
		r.sweepGates(at)
		if count := r.gateCount(); count > 2100 {
			t.Fatalf("version history grew past its retention window: %d", count)
		}
	}
	r.sweepGates(now.Add(3 * time.Hour))
	if r.gateCount() != 0 {
		t.Fatal("idle sweep did not release departed version metadata")
	}
}
