package registry

// Fleet-scale benchmarks for the queue drain that runs on every heartbeat,
// SetProviderIdle, challenge success, and disconnect. The shape is the
// 2026-08-31 overload: 1,300 providers ALL advertising the saturated model
// (prod gpt-oss: ~1,000 advertisers) at token-budget capacity with a queue of
// identical waiters for it. Before the dominance skip
// (queue_drain_dominance.go) every event paid depth × one full fleet scan;
// after it an event pays one scan, and a heartbeat inside the 20 ms
// post-saturation window pays none (queue_drain_suppress.go).
//
// Depth 8 is the primary row (prod QUEUE_MAX_DEPTH=8); depth 32 is the stress
// case. The x3 variants give every provider three advertised models with a
// saturated queue on each, the multi-model prod box shape.
//
// Run: go test ./registry/ -run='^$' -bench=Drain_ -benchmem -count=5
// Deterministic gates (scan count, allocation ceiling) live in
// queue_drain_test.go; ns/op here is machine-dependent.

import (
	"fmt"
	"io"
	"log/slog"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

const (
	drainBenchFleetSize = 1300
	drainBenchPubKey    = "fX6XYH7p2hmM3ogeXaAsY+p8M6UKD1df/LJUN9Nj9Nw="
)

func drainBenchModel(m int) string {
	return fmt.Sprintf("mlx-community/drain-bench-model-%02d-4bit", m)
}
func drainBenchProviderID(i int) string { return fmt.Sprintf("drain-prov-%04d", i) }

// drainBenchSlot is a warm slot whose token budget is completely spent, so
// budget-based admission (freeMemoryAdmits) rejects every request.
func drainBenchSlot(model string) protocol.BackendSlotCapacity {
	return protocol.BackendSlotCapacity{
		Model: model, State: "running", NumRunning: 1, NumWaiting: 0,
		ActiveTokens: 2048, MaxTokensPotential: 4096,
		ActiveTokenBudgetUsed: 65536, ActiveTokenBudgetMax: 65536, QueuedTokenBudget: 0,
		ObservedDecodeTPS: 25, ObservedPrefillTPS: 800,
		KVBytesPerToken: 65536,
	}
}

func drainBenchModels(modelsPerProvider int) []string {
	out := make([]string, 0, modelsPerProvider)
	for m := 0; m < modelsPerProvider; m++ {
		out = append(out, drainBenchModel(m))
	}
	return out
}

func drainBenchCapacity(models []string) *protocol.BackendCapacity {
	slots := make([]protocol.BackendSlotCapacity, 0, len(models))
	for _, m := range models {
		slots = append(slots, drainBenchSlot(m))
	}
	return &protocol.BackendCapacity{TotalMemoryGB: 64, GPUMemoryActiveGB: 20, Slots: slots}
}

// buildDrainBenchFleet registers n routable, budget-saturated providers that
// all serve every one of modelsPerProvider models, plus a queue holding depth
// plain requests for each model. The TPS registry is seeded with a full
// 50-sample window per chip so Median() sorts a realistic window during each
// scan, as in prod.
func buildDrainBenchFleet(tb testing.TB, n, modelsPerProvider, depth int) *Registry {
	tb.Helper()
	logger := slog.New(slog.NewTextHandler(io.Discard, &slog.HandlerOptions{Level: slog.LevelError}))
	reg := New(logger)
	models := drainBenchModels(modelsPerProvider)
	catalog := make([]CatalogEntry, 0, len(models))
	infos := make([]protocol.ModelInfo, 0, len(models))
	for _, m := range models {
		catalog = append(catalog, CatalogEntry{ID: m, SizeGB: 15})
		infos = append(infos, protocol.ModelInfo{ID: m, SizeBytes: 15_000_000_000, ModelType: "chat", Quantization: "4bit"})
	}
	reg.SetModelCatalog(catalog)
	chips := []string{"M1", "M2", "M3", "M4"}
	now := time.Now()
	for i := 0; i < n; i++ {
		chip := chips[i%len(chips)]
		msg := &protocol.RegisterMessage{
			Type: protocol.TypeRegister,
			Hardware: protocol.Hardware{
				MachineModel: "Mac15,8", ChipName: "Apple " + chip + " Max", ChipFamily: chip, ChipTier: "Max",
				MemoryGB: 64, MemoryAvailableGB: 60, MemoryBandwidthGBs: 400,
				CPUCores: protocol.CPUCores{Total: 16, Performance: 12, Efficiency: 4}, GPUCores: 40,
			},
			Models:    infos,
			Backend:   BackendMLXSwift,
			DecodeTPS: 25 + float64(i%10),
			PublicKey: drainBenchPubKey, EncryptedResponseChunks: true, Version: "0.8.15",
			PrivacyCapabilities: &protocol.PrivacyCapabilities{
				TextBackendInprocess: true, TextProxyDisabled: true, PythonRuntimeLocked: true,
				DangerousModulesBlocked: true, SIPEnabled: true, AntiDebugEnabled: true,
				CoreDumpsDisabled: true, EnvScrubbed: true,
			},
		}
		p := reg.Register(drainBenchProviderID(i), nil, msg)
		p.mu.Lock()
		p.TrustLevel = TrustHardware
		p.RuntimeVerified = true
		p.RuntimeManifestChecked = true
		p.ChallengeVerifiedSIP = true
		p.LastChallengeVerified = now
		p.LastHeartbeat = now
		p.Version = "0.8.15"
		p.SystemMetrics = protocol.SystemMetrics{MemoryPressure: 0.3, CPUUsage: 0.2, ThermalState: "nominal"}
		p.BackendCapacity = drainBenchCapacity(models)
		p.WarmModels = append([]string(nil), models...)
		p.mu.Unlock()
	}
	for _, m := range models {
		for _, chip := range chips {
			for s := 0; s < 50; s++ {
				reg.tpsRegistry.Record(m, chip, 25+float64(s%10))
			}
		}
	}

	q := NewRequestQueue(depth*2, 120*time.Second)
	reg.SetQueue(q)
	for _, m := range models {
		for k := 0; k < depth; k++ {
			id := fmt.Sprintf("drain-q-%s-%d", m, k)
			req := &QueuedRequest{
				RequestID: id, Model: m, EnqueuedAt: now,
				Pending: &PendingRequest{
					RequestID: id, Model: m,
					EstimatedPromptTokens: 800, RequestedMaxTokens: 1024,
				},
			}
			if err := q.Enqueue(req); err != nil {
				tb.Fatal(err)
			}
		}
	}
	return reg
}

// drainBenchHeartbeat is a heartbeat that keeps every slot saturated.
func drainBenchHeartbeat(i int, models []string) *protocol.HeartbeatMessage {
	active := models[0]
	return &protocol.HeartbeatMessage{
		Type: protocol.TypeHeartbeat, Status: "serving", ActiveModel: &active,
		Stats:         protocol.HeartbeatStats{RequestsServed: int64(100 + i), TokensGenerated: int64(50000 + i)},
		WarmModels:    models,
		SystemMetrics: protocol.SystemMetrics{MemoryPressure: 0.35, CPUUsage: 0.22, ThermalState: "nominal"},
		BackendCapacity: &protocol.BackendCapacity{
			TotalMemoryGB: 64, GPUMemoryActiveGB: 21, GPUMemoryPeakGB: 30, GPUMemoryCacheGB: 2,
			Slots: drainBenchCapacity(models).Slots,
		},
	}
}

func requireDrainBenchQueueIntact(b *testing.B, reg *Registry, models []string, depth int) {
	b.Helper()
	for _, m := range models {
		if got := reg.Queue().QueueSize(m); got != depth {
			b.Fatalf("queue depth for %s = %d after benchmark, want %d (fleet was not saturated)", m, got, depth)
		}
	}
}

// TestDrainBenchFixtureSaturated pins the fixture: every waiter must be a pure
// capacity rejection against the whole fleet, or the benchmark measures an
// admitting drain instead of the saturated one.
func TestDrainBenchFixtureSaturated(t *testing.T) {
	reg := buildDrainBenchFleet(t, 200, 3, 4)
	for _, m := range drainBenchModels(3) {
		pr := &PendingRequest{RequestID: "probe-" + m, Model: m, EstimatedPromptTokens: 800, RequestedMaxTokens: 1024}
		p, decision := reg.ReserveProviderEx(m, pr)
		if p != nil {
			t.Fatalf("fixture admitted a request for %s on %s; want saturation", m, p.ID)
		}
		if decision.CandidateCount != 0 || decision.CapacityRejections == 0 {
			t.Fatalf("fixture rejection for %s is not pure capacity: %+v", m, decision)
		}
		if !drainPureCapacityRejection(decision) {
			t.Fatalf("fixture verdict for %s cannot anchor dominance: %+v", m, decision)
		}
	}
}

func benchDrainHeartbeat(b *testing.B, modelsPerProvider, depth int) {
	reg := buildDrainBenchFleet(b, drainBenchFleetSize, modelsPerProvider, depth)
	models := drainBenchModels(modelsPerProvider)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		reg.Heartbeat(drainBenchProviderID(i%drainBenchFleetSize), drainBenchHeartbeat(i, models))
	}
	b.StopTimer()
	requireDrainBenchQueueIntact(b, reg, models, depth)
}

