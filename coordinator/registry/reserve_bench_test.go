package registry

import (
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// reserveBenchMaxAllocs is the allocs/op ceiling asserted by
// TestReserveProviderExAllocBudget. Candidate arenas removed per-provider
// allocations; selection and soft preferences now need no temporary lists.
// Measured with Go 1.27.1 on darwin/arm64: 15 before, 13 after. Keep a small
// allowance for toolchain escape-analysis differences, not the obsolete 850
// allocation limit from before candidate arenas.
const reserveBenchMaxAllocs = 20

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
// Run with -benchmem; TestReserveProviderExAllocBudget guards heap allocations.
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

// Exercise all three soft preferences. The owner preference has no match and
// must keep the public pool; version and decode preferences keep that pool.
func BenchmarkReserveProviderExPreferences_350x2(b *testing.B) {
	reg := buildReserveBenchFleet(b)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		model, pr := reserveBenchRequest(i)
		pr.PreferOwner = true
		pr.OwnerAccountID = "bench-owner"
		pr.Traits.AvoidVersion = "not-in-fleet"
		pr.MinDecodeTPS = 1
		p, _ := reg.ReserveProviderEx(model, pr)
		if p == nil {
			b.Fatal("no provider selected")
		}
		p.RemovePending(pr.RequestID)
	}
}

// TestReserveProviderExAllocBudget guards the bounded allocation count of a
// warm-fleet reserve, including its routing diagnostics and reservation commit.
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
