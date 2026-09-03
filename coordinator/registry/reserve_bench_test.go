package registry

import (
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// BASELINE (captured BEFORE the system-profiler routing-context changes, on
// this branch's parent commit b66ee3065, Apple M-series, go1.25):
//
//	BenchmarkReserveProviderEx_350x2-16  ~220-240 µs/op  209728 B/op  855 allocs/op  (3 runs, identical allocs)
//
// AFTER (same machine, routing context + fleet sampler landed):
//
//	BenchmarkReserveProviderEx_350x2-16  ~220-224 µs/op  209640 B/op  847 allocs/op  (3 runs, identical allocs)
//
// The 8 allocs/op removed are the slog key/value boxing in logRoutingDecision,
// which now checks Enabled(Debug) before the variadic call. The routing-context
// work (gate-reason tallies, top-4 candidate summaries, runner-up / best-idle /
// path, hbAgeMs, lock/scan/admit stamps) is REQUIRED to add ZERO heap
// allocations under r.mu per reserve. reserveBenchMaxAllocs below pins the
// pre-change baseline; TestReserveProviderExAllocBudget fails if allocs/op grows.

// reserveBenchMaxAllocs is the allocs/op ceiling asserted by
// TestReserveProviderExAllocBudget. Set to the measured pre-change baseline
// (see the header comment); a regression that adds a single heap allocation
// per reserve trips the test.
const reserveBenchMaxAllocs = 850 // re-pinned after the two-phase reserve (scan under RLock + short commit) landed on master

const (
	reserveBenchProviders = 350
	reserveBenchModelA    = "bench/model-a-4bit"
	reserveBenchModelB    = "bench/model-b-4bit"
)

// buildReserveBenchFleet registers 350 hardware-trusted providers that each
// serve two models with WARM ("running") slots. 20% of the fleet is derouted:
// every 10th provider has its node-health breaker tripped and every 10th+5
// provider has both of its (provider, model) pairs in capacity-reject cooldown,
// so the scan exercises the gate-rejection paths as well as the cost ranking.
func buildReserveBenchFleet(tb testing.TB) *Registry {
	tb.Helper()
	reg := New(testLogger())
	now := time.Now()
	for i := 0; i < reserveBenchProviders; i++ {
		id := fmt.Sprintf("bench-%04d", i)
		msg := testRegisterMessage()
		msg.Models = []protocol.ModelInfo{
			{ID: reserveBenchModelA, ModelType: "chat", Quantization: "4bit"},
			{ID: reserveBenchModelB, ModelType: "chat", Quantization: "4bit"},
		}
		msg.DecodeTPS = 40 + float64(i%17)
		p := reg.Register(id, nil, msg)
		p.mu.Lock()
		p.TrustLevel = TrustHardware
		p.RuntimeVerified = true
		p.RuntimeManifestChecked = true
		p.ChallengeVerifiedSIP = true
		p.LastChallengeVerified = now
		p.LastHeartbeat = now.Add(-time.Duration(i%30) * time.Second)
		p.SystemMetrics = protocol.SystemMetrics{MemoryPressure: 0.1, CPUUsage: 0.1, ThermalState: "nominal"}
		p.BackendCapacity = &protocol.BackendCapacity{
			TotalMemoryGB: 64,
			Slots: []protocol.BackendSlotCapacity{
				{Model: reserveBenchModelA, State: "running", NumRunning: i % 3, ObservedDecodeTPS: 30 + float64(i%11)},
				{Model: reserveBenchModelB, State: "running", NumRunning: (i + 1) % 3, ObservedDecodeTPS: 25 + float64(i%13)},
			},
		}
		p.mu.Unlock()
		switch i % 10 {
		case 0:
			for k := 0; k < providerBreakerConsecTrip; k++ {
				reg.RecordProviderOutcome(id, false, 500, "internal fault")
			}
		case 5:
			for k := 0; k < defaultCapacityCooldownThreshold; k++ {
				reg.RecordCapacityReject(id, reserveBenchModelA)
				reg.RecordCapacityReject(id, reserveBenchModelB)
			}
		}
	}
	return reg
}

func reserveBenchRequest(i int) (string, *PendingRequest) {
	model := reserveBenchModelA
	if i%2 == 1 {
		model = reserveBenchModelB
	}
	return model, &PendingRequest{
		RequestID:             "bench-req",
		Model:                 model,
		EstimatedPromptTokens: 500,
		RequestedMaxTokens:    256,
	}
}

// BenchmarkReserveProviderEx_350x2 measures one ReserveProviderEx call (plus
// the RemovePending that releases the reservation) against a 350-provider,
// two-model warm fleet with 20% of providers derouted by breaker/cooldown.
// Run with -benchmem; allocs/op must not grow versus the header baseline.
func BenchmarkReserveProviderEx_350x2(b *testing.B) {
	reg := buildReserveBenchFleet(b)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		model, pr := reserveBenchRequest(i)
		p, _ := reg.ReserveProviderEx(model, pr)
		if p == nil {
			b.Fatal("no provider selected")
		}
		p.RemovePending(pr.RequestID)
	}
}

// TestReserveProviderExAllocBudget asserts that a warm-fleet reserve does not
// allocate more than the pre-change baseline (reserveBenchMaxAllocs).
func TestReserveProviderExAllocBudget(t *testing.T) {
	if testing.Short() {
		t.Skip("alloc budget check skipped in -short mode")
	}
	reg := buildReserveBenchFleet(t)
	// Warm up once so lazily-initialized state does not count.
	model, pr := reserveBenchRequest(0)
	if p, _ := reg.ReserveProviderEx(model, pr); p != nil {
		p.RemovePending(pr.RequestID)
	}
	const rounds = 200
	allocs := testing.AllocsPerRun(rounds, func() {
		model, pr := reserveBenchRequest(1)
		p, _ := reg.ReserveProviderEx(model, pr)
		if p != nil {
			p.RemovePending(pr.RequestID)
		}
	})
	if reserveBenchMaxAllocs > 0 && allocs > float64(reserveBenchMaxAllocs) {
		t.Fatalf("ReserveProviderEx allocs/op = %.1f, exceeds baseline %d", allocs, reserveBenchMaxAllocs)
	}
	t.Logf("ReserveProviderEx allocs/op = %.1f (baseline ceiling %d)", allocs, reserveBenchMaxAllocs)
}
