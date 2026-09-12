package registry

// Fleet-scale benchmarks for the queue drain that runs on every heartbeat,
// SetProviderIdle, challenge success, and disconnect. The shape is the
// 2026-08-31 overload: a 1,300-provider fleet at token-budget capacity with a
// full (32-deep) queue for one model. Before the dominance skip in
// drainQueuedRequests every event paid depth × one full fleet scan
// (~37 ms / 36 MB / 333K allocs); after it an event pays one scan.
//
// Run: go test ./registry/ -run='^$' -bench=Drain -benchmem -count=3

import (
	"fmt"
	"io"
	"log/slog"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

const (
	drainBenchFleetSize  = 1300
	drainBenchQueueDepth = 32
	drainBenchModel      = "mlx-community/drain-bench-model-4bit"
	drainBenchPubKey     = "fX6XYH7p2hmM3ogeXaAsY+p8M6UKD1df/LJUN9Nj9Nw="
)

func drainBenchProviderID(i int) string { return fmt.Sprintf("drain-prov-%04d", i) }

// drainBenchSlot is a warm slot whose token budget is completely spent, so
// budget-based admission (freeMemoryAdmits) rejects every request.
func drainBenchSlot() protocol.BackendSlotCapacity {
	return protocol.BackendSlotCapacity{
		Model: drainBenchModel, State: "running", NumRunning: 1, NumWaiting: 0,
		ActiveTokens: 2048, MaxTokensPotential: 4096,
		ActiveTokenBudgetUsed: 65536, ActiveTokenBudgetMax: 65536, QueuedTokenBudget: 0,
		ObservedDecodeTPS: 25, ObservedPrefillTPS: 800,
		KVBytesPerToken: 65536,
	}
}

// buildDrainBenchFleet registers n routable, budget-saturated providers that
// all serve drainBenchModel, plus a queue holding depth plain requests for it.
// The TPS registry is seeded with a full 50-sample window per chip so Median()
// sorts a realistic window during each scan, as in prod.
func buildDrainBenchFleet(b testing.TB, n, depth int) *Registry {
	b.Helper()
	logger := slog.New(slog.NewTextHandler(io.Discard, &slog.HandlerOptions{Level: slog.LevelError}))
	reg := New(logger)
	reg.SetModelCatalog([]CatalogEntry{{ID: drainBenchModel, SizeGB: 15}})
	chips := []string{"M1", "M2", "M3", "M4"}
	for i := 0; i < n; i++ {
		chip := chips[i%len(chips)]
		msg := &protocol.RegisterMessage{
			Type: protocol.TypeRegister,
			Hardware: protocol.Hardware{
				MachineModel: "Mac15,8", ChipName: "Apple " + chip + " Max", ChipFamily: chip, ChipTier: "Max",
				MemoryGB: 64, MemoryAvailableGB: 60, MemoryBandwidthGBs: 400,
				CPUCores: protocol.CPUCores{Total: 16, Performance: 12, Efficiency: 4}, GPUCores: 40,
			},
			Models: []protocol.ModelInfo{{
				ID: drainBenchModel, SizeBytes: 15_000_000_000, ModelType: "chat", Quantization: "4bit",
			}},
			Backend: BackendMLXSwift, DecodeTPS: 25 + float64(i%10),
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
		p.LastChallengeVerified = time.Now()
		p.Version = "0.8.15"
		p.SystemMetrics = protocol.SystemMetrics{MemoryPressure: 0.3, CPUUsage: 0.2, ThermalState: "nominal"}
		p.BackendCapacity = &protocol.BackendCapacity{
			TotalMemoryGB: 64, GPUMemoryActiveGB: 20,
			Slots: []protocol.BackendSlotCapacity{drainBenchSlot()},
		}
		p.WarmModels = []string{drainBenchModel}
		p.mu.Unlock()
	}
	for _, chip := range chips {
		for s := 0; s < 50; s++ {
			reg.tpsRegistry.Record(drainBenchModel, chip, 25+float64(s%10))
		}
	}

	q := NewRequestQueue(depth*2, 120*time.Second)
	reg.SetQueue(q)
	for k := 0; k < depth; k++ {
		id := fmt.Sprintf("drain-q-%d", k)
		req := &QueuedRequest{
			RequestID: id, Model: drainBenchModel, EnqueuedAt: time.Now(),
			Pending: &PendingRequest{
				RequestID: id, Model: drainBenchModel,
				EstimatedPromptTokens: 800, RequestedMaxTokens: 1024,
			},
		}
		if err := q.Enqueue(req); err != nil {
			b.Fatal(err)
		}
	}
	return reg
}

// drainBenchHeartbeat is a heartbeat that keeps the provider's slot saturated.
func drainBenchHeartbeat(i int) *protocol.HeartbeatMessage {
	active := drainBenchModel
	return &protocol.HeartbeatMessage{
		Type: protocol.TypeHeartbeat, Status: "serving", ActiveModel: &active,
		Stats:         protocol.HeartbeatStats{RequestsServed: int64(100 + i), TokensGenerated: int64(50000 + i)},
		WarmModels:    []string{drainBenchModel},
		SystemMetrics: protocol.SystemMetrics{MemoryPressure: 0.35, CPUUsage: 0.22, ThermalState: "nominal"},
		BackendCapacity: &protocol.BackendCapacity{
			TotalMemoryGB: 64, GPUMemoryActiveGB: 21, GPUMemoryPeakGB: 30, GPUMemoryCacheGB: 2,
			Slots: []protocol.BackendSlotCapacity{drainBenchSlot()},
		},
	}
}

func requireDrainBenchQueueIntact(b *testing.B, reg *Registry) {
	b.Helper()
	if got := reg.Queue().QueueSize(drainBenchModel); got != drainBenchQueueDepth {
		b.Fatalf("queue depth = %d after benchmark, want %d (fleet was not saturated)", got, drainBenchQueueDepth)
	}
}

// BenchmarkDrain_Heartbeat_1300_SaturatedQueue_Depth32 is the 260/s fleet-wide
// event: a heartbeat from a provider serving the queued model while the whole
// fleet is at capacity.
func BenchmarkDrain_Heartbeat_1300_SaturatedQueue_Depth32(b *testing.B) {
	reg := buildDrainBenchFleet(b, drainBenchFleetSize, drainBenchQueueDepth)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		reg.Heartbeat(drainBenchProviderID(i%drainBenchFleetSize), drainBenchHeartbeat(i))
	}
	b.StopTimer()
	requireDrainBenchQueueIntact(b, reg)
}

// BenchmarkDrain_SetProviderIdle_1300_SaturatedQueue_Depth32 is the
// completion/cancel/failed-attempt event (16 call sites). Never suppressed,
// so this row isolates the per-pass cost of the drain itself.
func BenchmarkDrain_SetProviderIdle_1300_SaturatedQueue_Depth32(b *testing.B) {
	reg := buildDrainBenchFleet(b, drainBenchFleetSize, drainBenchQueueDepth)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		reg.SetProviderIdle(drainBenchProviderID(i % drainBenchFleetSize))
	}
	b.StopTimer()
	requireDrainBenchQueueIntact(b, reg)
}
