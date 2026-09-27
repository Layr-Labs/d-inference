package registry

// Fleet-scale benchmarks for the periodic and aggregate paths: everything that
// walks the whole fleet OUTSIDE the routing scan (metrics gauges, the public
// /v1/models and /v1/stats aggregations, the eviction sweep, the warm-pool
// planning tick, the per-heartbeat model-swap planner) plus the per-heartbeat
// BackendCapacitySnapshot deep copy. Same 1,260-provider fixture as
// fleet_scale_bench_test.go so the two families are directly comparable:
//
//	go test ./registry/ -run '^$' -bench 'FleetAgg|FleetTick|BackendCapacitySnapshot' -benchmem

import (
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// BenchmarkFleetAggSnapshot is the /metrics FleetSnapshot gauge summary.
func BenchmarkFleetAggSnapshot(b *testing.B) {
	f := buildBenchFleet(b, benchFleetProviders, benchFleetModels)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if f.reg.Snapshot().Connected == 0 {
			b.Fatal("empty snapshot")
		}
	}
}

// BenchmarkFleetAggPublicProviderModels is the capability-filtered per-provider
// model view behind /v1/stats and /v1/providers/attestation.
func BenchmarkFleetAggPublicProviderModels(b *testing.B) {
	f := buildBenchFleet(b, benchFleetProviders, benchFleetModels)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if len(f.reg.PublicProviderModels()) == 0 {
			b.Fatal("no providers")
		}
	}
}

// BenchmarkFleetAggListProviders is the base-rewards settlement snapshot.
func BenchmarkFleetAggListProviders(b *testing.B) {
	f := buildBenchFleet(b, benchFleetProviders, benchFleetModels)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if len(f.reg.ListProviders()) == 0 {
			b.Fatal("no providers")
		}
	}
}

// BenchmarkFleetAggRoutableProviderIDsForBuild is the rollout-progress gate.
func BenchmarkFleetAggRoutableProviderIDsForBuild(b *testing.B) {
	f := buildBenchFleet(b, benchFleetProviders, benchFleetModels)
	model := f.models[0]
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if len(f.reg.RoutableProviderIDsForBuild(model)) == 0 {
			b.Fatal("no routable providers")
		}
	}
}

// BenchmarkFleetAggOwnedModels is the self-route /v1/models view for one
// account owning a handful of boxes inside a large public fleet.
func BenchmarkFleetAggOwnedModels(b *testing.B) {
	f := buildBenchFleet(b, benchFleetProviders, benchFleetModels)
	const account = "acct-bench"
	for i, id := range f.ids {
		if i%100 != 0 {
			continue
		}
		p := f.reg.GetProvider(id)
		p.mu.Lock()
		p.AccountID = account
		p.mu.Unlock()
	}
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if len(f.reg.OwnedModels(account)) == 0 {
			b.Fatal("no owned models")
		}
	}
}

// BenchmarkFleetAggCodeAttestationCoverage is the 15s DD gauge + /v1/stats count.
func BenchmarkFleetAggCodeAttestationCoverage(b *testing.B) {
	f := buildBenchFleet(b, benchFleetProviders, benchFleetModels)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, online := f.reg.CodeAttestationCoverage(); online == 0 {
			b.Fatal("no online providers")
		}
	}
}

// BenchmarkFleetAggCountProvidersWithCurrentApplicationEvidence is the
// release-policy shadow-mode acceptance counter (/v1/stats).
func BenchmarkFleetAggCountProvidersWithCurrentApplicationEvidence(b *testing.B) {
	f := buildBenchFleet(b, benchFleetProviders, benchFleetModels)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, connected := f.reg.CountProvidersWithCurrentApplicationEvidence(); connected == 0 {
			b.Fatal("no connected providers")
		}
	}
}

// BenchmarkFleetAggApplicationEvidenceModelCoverage is the per-model
// release-policy coverage table (/v1/stats).
func BenchmarkFleetAggApplicationEvidenceModelCoverage(b *testing.B) {
	f := buildBenchFleet(b, benchFleetProviders, benchFleetModels)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if len(f.reg.ApplicationEvidenceModelCoverage()) == 0 {
			b.Fatal("no coverage rows")
		}
	}
}

