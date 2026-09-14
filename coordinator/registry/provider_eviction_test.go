package registry

import (
	"context"
	"testing"
	"time"
)

func TestEviction(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	p := reg.Register("p1", nil, msg)

	// Backdate the heartbeat.
	p.LastHeartbeat = time.Now().Add(-2 * time.Minute)

	// Eviction now requires two consecutive stale sweeps (grace against a
	// transient coordinator stall mass-reaping a live fleet). First sweep =
	// strike, second = evict.
	reg.evictStale(90 * time.Second)
	if reg.GetProvider("p1") == nil {
		t.Error("provider should survive the first stale sweep (grace)")
	}
	reg.evictStale(90 * time.Second)

	if reg.GetProvider("p1") != nil {
		t.Error("provider should have been evicted after two stale sweeps")
	}
	if reg.ProviderCount() != 0 {
		t.Errorf("count = %d, want 0", reg.ProviderCount())
	}
}

func TestEvictionKeepsFreshProviders(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	reg.Register("p1", nil, msg)

	// Fresh provider — should not be evicted.
	reg.evictStale(90 * time.Second)

	if reg.GetProvider("p1") == nil {
		t.Error("fresh provider should not be evicted")
	}
}

func TestEvictionLoopStopsOnCancel(t *testing.T) {
	reg := New(testLogger())
	ctx, cancel := context.WithCancel(context.Background())

	reg.StartEvictionLoop(ctx, 100*time.Millisecond)

	// Give the goroutine time to start.
	time.Sleep(50 * time.Millisecond)
	cancel()
	// Give the goroutine time to stop.
	time.Sleep(100 * time.Millisecond)
	// If we get here without hanging, the test passes.
}

// TestProviderEviction verifies that a provider with a stale heartbeat is
// fully evicted from the registry: GetProvider returns nil, ProviderCount
// goes to zero, and FindProvider no longer routes to it.
func TestProviderEviction(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	model := msg.Models[0].ID

	p := reg.Register("evict-me", nil, msg)
	p.TrustLevel = TrustHardware
	p.LastChallengeVerified = time.Now()
	p.ChallengeVerifiedSIP = true

	// Verify provider is present and routable before eviction.
	if reg.GetProvider("evict-me") == nil {
		t.Fatal("provider should exist before eviction")
	}
	if reg.ProviderCount() != 1 {
		t.Fatalf("provider count = %d, want 1", reg.ProviderCount())
	}
	found := findRoutableProvider(reg, model)
	if found == nil {
		t.Fatal("FindProvider should return provider before eviction")
	}
	reg.SetProviderIdle(found.ID)

	// Backdate heartbeat to 2 minutes ago and evict with 90s timeout. Eviction
	// takes two consecutive stale sweeps (grace); the second one reaps.
	p.LastHeartbeat = time.Now().Add(-2 * time.Minute)
	reg.evictStale(90 * time.Second)
	reg.evictStale(90 * time.Second)

	// Verify complete removal.
	if reg.GetProvider("evict-me") != nil {
		t.Error("GetProvider should return nil after eviction")
	}
	if reg.ProviderCount() != 0 {
		t.Errorf("ProviderCount = %d, want 0 after eviction", reg.ProviderCount())
	}
	if findRoutableProvider(reg, model) != nil {
		t.Error("FindProvider should return nil after eviction")
	}

	// Verify that listing models also shows nothing.
	models := reg.ListModels()
	if len(models) != 0 {
		t.Errorf("ListModels returned %d models, want 0 after eviction", len(models))
	}
}