func benchDrainSetProviderIdle(b *testing.B, modelsPerProvider, depth int) {
	benchDrainSetProviderIdleDominance(b, modelsPerProvider, depth, true)
}

func benchDrainSetProviderIdleDominance(b *testing.B, modelsPerProvider, depth int, dominance bool) {
	reg := buildDrainBenchFleet(b, drainBenchFleetSize, modelsPerProvider, depth)
	reg.drainDominanceDisabled = !dominance
	models := drainBenchModels(modelsPerProvider)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		reg.SetProviderIdle(drainBenchProviderID(i % drainBenchFleetSize))
	}
	b.StopTimer()
	requireDrainBenchQueueIntact(b, reg, models, depth)
}

// BenchmarkDrain_Heartbeat_* is the ~260/s fleet-wide event: a heartbeat from
// a provider serving the queued model while the whole fleet is at capacity.
// Consecutive iterations land inside the 20 ms suppression window, so this
// row measures the suppressed path plus one trailing pass per window; the
// SetProviderIdle rows isolate the unsuppressed per-pass cost.
func BenchmarkDrain_Heartbeat_1300x1_Depth8(b *testing.B)  { benchDrainHeartbeat(b, 1, 8) }
func BenchmarkDrain_Heartbeat_1300x1_Depth32(b *testing.B) { benchDrainHeartbeat(b, 1, 32) }
func BenchmarkDrain_Heartbeat_1300x3_Depth8(b *testing.B)  { benchDrainHeartbeat(b, 3, 8) }