// BenchmarkFleetTickEvictStale is the eviction sweep (every timeout/3) in its
// steady state: every provider fresh, nothing to evict. The timeout is far
// larger than any benchmark run so the fixture never ages into a strike.
func BenchmarkFleetTickEvictStale(b *testing.B) {
	f := buildBenchFleet(b, benchFleetProviders, benchFleetModels)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		f.reg.evictStale(24 * time.Hour)
	}
	b.StopTimer()
	if f.reg.ProviderCount() != benchFleetProviders {
		b.Fatalf("fleet shrank to %d during a no-evict sweep", f.reg.ProviderCount())
	}
}

// BenchmarkFleetTickEvictStaleStriking is the sweep with a third of the fleet
// stale on its FIRST strike each time (the strike map is reset between
// iterations so nothing is ever reaped). This is the write path: strikes are
// carried across sweeps.
func BenchmarkFleetTickEvictStaleStriking(b *testing.B) {
	f := buildBenchFleet(b, benchFleetProviders, benchFleetModels)
	stale := time.Now().Add(-48 * time.Hour)
	for i, id := range f.ids {
		if i%3 != 0 {
			continue
		}
		p := f.reg.GetProvider(id)
		p.mu.Lock()
		p.LastHeartbeat = stale
		p.mu.Unlock()
	}
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		f.reg.evictStale(24 * time.Hour)
		b.StopTimer()
		f.reg.mu.Lock()
		f.reg.evictStrikes = make(map[string]int)
		f.reg.mu.Unlock()
		b.StartTimer()
	}
	b.StopTimer()
	if f.reg.ProviderCount() != benchFleetProviders {
		b.Fatalf("fleet shrank to %d during a first-strike sweep", f.reg.ProviderCount())
	}
}

// BenchmarkFleetTickWarmPoolFleetSnapshot is the fleet walk inside every
// warm-pool controller tick (30s + hot-path triggers).
func BenchmarkFleetTickWarmPoolFleetSnapshot(b *testing.B) {
	f := buildBenchFleet(b, benchFleetProviders, benchFleetModels)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if len(f.reg.warmPoolFleetSnapshot(time.Now())) == 0 {
			b.Fatal("no models")
		}
	}
}

// BenchmarkFleetTickWarmPoolPlanObserveOnly is one full observe-only planning
// pass (fleet snapshot + Little's Law targets), invoked without the controller
// goroutine.
func BenchmarkFleetTickWarmPoolPlanObserveOnly(b *testing.B) {
	f := buildBenchFleet(b, benchFleetProviders, benchFleetModels)
	c := newWarmPoolController(f.reg, WarmPoolConfig{
		Enabled:                    true,
		ObserveOnly:                true,
		Interval:                   30 * time.Second,
		DecodeFloorTPS:             12,
		FallbackQualityConcurrency: 4,
		AssumedPromptTokens:        800,
		AssumedCompletionTokens:    400,
	})
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if len(c.planObserveOnly(time.Now(), nil)) == 0 {
			b.Fatal("no snapshots")
		}
	}
}

// BenchmarkFleetTickTriggerModelSwapsWarmQueued is the per-heartbeat swap
// planner while a request is queued for a model that IS warm somewhere: the
// planner walks providers until it finds the first warm one.
func BenchmarkFleetTickTriggerModelSwapsWarmQueued(b *testing.B) {
	f := buildBenchFleet(b, benchFleetProviders, benchFleetModels)
	f.reg.loadModelSender = func(string, string) error { return nil }
	if err := f.reg.Queue().Enqueue(&QueuedRequest{RequestID: "bench-queued-warm", Model: f.models[0]}); err != nil {
		b.Fatal(err)
	}
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		f.reg.TriggerModelSwaps()
	}
}

