package registry_test

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"
	"github.com/eigeninference/d-inference/coordinator/protocol"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func BenchmarkFleetTickEvictStale(b *testing.B) {
	var lifecycle *production.ConnectionLifecycle
	f := buildBenchFleet(b, benchFleetProviders, benchFleetModels, production.Dependencies{
		ConnectionLifecycle: func(l *production.ConnectionLifecycle) production.ConnectionMaintenance {
			lifecycle = l
			return l
		},
	})
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		lifecycle.Sweep(24 * time.Hour)
	}
	b.StopTimer()
	if f.reg.ProviderCount() != benchFleetProviders {
		b.Fatalf("fleet shrank to %d during a no-evict sweep", f.reg.ProviderCount())
	}
}

func BenchmarkFleetTickEvictStaleStriking(b *testing.B) {
	var lifecycle *production.ConnectionLifecycle
	f := buildBenchFleet(b, benchFleetProviders, benchFleetModels, production.Dependencies{
		ConnectionLifecycle: func(l *production.ConnectionLifecycle) production.ConnectionMaintenance {
			lifecycle = l
			return l
		},
	})
	stale := time.Now().Add(-48 * time.Hour)
	for i, id := range f.ids {
		if i%3 != 0 {
			continue
		}
		p := f.reg.GetProvider(id)
		p.Mu().Lock()
		p.LastHeartbeat = stale
		p.Mu().Unlock()
	}
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		lifecycle.Sweep(24 * time.Hour)
		b.StopTimer()
		// A healthy sweep clears the first strikes without changing the fleet.
		// Only the original 24-hour stale sweep is timed.
		lifecycle.Sweep(72 * time.Hour)
		b.StartTimer()
	}
	b.StopTimer()
	if f.reg.ProviderCount() != benchFleetProviders {
		b.Fatalf("fleet shrank to %d during a first-strike sweep", f.reg.ProviderCount())
	}
}

func BenchmarkFleetTickWarmPoolFleetSnapshot(b *testing.B) {
	var fleet func(time.Time) map[string]warmplan.Fleet
	f := buildBenchFleet(b, benchFleetProviders, benchFleetModels, production.Dependencies{
		WarmPlanning: func(deps warmplan.Dependencies[production.ModelLoadAction]) *warmplan.Controller[production.ModelLoadAction] {
			fleet = deps.Fleet
			return warmplan.NewController(deps)
		},
	})
	// Match the unconfigured registry's fleet quality fallback exactly.
	f.reg.ConfigureWarmPool(warmplan.Config{FallbackQualityConcurrency: 1})
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if len(fleet(time.Now())) == 0 {
			b.Fatal("no models")
		}
	}
}

func BenchmarkFleetTickWarmPoolPlanObserveOnly(b *testing.B) {
	var planning warmplan.Dependencies[production.ModelLoadAction]
	f := buildBenchFleet(b, benchFleetProviders, benchFleetModels, production.Dependencies{
		WarmPlanning: func(deps warmplan.Dependencies[production.ModelLoadAction]) *warmplan.Controller[production.ModelLoadAction] {
			planning = deps
			return warmplan.NewController(deps)
		},
	})
	// The original standalone controller did not change registry fleet policy.
	f.reg.ConfigureWarmPool(warmplan.Config{FallbackQualityConcurrency: 1})
	planning.Config = warmplan.Config{
		Enabled: true, ObserveOnly: true, Interval: 30 * time.Second,
		DecodeFloorTPS: 12, FallbackQualityConcurrency: 4,
		AssumedPromptTokens: 800, AssumedCompletionTokens: 400,
	}
	c := warmplan.NewController(planning)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if len(c.PlanObserveOnly(time.Now(), nil)) == 0 {
			b.Fatal("no snapshots")
		}
	}
}

type benchModelCommandTransport struct{}

func (benchModelCommandTransport) WriteText(context.Context, []byte) error { return nil }

func benchModelCommands(string, production.ModelCommandTransport) production.ModelCommandTransport {
	return benchModelCommandTransport{}
}

func BenchmarkFleetTickTriggerModelSwapsWarmQueued(b *testing.B) {
	f := buildBenchFleet(b, benchFleetProviders, benchFleetModels, production.Dependencies{ModelCommands: benchModelCommands})
	if err := f.reg.Queue().Enqueue(&production.QueuedRequest{RequestID: "bench-queued-warm", Model: f.models[0]}); err != nil {
		b.Fatal(err)
	}
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		f.reg.TriggerModelSwaps()
	}
}

