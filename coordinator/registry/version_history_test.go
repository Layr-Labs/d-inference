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
	r.mu.Lock()
	r.identityVersionSeenAt[versionResetStable] = stale
	for _, id := range []string{"departed", "recent", "quarantined", "recent-reset", "fault-window"} {
		r.identityVersions[id] = "0.9.0"
		r.identityVersionSeenAt[id] = stale
	}
	r.identityVersionSeenAt["recent"] = now
	r.identityVersionResetAt = map[string]time.Time{"departed": stale, "recent-reset": now}
	r.providerBreakerOpenUntil["quarantined"] = now.Add(time.Minute)
	r.providerOutcomes["fault-window"] = &providerHealthWindow{}
	r.providerOutcomes["fault-window"].recordFault(now, false)
	r.identityVersionSweepAt = time.Time{}
	r.mu.Unlock()
	r.sweepIdentityVersionHistory(now)
	r.mu.RLock()
	for _, id := range []string{versionResetStable, "recent", "quarantined", "recent-reset", "fault-window"} {
		if _, kept := r.identityVersions[id]; !kept {
			t.Errorf("active or recent identity %q was removed", id)
		}
	}
	if _, kept := r.identityVersions["departed"]; kept || len(r.identityVersionResetAt) != 1 {
		t.Error("departed version/reset history was retained")
	}
	r.mu.RUnlock()
	// A long-lived session starts its reconnect grace when it disconnects,
	// not when it originally announced the version.
	r.Disconnect(live.ID)
	r.sweepIdentityVersionHistory(now.Add(identityVersionSweepInterval))
	r.mu.RLock()
	_, kept := r.identityVersions[versionResetStable]
	r.mu.RUnlock()
	if !kept {
		t.Fatal("disconnect did not preserve the recent reconnect window")
	}
}

func TestVersionHistoryChurnDoesNotRetainDepartedVersionsForever(t *testing.T) {
	r := New(testLogger())
	now := time.Now()
	r.mu.Lock()
	r.identityVersions = make(map[string]string)
	r.identityVersionResetAt = make(map[string]time.Time)
	for minute := range 120 {
		at := now.Add(time.Duration(minute) * time.Minute)
		for i := range 100 {
			id := fmt.Sprintf("departed-%d-%d", minute, i)
			r.identityVersions[id] = "0.9.1"
			r.identityVersionResetAt[id] = at
			r.touchIdentityVersionLocked(id, at)
		}
		r.pruneIdentityVersionsLocked(at)
		if len(r.identityVersions) > 2100 {
			t.Fatalf("version history grew past its retention window: %d", len(r.identityVersions))
		}
	}
	r.mu.Unlock()
	r.sweepIdentityVersionHistory(now.Add(3 * time.Hour))
	r.mu.RLock()
	defer r.mu.RUnlock()
	if len(r.identityVersions)+len(r.identityVersionSeenAt)+len(r.identityVersionResetAt) != 0 {
		t.Fatal("idle sweep did not release departed version metadata")
	}
}