// BenchmarkFleetTickTriggerModelSwapsUnservableQueued is the planner's worst
// case, reached on EVERY heartbeat while a request is queued for a catalog
// model no connected provider can serve: both the warm scan and the
// cold-candidate scan walk the entire fleet and find nothing.
func BenchmarkFleetTickTriggerModelSwapsUnservableQueued(b *testing.B) {
	f := buildBenchFleet(b, benchFleetProviders, benchFleetModels)
	f.reg.loadModelSender = func(string, string) error { return nil }
	catalog := make([]CatalogEntry, 0, benchFleetModels+1)
	for m := 0; m < benchFleetModels; m++ {
		catalog = append(catalog, CatalogEntry{ID: benchFleetModelID(m), SizeGB: 16 + float64(m), MinRAMGB: 32})
	}
	unservable := benchFleetModelID(benchFleetModels)
	catalog = append(catalog, CatalogEntry{ID: unservable, SizeGB: 40, MinRAMGB: 32})
	f.reg.SetModelCatalog(catalog)
	if err := f.reg.Queue().Enqueue(&QueuedRequest{RequestID: "bench-queued-cold", Model: unservable}); err != nil {
		b.Fatal(err)
	}
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		f.reg.TriggerModelSwaps()
	}
}

// benchThreeSlotHeartbeat is a realistic current-provider heartbeat: three
// resident slots, paged KV backend on each, and MLX cache reclaimer telemetry.
func benchThreeSlotHeartbeat(models []string) *protocol.HeartbeatMessage {
	slots := make([]protocol.BackendSlotCapacity, 0, 3)
	for i, m := range models[:3] {
		kv := "paged"
		slots = append(slots, protocol.BackendSlotCapacity{
			Model:                 m,
			State:                 "running",
			NumRunning:            i,
			MaxConcurrency:        8,
			ActiveTokens:          int64(i) * 900,
			MaxTokensPotential:    int64(i) * 1400,
			ObservedDecodeTPS:     20 + float64(i),
			ObservedPrefillTPS:    900,
			ActiveTokenBudgetUsed: int64(i) * 1400,
			ActiveTokenBudgetMax:  120000,
			KVBytesPerToken:       98304,
			KVBackend:             &kv,
			StepsExecuted:         int64(1000 + i),
			Admits:                int64(50 + i),
			FirstTokensEmitted:    int64(50 + i),
		})
	}
	active := models[0]
	free := 30.0
	return &protocol.HeartbeatMessage{
		Type:        protocol.TypeHeartbeat,
		Status:      "idle",
		ActiveModel: &active,
		WarmModels:  models[:3],
		BackendCapacity: &protocol.BackendCapacity{
			Slots:             slots,
			GPUMemoryActiveGB: 48,
			GPUMemoryPeakGB:   52,
			GPUMemoryCacheGB:  3,
			TotalMemoryGB:     128,
			FreeForLoadGB:     &free,
			MLXCacheReclaimer: &protocol.MLXCacheReclaimerTelemetry{
				CacheLimitBytes:       8 << 30,
				SweepSignals:          120,
				Reclaims:              12,
				ReclaimedBytes:        3 << 30,
				LastReclaimedBytes:    256 << 20,
				LastReclaimDurationMS: 14,
			},
		},
	}
}

// benchRegisterThreeSlotProvider registers one provider advertising three
// catalog models with the three-slot heartbeat applied.
func benchRegisterThreeSlotProvider(tb testing.TB, reg *Registry, id string, models []string) *Provider {
	tb.Helper()
	infos := make([]protocol.ModelInfo, 0, 3)
	for _, m := range models[:3] {
		infos = append(infos, protocol.ModelInfo{ID: m, ModelType: "chat", Quantization: "4bit"})
	}
	msg := &protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipFamily: "M3", ChipTier: "Max", MemoryGB: 128},
		Models:                  infos,
		Backend:                 BackendMLXSwift,
		Version:                 "0.8.15",
		PublicKey:               benchFleetPublicKey,
		EncryptedResponseChunks: true,
	}
	p := reg.Register(id, nil, msg)
	makeProviderRoutable(p)
	reg.Heartbeat(id, benchThreeSlotHeartbeat(models))
	return p
}

// BenchmarkBackendCapacitySnapshot is the per-heartbeat detached copy the API
// heartbeat branch takes for telemetry (three slots, KV backend pointers,
// reclaimer telemetry present).
func BenchmarkBackendCapacitySnapshot(b *testing.B) {
	f := buildBenchFleet(b, 8, benchFleetModels)
	p := benchRegisterThreeSlotProvider(b, f.reg, fmt.Sprintf("bench-%04d", benchFleetProviders), f.models)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if snap := p.BackendCapacitySnapshot(); snap == nil || len(snap.Slots) != 3 {
			b.Fatal("unexpected snapshot")
		}
	}
}