func BenchmarkFleetTickTriggerModelSwapsUnservableQueued(b *testing.B) {
	f := buildBenchFleet(b, benchFleetProviders, benchFleetModels, production.Dependencies{ModelCommands: benchModelCommands})
	catalog := make([]production.CatalogEntry, 0, benchFleetModels+1)
	for m := 0; m < benchFleetModels; m++ {
		catalog = append(catalog, production.CatalogEntry{ID: benchFleetModelID(m), SizeGB: 16 + float64(m), MinRAMGB: 32})
	}
	unservable := benchFleetModelID(benchFleetModels)
	catalog = append(catalog, production.CatalogEntry{ID: unservable, SizeGB: 40, MinRAMGB: 32})
	f.reg.SetModelCatalog(catalog)
	if err := f.reg.Queue().Enqueue(&production.QueuedRequest{RequestID: "bench-queued-cold", Model: unservable}); err != nil {
		b.Fatal(err)
	}
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		f.reg.TriggerModelSwaps()
	}
}

func benchQueueColdAdvertised(b *testing.B, f *benchFleet, extra int) (providerID string, hb *protocol.HeartbeatMessage, cold string) {
	b.Helper()
	catalog := make([]production.CatalogEntry, 0, benchFleetModels+1)
	for m := 0; m < benchFleetModels; m++ {
		catalog = append(catalog, production.CatalogEntry{ID: benchFleetModelID(m), SizeGB: 16 + float64(m), MinRAMGB: 32})
	}
	cold = benchFleetModelID(benchFleetModels)
	catalog = append(catalog, production.CatalogEntry{ID: cold, SizeGB: 40, MinRAMGB: 32})
	f.reg.SetModelCatalog(catalog)

	crashedHeartbeat := func() *protocol.HeartbeatMessage {
		active := cold
		return &protocol.HeartbeatMessage{
			Type: protocol.TypeHeartbeat, Status: "idle", ActiveModel: &active,
			BackendCapacity: &protocol.BackendCapacity{
				Slots: []protocol.BackendSlotCapacity{{Model: cold, State: "crashed"}}, TotalMemoryGB: 128,
			},
		}
	}
	for i := 0; i < extra; i++ {
		id := fmt.Sprintf("bench-cold-%03d", i)
		if providerID == "" {
			providerID = id
		}
		msg := &protocol.RegisterMessage{
			Type:     protocol.TypeRegister,
			Hardware: protocol.Hardware{ChipFamily: "M3", ChipTier: "Max", MemoryGB: 128},
			Models:   []protocol.ModelInfo{{ID: cold, ModelType: "chat", Quantization: "4bit"}},
			Backend:  production.BackendMLXSwift, Version: "0.8.15",
			PublicKey: benchFleetPublicKey, EncryptedResponseChunks: true,
		}
		p := f.reg.Register(id, nil, msg)
		makeProviderRoutable(p)
		f.reg.Heartbeat(id, crashedHeartbeat())
	}
	if err := f.reg.Queue().Enqueue(&production.QueuedRequest{RequestID: "bench-queued-cold-advertised", Model: cold}); err != nil {
		b.Fatal(err)
	}
	return providerID, crashedHeartbeat(), cold
}

func BenchmarkFleetTickHeartbeatQueuedColdAdvertised(b *testing.B) {
	f := buildBenchFleet(b, benchFleetProviders, benchFleetModels, production.Dependencies{ModelCommands: benchModelCommands})
	providerID, hb, cold := benchQueueColdAdvertised(b, f, 12)
	requeues := 0
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		f.reg.Heartbeat(providerID, hb)
		if f.reg.Queue().QueueSize(cold) == 0 {
			b.StopTimer()
			requeues++
			if err := f.reg.Queue().Enqueue(&production.QueuedRequest{RequestID: fmt.Sprintf("bench-queued-cold-advertised-%d", i), Model: cold}); err != nil {
				b.Fatal(err)
			}
			b.StartTimer()
		}
	}
	b.ReportMetric(float64(requeues)/float64(b.N), "requeues/op")
}

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
		p.Mu().Lock()
		p.AccountID = account
		p.Mu().Unlock()
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
func benchRegisterThreeSlotProvider(tb testing.TB, reg *production.Registry, id string, models []string) *production.Provider {
	tb.Helper()
	infos := make([]protocol.ModelInfo, 0, 3)
	for _, m := range models[:3] {
		infos = append(infos, protocol.ModelInfo{ID: m, ModelType: "chat", Quantization: "4bit"})
	}
	msg := &protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipFamily: "M3", ChipTier: "Max", MemoryGB: 128},
		Models:                  infos,
		Backend:                 production.BackendMLXSwift,
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
