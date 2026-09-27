package registry

import (
	"errors"
	"testing"
	"time"
)

func TestLifecycleDrainFencesHeldReservationUntilDisconnect(t *testing.T) {
	r := New(testLogger())
	p := registerDrainStateProvider(t, r, "lifecycle", 100)
	pr := drainStateRequest("reserved-before-drain")
	if r.ReserveProvider(drainStateTestModel, pr) != p {
		t.Fatal("reservation failed")
	}
	if r.CommitProviderDrain(p, "stop") == 0 {
		t.Fatal("drain not committed")
	}
	// A delayed pre-drain idle heartbeat and a missed heartbeat TTL cannot
	// resurrect a process whose operator has explicitly stopped admission.
	r.Heartbeat(p.ID, drainStateHeartbeat("idle"))
	p.mu.Lock()
	p.drainingUntil = time.Now().Add(-time.Hour)
	w := p.writer
	p.mu.Unlock()
	if !r.ProviderDraining(p.ID) {
		t.Fatal("lifecycle drain expired")
	}
	if err := r.authorizeInferenceHandoff(p, pr, w); !errors.Is(err, ErrProviderDraining) {
		t.Fatalf("reserved frame crossed drain boundary: %v", err)
	}
	if got := r.ReserveProvider(drainStateTestModel, drainStateRequest("late")); got != nil {
		t.Fatal("new request routed")
	}
	if err := r.SendLoadModel(p.ID, drainStateTestModel); err == nil {
		t.Fatal("load command crossed drain")
	}
	if err := r.SendPrefetchModel(p.ID, drainStateTestModel, 1); err == nil {
		t.Fatal("prefetch crossed drain")
	}
	r.mu.RLock()
	_, eligible := r.modelLoadCandidatePendingLocked(p, drainStateTestModel, time.Now())
	r.mu.RUnlock()
	if eligible {
		t.Fatal("cold load planner selected draining provider")
	}
	r.Disconnect(p.ID)
	if r.CommitProviderDrain(p, "stale") != 0 {
		t.Fatal("stale connection committed a drain")
	}
	registerDrainStateProvider(t, r, p.ID, 100)
	if r.ProviderDraining(p.ID) {
		t.Fatal("drain leaked onto new connection")
	}
}
