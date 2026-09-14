package registry

import (
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func firstContentCapacityHeartbeat(p *Provider, sequence uint64) *protocol.HeartbeatMessage {
	capacity := p.BackendCapacitySnapshot()
	capacity.CapacitySeq = sequence
	model := capacity.Slots[0].Model
	return &protocol.HeartbeatMessage{Status: "idle", ActiveModel: &model,
		SystemMetrics: protocol.SystemMetrics{ThermalState: "nominal"}, BackendCapacity: capacity}
}

func TestFirstContentFreshnessRejectsReplayedCapacity(t *testing.T) {
	r := New(testLogger())
	if err := r.ConfigureFirstContentRouting(FirstContentRoutingPrefer); err != nil {
		t.Fatal(err)
	}
	cheap := firstContentTestProvider(t, r, "old-capacity", 4_000, 1_800)
	fresh := firstContentTestProvider(t, r, "fresh-capacity", 500, 1_800)
	heartbeat := firstContentCapacityHeartbeat(cheap, 2)
	if !r.Heartbeat(cheap.ID, heartbeat) {
		t.Fatal("initial capacity rejected")
	}
	// Positive control: this is the ordinary winner and is feasible while its
	// accepted report is fresh. There is no extra request work after removal.
	request := firstContentTestRequest()
	winner, _ := r.ReserveProviderEx(request.Model, request)
	if winner != cheap {
		t.Fatal("fixture did not prefer the cheap fresh provider")
	}
	winner.RemovePending(request.RequestID)

	old := time.Now().Add(-6 * time.Second)
	cheap.mu.Lock()
	cheap.LastHeartbeat, cheap.capacitySamplesAt = old, old
	cheap.mu.Unlock()
	for _, sequence := range []uint64{1, 2, 1, 2} {
		heartbeat.BackendCapacity.CapacitySeq = sequence
		if r.Heartbeat(cheap.ID, heartbeat) {
			t.Fatal("stale or duplicate capacity sequence accepted")
		}
	}
	cheap.mu.Lock()
	live, accepted := cheap.LastHeartbeat, cheap.capacitySamplesAt
	cheap.mu.Unlock()
	if !live.After(old) || !accepted.Equal(old) {
		t.Fatal("liveness and accepted-capacity clocks were not kept separate")
	}
	request = firstContentTestRequest()
	winner, _ = r.ReserveProviderEx(request.Model, request)
	if winner != fresh {
		t.Fatal("replayed heartbeat freshened obsolete idle/rate evidence")
	}
	winner.RemovePending(request.RequestID)

	// A newer accepted report really does renew feasibility.
	heartbeat.BackendCapacity.CapacitySeq = 3
	if !r.Heartbeat(cheap.ID, heartbeat) {
		t.Fatal("new capacity report rejected")
	}
	request = firstContentTestRequest()
	winner, decision := r.ReserveProviderEx(request.Model, request)
	if winner != cheap || decision.FirstContent.CapacityAgeMs > 5_000 || decision.FirstContent.Status != "feasible" {
		t.Fatalf("new accepted report did not restore feasibility: %+v", decision.FirstContent)
	}
}

func TestFirstContentFreshnessRevalidatedAtCommit(t *testing.T) {
	forEachCommitMode(t, func(t *testing.T, mode reserveCommitMode) {
		r := New(testLogger())
		setReserveCommitModeForTest(r, mode)
		if err := r.ConfigureFirstContentRouting(FirstContentRoutingPrefer); err != nil {
			t.Fatal(err)
		}
		aged := firstContentTestProvider(t, r, "aged-during-scan", 4_000, 1_800)
		fresh := firstContentTestProvider(t, r, "still-fresh", 500, 1_800)
		var once sync.Once
		r.reservationAfterScan = func(string) {
			once.Do(func() {
				aged.mu.Lock()
				aged.capacitySamplesAt = time.Now().Add(-6 * time.Second)
				// Simulate a liveness-only update after the captured scan.
				aged.LastHeartbeat = time.Now()
				aged.mu.Unlock()
			})
		}
		request := firstContentTestRequest()
		winner, decision := r.ReserveProviderEx(request.Model, request)
		if winner != fresh || decision.ScanCount < 2 || pendingCountOf(aged) != 0 {
			t.Fatalf("commit did not reconsider stale capacity: winner=%v scans=%d", winner, decision.ScanCount)
		}
	})
}

func TestFirstContentFreshnessClearsAndRenewsWithAcceptedCapacity(t *testing.T) {
	r := New(testLogger())
	if err := r.ConfigureFirstContentRouting(FirstContentRoutingShadow); err != nil {
		t.Fatal(err)
	}
	p := firstContentTestProvider(t, r, "capacity-lifecycle", 4_000, 1_800)
	legacy := firstContentCapacityHeartbeat(p, 0)
	p.mu.Lock()
	p.capacitySamplesAt = time.Time{}
	p.mu.Unlock()
	request := firstContentTestRequest()
	winner, decision := r.ReserveProviderEx(request.Model, request)
	if winner != p || decision.FirstContent.Status != "unknown" || decision.FirstContent.Reason != "stale" {
		t.Fatalf("missing acceptance clock fabricated fresh capacity: %+v", decision.FirstContent)
	}
	winner.RemovePending(request.RequestID)
	if !r.Heartbeat(p.ID, legacy) {
		t.Fatal("legacy accepted report rejected")
	}
	request = firstContentTestRequest()
	winner, decision = r.ReserveProviderEx(request.Model, request)
	if winner != p || decision.FirstContent.Status != "feasible" {
		t.Fatalf("legacy accepted report did not renew capacity: %+v", decision.FirstContent)
	}
	winner.RemovePending(request.RequestID)
	if !r.Heartbeat(p.ID, &protocol.HeartbeatMessage{}) {
		t.Fatal("nil capacity heartbeat rejected")
	}
	p.mu.Lock()
	cleared := p.BackendCapacity == nil && p.capacitySamplesAt.IsZero()
	p.mu.Unlock()
	if !cleared {
		t.Fatal("nil capacity retained its accepted snapshot clock")
	}
	r.Disconnect(p.ID)
	replacement := r.Register(p.ID, nil, testRegisterMessage())
	if replacement == p || !replacement.capacitySamplesAt.IsZero() {
		t.Fatal("reconnected provider inherited old capacity freshness")
	}
}
