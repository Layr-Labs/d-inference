package registry

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestProviderServiceStatusReadyIsNotTraffic(t *testing.T) {
	r := New(testLogger())
	p := makeSchedulerProvider(t, r, "node", "service-model", 100)
	status := r.ProviderServiceStatus("", p.ID, time.Now())
	if status == nil || status.State != "ready" || status.PendingRequests != 0 || len(status.Models) != 1 || !status.Models[0].Eligible {
		t.Fatalf("status = %+v", status)
	}
	if p.PendingCount() != 0 {
		t.Fatal("status query reserved capacity")
	}
	if !status.ExpiresAt.After(status.ObservedAt) || status.Probe.Scope != "public_text" {
		t.Fatalf("scope/freshness missing: %+v", status)
	}
	if got := r.ProviderServiceStatus("another-account", p.ID, time.Now()); got != nil {
		t.Fatal("exposed another account's status")
	}
}

func TestProviderServiceStatusUsesRealFailureGates(t *testing.T) {
	r := New(testLogger())
	p := makeSchedulerProvider(t, r, "node", "service-a", 100)
	p.mu.Lock()
	p.Models = append(p.Models, protocol.ModelInfo{ID: "service-b"})
	p.mu.Unlock()
	for i := 0; i < 2; i++ {
		r.RecordInferenceError(p.ID, "service-a", 500, "base")
	}
	status := r.ProviderServiceStatus("", p.ID, time.Now())
	if status.State != "limited" || status.Models[0].Reason != "error_cooldown" || status.Models[0].Eligible || !status.Models[1].Eligible {
		t.Fatalf("per-model gates not represented: %+v", status)
	}
	if !r.InferenceErrorCooldownActive(p.ID, "service-a", "base") {
		t.Fatal("status cleared cooldown")
	}
	for i := 0; i < 5; i++ {
		r.RecordProviderOutcome(p.ID, false, 503, "internal error")
	}
	status = r.ProviderServiceStatus("", p.ID, time.Now())
	if status.State != "unavailable" || status.Models[1].Reason != "breaker" {
		t.Fatalf("node breaker absent: %+v", status)
	}
	if !r.ProviderBreakerOpen(p.ID) {
		t.Fatal("status consumed recovery")
	}
}

func TestProviderServiceStatusFreshnessAndBusy(t *testing.T) {
	r := New(testLogger())
	p := makeSchedulerProvider(t, r, "node", "service-model", 100)
	now := time.Now()
	p.mu.Lock()
	p.LastHeartbeat = now.Add(-89 * time.Second)
	p.mu.Unlock()
	status := r.ProviderServiceStatus("", p.ID, now)
	if status.ExpiresAt.Sub(now) != time.Second {
		t.Fatalf("freshness extends beyond heartbeat: %+v", status)
	}
	status = r.ProviderServiceStatus("", p.ID, now.Add(2*time.Second))
	if status.State != "unknown" || status.Reason != "heartbeat_stale" {
		t.Fatalf("stale provider appeared current: %+v", status)
	}
	p.mu.Lock()
	p.LastHeartbeat = now
	p.BackendCapacity.Slots[0].NumRunning = 100
	p.BackendCapacity.Slots[0].MaxConcurrency = 1
	p.mu.Unlock()
	status = r.ProviderServiceStatus("", p.ID, now)
	if status.State != "busy" || status.Reason != "no_headroom" {
		t.Fatalf("busy state=%+v", status)
	}
	r.MarkDraining(p.ID)
	status = r.ProviderServiceStatus("", p.ID, now)
	if status.State != "draining" {
		t.Fatalf("draining state=%+v", status)
	}
}
