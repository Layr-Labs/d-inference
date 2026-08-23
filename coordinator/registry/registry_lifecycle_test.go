package registry

import (
	"context"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestDisconnect(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	reg.Register("p1", nil, msg)

	reg.Disconnect("p1")

	if reg.GetProvider("p1") != nil {
		t.Error("provider should be nil after disconnect")
	}
	if reg.ProviderCount() != 0 {
		t.Errorf("count = %d, want 0", reg.ProviderCount())
	}
}

func TestDisconnectUnknown(t *testing.T) {
	reg := New(testLogger())
	// Should not panic.
	reg.Disconnect("nonexistent")
}

func TestSetProviderIdle(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	p1 := reg.Register("p1", nil, msg)
	p1.TrustLevel = TrustHardware
	p1.LastChallengeVerified = time.Now()
	p1.ChallengeVerifiedSIP = true

	// Put the provider in the serving state, then verify SetProviderIdle clears it.
	p := reg.GetProvider("p1")
	p.mu.Lock()
	p.Status = StatusServing
	p.mu.Unlock()
	if p.Status != StatusServing {
		t.Errorf("status = %q, want %q", p.Status, StatusServing)
	}

	reg.SetProviderIdle("p1")
	if p.Status != StatusOnline {
		t.Errorf("status = %q, want %q after idle", p.Status, StatusOnline)
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

// TestDisconnectDuplicatesBySerial: providers sharing the kept connection's
// serial must be removed (the path now relies on Disconnect for teardown).
func TestDisconnectDuplicatesBySerial(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()

	const serial = "SERIAL-DUP-1"
	keep := reg.Register("keep", nil, msg)
	keep.AttestationResult = &attestation.VerificationResult{SerialNumber: serial}
	dupA := reg.Register("dupA", nil, msg)
	dupA.AttestationResult = &attestation.VerificationResult{SerialNumber: serial}
	dupB := reg.Register("dupB", nil, msg)
	dupB.AttestationResult = &attestation.VerificationResult{SerialNumber: serial}
	// A provider from a different device must be left untouched.
	other := reg.Register("other", nil, msg)
	other.AttestationResult = &attestation.VerificationResult{SerialNumber: "SERIAL-OTHER"}

	reg.DisconnectDuplicatesBySerial("keep", serial)

	if reg.GetProvider("keep") == nil {
		t.Error("kept provider should remain registered")
	}
	if reg.GetProvider("other") == nil {
		t.Error("provider with a different serial should not be evicted")
	}
	if reg.GetProvider("dupA") != nil {
		t.Error("duplicate dupA should have been disconnected")
	}
	if reg.GetProvider("dupB") != nil {
		t.Error("duplicate dupB should have been disconnected")
	}
	if reg.ProviderCount() != 2 {
		t.Errorf("provider count = %d, want 2 (keep + other)", reg.ProviderCount())
	}
}

func TestEvictionLoopStopsOnCancel(t *testing.T) {
	reg := New(testLogger())
	ctx, cancel := context.WithCancel(context.Background())
	ticks := make(chan time.Time)
	stopped := make(chan struct{})

	go func() {
		defer close(stopped)
		reg.runEvictionLoop(ctx, 90*time.Second, ticks)
	}()
	cancel()

	select {
	case <-stopped:
	case <-time.After(time.Second):
		t.Fatal("eviction loop did not stop after cancellation")
	}
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

	// Backdate heartbeat to 2 minutes ago. The first stale sweep records a
	// strike but keeps the provider; the second consecutive sweep evicts it.
	p.LastHeartbeat = time.Now().Add(-2 * time.Minute)
	reg.evictStale(90 * time.Second)
	if reg.GetProvider("evict-me") == nil {
		t.Fatal("provider should survive the first stale sweep")
	}
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

// TestConcurrentFindProviderAndHeartbeat is a stress test that exercises
// concurrent registry operations to verify correctness under load. Goroutine 1
// drives the production routing path (ReserveProviderEx, via findRoutableProvider)
// alternating with Heartbeat; the remaining goroutines run reputation updates,
// provider reads, and registry reads fully concurrently. Routing and Heartbeat
// both take r.mu and the provider mutex, so the test passes under -race.
func TestConcurrentFindProviderAndHeartbeat(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	model := msg.Models[0].ID

	// Register 5 providers with different stats.
	for i := range 5 {
		id := fmt.Sprintf("provider-%d", i)
		p := reg.Register(id, nil, msg)
		p.DecodeTPS = float64(50 + i*25)
		p.TrustLevel = TrustHardware
		p.LastChallengeVerified = time.Now()
		p.ChallengeVerifiedSIP = true
		p.SystemMetrics = protocol.SystemMetrics{
			MemoryPressure: float64(i) * 0.1,
			CPUUsage:       float64(i) * 0.05,
			ThermalState:   "nominal",
		}
	}

	var wg sync.WaitGroup

	// Goroutine 1: alternate production routing (ReserveProviderEx) and Heartbeat.
	wg.Add(1)
	go func() {
		defer wg.Done()
		thermalStates := []string{"nominal", "fair", "serious", "nominal"}
		for i := range 100 {
			// Phase A: route a request then release the provider.
			p := findRoutableProvider(reg, model)
			if p != nil {
				reg.SetProviderIdle(p.ID)
			}

			// Phase B: Send heartbeat with varying metrics
			id := fmt.Sprintf("provider-%d", i%5)
			hb := &protocol.HeartbeatMessage{
				Type:   protocol.TypeHeartbeat,
				Status: "idle",
				Stats:  protocol.HeartbeatStats{RequestsServed: int64(i)},
				SystemMetrics: protocol.SystemMetrics{
					MemoryPressure: float64(i%10) * 0.1,
					CPUUsage:       float64(i%8) * 0.1,
					ThermalState:   thermalStates[i%len(thermalStates)],
				},
				WarmModels: []string{model},
			}
			reg.Heartbeat(id, hb)
		}
	}()

	// Goroutine 2: Record job success/failure (modifies Reputation).
	// RecordJobSuccess/Failure holds r.mu.RLock then p.mu.Lock — same
	// lock order as Heartbeat.
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := range 100 {
			id := fmt.Sprintf("provider-%d", i%5)
			if i%3 == 0 {
				reg.RecordJobFailure(id)
			} else {
				reg.RecordJobSuccess(id, time.Duration(i)*time.Millisecond)
			}
		}
	}()

	// Goroutine 3: Read provider fields under the provider mutex.
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := range 100 {
			id := fmt.Sprintf("provider-%d", i%5)
			p := reg.GetProvider(id)
			if p != nil {
				p.Mu().Lock()
				_ = p.SystemMetrics.MemoryPressure
				_ = p.SystemMetrics.CPUUsage
				_ = p.SystemMetrics.ThermalState
				_ = p.DecodeTPS
				_ = p.TrustLevel
				_ = p.Status
				_ = len(p.WarmModels)
				_ = p.CurrentModel
				p.Mu().Unlock()
			}
		}
	}()

	// Goroutine 4: ProviderCount + ForEachProvider (read-only registry access).
	wg.Add(1)
	go func() {
		defer wg.Done()
		for range 100 {
			_ = reg.ProviderCount()
			reg.ForEachProvider(func(p *Provider) {
				_ = p.PendingCount()
			})
		}
	}()

	// Goroutine 5: ProviderIDs + GetProvider (registry read operations).
	wg.Add(1)
	go func() {
		defer wg.Done()
		for range 100 {
			ids := reg.ProviderIDs()
			for _, id := range ids {
				_ = reg.GetProvider(id)
			}
		}
	}()

	wg.Wait()

	// If we reach here without a data race, the test passes.
	// Verify the registry is still consistent.
	if reg.ProviderCount() != 5 {
		t.Errorf("provider count = %d, want 5 after concurrent operations", reg.ProviderCount())
	}
}

// TestRemoveProviderBySerialRaceWithAttestation guards the DAR-291 delete path:
// RemoveProviderBySerial matches a live machine by its attested serial, reading
// AttestationResult while holding only the registry lock. Since attestation
// completion writes that pointer under the provider mutex (SetAttestationResult),
// the read must go through the thread-safe accessor or it data-races. Run under
// -race; it fails (DATA RACE) without the GetAttestationResult() fix.
func TestRemoveProviderBySerialRaceWithAttestation(t *testing.T) {
	reg := New(testLogger())
	p := reg.Register("p-race", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: "m", ModelType: "chat"}},
	})
	const serial = "SER-RACE"

	var wg sync.WaitGroup
	for i := 0; i < 200; i++ {
		wg.Add(2)
		go func() {
			defer wg.Done()
			p.SetAttestationResult(&attestation.VerificationResult{SerialNumber: serial})
		}()
		go func() {
			defer wg.Done()
			reg.RemoveProviderBySerial(serial, false)
		}()
	}
	wg.Wait()
}

