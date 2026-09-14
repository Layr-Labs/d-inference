package registry

import (
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

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