// benchQueueColdAdvertised extends the fleet with one more catalog model that
// a handful of extra providers advertise but hold in a crashed slot (so it is
// neither warm nor reservable anywhere), queues one request for it, and
// returns one of those providers plus a heartbeat that keeps the slot crashed.
// This is the congestion shape: a request waits for a model the fleet
// advertises but cannot currently serve.
func benchQueueColdAdvertised(b *testing.B, f *benchFleet, extra int) (providerID string, hb *protocol.HeartbeatMessage, cold string) {
	b.Helper()
	f.reg.loadModelSender = func(string, string) error { return nil }
	catalog := make([]CatalogEntry, 0, benchFleetModels+1)
	for m := 0; m < benchFleetModels; m++ {
		catalog = append(catalog, CatalogEntry{ID: benchFleetModelID(m), SizeGB: 16 + float64(m), MinRAMGB: 32})
	}
	cold = benchFleetModelID(benchFleetModels)
	catalog = append(catalog, CatalogEntry{ID: cold, SizeGB: 40, MinRAMGB: 32})
	f.reg.SetModelCatalog(catalog)

	crashedHeartbeat := func() *protocol.HeartbeatMessage {
		active := cold
		return &protocol.HeartbeatMessage{
			Type:        protocol.TypeHeartbeat,
			Status:      "idle",
			ActiveModel: &active,
			BackendCapacity: &protocol.BackendCapacity{
				Slots:         []protocol.BackendSlotCapacity{{Model: cold, State: "crashed"}},
				TotalMemoryGB: 128,
			},
		}
	}
	for i := 0; i < extra; i++ {
		id := fmt.Sprintf("bench-cold-%03d", i)
		if providerID == "" {
			providerID = id
		}
		msg := &protocol.RegisterMessage{
			Type:                    protocol.TypeRegister,
			Hardware:                protocol.Hardware{ChipFamily: "M3", ChipTier: "Max", MemoryGB: 128},
			Models:                  []protocol.ModelInfo{{ID: cold, ModelType: "chat", Quantization: "4bit"}},
			Backend:                 BackendMLXSwift,
			Version:                 "0.8.15",
			PublicKey:               benchFleetPublicKey,
			EncryptedResponseChunks: true,
		}
		p := f.reg.Register(id, nil, msg)
		makeProviderRoutable(p)
		f.reg.Heartbeat(id, crashedHeartbeat())
	}
	if err := f.reg.Queue().Enqueue(&QueuedRequest{RequestID: "bench-queued-cold-advertised", Model: cold}); err != nil {
		b.Fatal(err)
	}
	return providerID, crashedHeartbeat(), cold
}

// BenchmarkFleetTickHeartbeatQueuedColdAdvertised is the FULL registry
// heartbeat ingest while a request is queued for a model the heartbeating
// provider advertises but cannot serve: every such heartbeat pops the request,
// runs a reservation scan across the fleet, requeues it, and then runs the
// model-swap planner (registry.go: drainQueuedRequestsForModels +
// TriggerModelSwaps at the tail of Heartbeat). Compare with
// BenchmarkFleetHeartbeat (~0.5 µs) for the same ingest with an empty queue.
func BenchmarkFleetTickHeartbeatQueuedColdAdvertised(b *testing.B) {
	f := buildBenchFleet(b, benchFleetProviders, benchFleetModels)
	providerID, hb, cold := benchQueueColdAdvertised(b, f, 12)
	requeues := 0
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		f.reg.Heartbeat(providerID, hb)
		if f.reg.Queue().QueueSize(cold) == 0 {
			// The drain terminally failed or assigned the request; put a fresh
			// one back so every iteration measures the congested shape.
			b.StopTimer()
			requeues++
			if err := f.reg.Queue().Enqueue(&QueuedRequest{RequestID: fmt.Sprintf("bench-queued-cold-advertised-%d", i), Model: cold}); err != nil {
				b.Fatal(err)
			}
			b.StartTimer()
		}
	}
	b.ReportMetric(float64(requeues)/float64(b.N), "requeues/op")
}