// BenchmarkDrain_SetProviderIdle_* is the completion/cancel/failed-attempt
// event (15 call sites). Never suppressed, so this row is the per-pass cost
// of the drain itself.
func BenchmarkDrain_SetProviderIdle_1300x1_Depth8(b *testing.B)  { benchDrainSetProviderIdle(b, 1, 8) }
func BenchmarkDrain_SetProviderIdle_1300x1_Depth32(b *testing.B) { benchDrainSetProviderIdle(b, 1, 32) }
func BenchmarkDrain_SetProviderIdle_1300x3_Depth8(b *testing.B)  { benchDrainSetProviderIdle(b, 3, 8) }

// *_NoDominance rows are the pre-change cost on the same fixture (dominance
// skip disabled through the test-only toggle): depth × one scan per event.
func BenchmarkDrain_SetProviderIdle_1300x1_Depth8_NoDominance(b *testing.B) {
	benchDrainSetProviderIdleDominance(b, 1, 8, false)
}
func BenchmarkDrain_SetProviderIdle_1300x1_Depth32_NoDominance(b *testing.B) {
	benchDrainSetProviderIdleDominance(b, 1, 32, false)
}

// BenchmarkDrain_Disconnect_1300x1_Depth32: Disconnect re-runs the drain for
// the departed provider's models so a constrained waiter can fail fast; with
// plain waiters it can never admit anyone, so this is the pure per-pass cost
// (a fresh provider is registered outside the timer for each iteration).
func BenchmarkDrain_Disconnect_1300x1_Depth32(b *testing.B) {
	reg := buildDrainBenchFleet(b, drainBenchFleetSize, 1, 32)
	models := drainBenchModels(1)
	infos := []protocol.ModelInfo{{ID: models[0], ModelType: "chat", Quantization: "4bit"}}
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		b.StopTimer()
		id := fmt.Sprintf("drain-dc-%d", i)
		msg := testRegisterMessage()
		msg.Models = infos
		reg.Register(id, nil, msg)
		b.StartTimer()
		reg.Disconnect(id)
	}
	b.StopTimer()
	requireDrainBenchQueueIntact(b, reg, models, 32)
}

// BenchmarkDrain_ReserveProviderEx_1300 is the unit the drain used to multiply
// by queue depth: one saturated full-fleet scan on the same fixture.
func BenchmarkDrain_ReserveProviderEx_1300(b *testing.B) {
	reg := buildDrainBenchFleet(b, drainBenchFleetSize, 1, 0)
	model := drainBenchModel(0)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		pr := &PendingRequest{RequestID: "r", Model: model, EstimatedPromptTokens: 800, RequestedMaxTokens: 1024}
		if p, _ := reg.ReserveProviderEx(model, pr); p != nil {
			b.Fatal("expected saturation")
		}
	}
}
