package registry_test

import (
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/identitygate"
)

func TestVersionHistoryRetentionKeepsLiveRecentAndQuarantinedIdentities(t *testing.T) {
	now := time.Now()
	stale := now.Add(-20*time.Minute - time.Minute)
	r, gates, clock := newVersionGateRegistry(stale)
	live := bindVersionedSession(t, r, "live-history", "0.9.0", false)
	identities := []string{versionResetStable, "departed", "recent", "quarantined", "recent-reset", "fault-window"}
	for _, id := range identities {
		if id == versionResetStable {
			continue
		}
		clock.set(stale)
		session := gates.Attach(id + "-history")
		version := "0.9.0"
		if id == "departed" || id == "recent-reset" {
			version = "0.8.9"
		}
		gates.Bind(session, id, version)
		if version != "0.9.0" {
			if id == "recent-reset" {
				clock.set(now)
			}
			gates.ObserveVersion(session, "0.9.0")
		}
		gates.Detach(session, id)
	}

	quarantined := gates.ResolveIdentity("quarantined")
	// The third backoff lasts four minutes. Its fault is three minutes old,
	// leaving exactly one minute of quarantine but no live two-minute ring.
	clock.set(now.Add(-6*time.Minute - 2*time.Second))
	for range identitygate.ProviderBreakerConsecTrip {
		gates.RecordProviderOutcomeRef(quarantined, false, 500, "internal error")
	}
	clock.set(now.Add(-5*time.Minute - time.Second))
	gates.RecordProviderOutcomeRef(quarantined, false, 500, "internal error")
	clock.set(now.Add(-3 * time.Minute))
	gates.RecordProviderOutcomeRef(quarantined, false, 500, "internal error")
	if health := gates.ViewReference(quarantined).BreakerHealth(now); health.Samples != 0 || !health.RetryAfter.Equal(now.Add(time.Minute)) {
		t.Fatalf("quarantine fixture must have no live fault window and exactly one minute left: %+v", health)
	}
	clock.set(now)
	gates.RecordProviderOutcomeRef(gates.ResolveIdentity("fault-window"), false, 500, "internal error")
	if health := gates.ViewIdentity("fault-window").BreakerHealth(now); health.Samples != 1 || !health.RetryAfter.IsZero() {
		t.Fatalf("fault-window fixture must retain one fault without quarantine: %+v", health)
	}

	// A health-neutral shed dates activity without altering version/fault
	// evidence. Replaying its timestamp preserves the original independent
	// stale-activity/fresh-reset and stale-activity/fresh-ring conditions.
	for _, id := range identities {
		clock.set(stale)
		if id == "recent" {
			clock.set(now)
		}
		gates.RecordProviderOutcomeRef(gates.ResolveIdentity(id), false, 429, "busy")
	}
	clock.set(now)
	gates.Sweep(now)
	for _, id := range []string{versionResetStable, "recent", "quarantined", "recent-reset", "fault-window"} {
		if !gates.ViewIdentity(id).Present() {
			t.Errorf("active or recent identity %q was removed", id)
		}
	}
	if gates.ViewIdentity("departed").Present() {
		t.Error("departed version/reset history was retained")
	}
	// The reconnect grace starts at disconnect even when version/outcome
	// activity has already aged out of the retention horizon.
	r.Disconnect(live.ID)
	gates.Sweep(now.Add(time.Minute))
	if !gates.ViewIdentity(versionResetStable).Present() {
		t.Fatal("disconnect did not preserve the recent reconnect window")
	}
}

func TestVersionHistoryChurnDoesNotRetainDepartedVersionsForever(t *testing.T) {
	now := time.Now()
	_, gates, clock := newVersionGateRegistry(now)
	for minute := range 120 {
		at := now.Add(time.Duration(minute) * time.Minute)
		clock.set(at)
		for i := range 100 {
			id := fmt.Sprintf("departed-%d-%d", minute, i)
			session := gates.Attach(id + "-session")
			gates.Bind(session, id, "0.9.0")
			gates.ObserveVersion(session, "0.9.1")
			gates.Detach(session, id)
		}
		if count := gates.Sweep(at); count > 2100 {
			t.Fatalf("version history grew past its retention window: %d", count)
		}
	}
	if gates.Sweep(now.Add(3*time.Hour)) != 0 {
		t.Fatal("idle sweep did not release departed version metadata")
	}
}