func TestEvictionStrikeResetsAfterRecovery(t *testing.T) {
	reg := New(testLogger())
	p := reg.Register("recovering", nil, testRegisterMessage())
	p.LastHeartbeat = time.Now().Add(-2 * time.Minute)

	reg.evictStale(90 * time.Second)
	if reg.GetProvider(p.ID) == nil {
		t.Fatal("provider should survive its first stale sweep")
	}

	p.LastHeartbeat = time.Now()
	reg.evictStale(90 * time.Second)

	p.LastHeartbeat = time.Now().Add(-2 * time.Minute)
	reg.evictStale(90 * time.Second)
	if reg.GetProvider(p.ID) == nil {
		t.Fatal("a recovered provider should receive a fresh first-strike grace")
	}
	reg.evictStale(90 * time.Second)
	if reg.GetProvider(p.ID) != nil {
		t.Fatal("provider should be evicted after two new consecutive stale sweeps")
	}
}

func TestDurationStats(t *testing.T) {
	input := []time.Duration{4 * time.Second, time.Second, 3 * time.Second, 2 * time.Second}
	min, median, p90, max := durationStats(input)
	if min != time.Second || median != 3*time.Second || p90 != 4*time.Second || max != 4*time.Second {
		t.Fatalf("durationStats = (%v, %v, %v, %v), want (1s, 3s, 4s, 4s)", min, median, p90, max)
	}
	if input[0] != 4*time.Second || input[1] != time.Second {
		t.Fatalf("durationStats mutated its input: %v", input)
	}

	min, median, p90, max = durationStats(nil)
	if min != 0 || median != 0 || p90 != 0 || max != 0 {
		t.Fatalf("durationStats(nil) = (%v, %v, %v, %v), want all zero", min, median, p90, max)
	}
}
