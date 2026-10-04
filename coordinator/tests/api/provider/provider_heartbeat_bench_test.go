package provider_test

// Component benchmarks for post-decode heartbeat ingestion and telemetry, plus
// the production trust rearm check as an explicit separate dependency. These do
// not exercise provider owner construction or WebSocket dispatch. The registered
// provider carries a realistic three-slot BackendCapacity with MLX cache
// reclaimer telemetry — the shape every current provider reports.
//
//	go test ./tests/api/provider/ -run '^$' -bench 'HeartbeatBranch' -benchmem

import (
	"context"
	"io"
	"log/slog"
	"net"
	"testing"

	"github.com/DataDog/datadog-go/v5/statsd"
	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/api/provider/trust"
	"github.com/eigeninference/d-inference/coordinator/datadog"
	"github.com/eigeninference/d-inference/coordinator/internal/provider/heartbeat"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

const benchHeartbeatProviderID = "bench-heartbeat-provider"

var benchHeartbeatModels = []string{
	"mlx-community/bench-model-00-4bit",
	"mlx-community/bench-model-01-4bit",
	"mlx-community/bench-model-02-4bit",
}

func benchHeartbeatFixture(tb testing.TB) (*heartbeatFixture, *trust.Owner, *registry.Provider) {
	tb.Helper()
	logger := slog.New(slog.NewTextHandler(io.Discard, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	reg.SetStore(st)
	obs := observation.New(observation.Dependencies{Registry: reg, Store: st, Logger: logger})
	tb.Cleanup(obs.Close)
	fixture := &heartbeatFixture{registry: reg, observation: obs, ingestor: heartbeat.New(reg, obs)}
	// Keep the real trust rearm check in the timed workload, without wrapping
	// either component in a provider owner facade.
	trustOwner := trust.New(trust.Dependencies{Registry: reg, Store: st, Observation: obs, Logger: logger}, trust.Config{})
	trustOwner.Start()
	tb.Cleanup(trustOwner.Close)

	infos := make([]protocol.ModelInfo, 0, len(benchHeartbeatModels))
	for _, m := range benchHeartbeatModels {
		infos = append(infos, protocol.ModelInfo{ID: m, ModelType: "chat", Quantization: "4bit"})
	}
	p := reg.Register(benchHeartbeatProviderID, nil, &protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipFamily: "M3", ChipTier: "Max", MemoryGB: 128},
		Models:                  infos,
		Backend:                 registry.BackendMLXSwift,
		Version:                 "0.8.15",
		PublicKey:               "fX6XYH7p2hmM3ogeXaAsY+p8M6UKD1df/LJUN9Nj9Nw=",
		EncryptedResponseChunks: true,
	})
	reg.Heartbeat(benchHeartbeatProviderID, benchHeartbeatMessage())
	return fixture, trustOwner, p
}

// benchHeartbeatMessage is a baseline (non-event) heartbeat: no prefix-cache
// fields, three resident slots with engine-health counters, reclaimer stats.
func benchHeartbeatMessage() *protocol.HeartbeatMessage {
	slots := make([]protocol.BackendSlotCapacity, 0, 3)
	for i, m := range benchHeartbeatModels {
		kv := "paged"
		slots = append(slots, protocol.BackendSlotCapacity{
			Model:                 m,
			State:                 "running",
			NumRunning:            i,
			MaxConcurrency:        8,
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
	active := benchHeartbeatModels[0]
	free := 30.0
	return &protocol.HeartbeatMessage{
		Type:        protocol.TypeHeartbeat,
		Status:      "idle",
		ActiveModel: &active,
		WarmModels:  benchHeartbeatModels,
		SystemMetrics: protocol.SystemMetrics{
			MemoryPressure: 0.3,
			CPUUsage:       0.2,
			ThermalState:   "nominal",
		},
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

// benchLocalStatsd wires a real DogStatsD client at a throwaway local UDP
// socket so the benchmark pays the real client-side cost instead of the
// nil-client no-op. datadog-go v5 aggregates gauges client-side, so what the
// timed loop pays per call is the aggregator insert (metric/tag context key +
// map update); formatting and the UDP write happen on the client's flush
// goroutine. Nothing reads the socket; UDP just drops the datagrams.
func benchLocalStatsd(tb testing.TB) *datadog.Client {
	tb.Helper()
	conn, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		tb.Fatalf("listen udp: %v", err)
	}
	tb.Cleanup(func() { _ = conn.Close() })
	sd, err := statsd.New(conn.LocalAddr().String(), statsd.WithNamespace("bench."))
	if err != nil {
		tb.Fatalf("statsd client: %v", err)
	}
	tb.Cleanup(func() { _ = sd.Close() })
	return &datadog.Client{Statsd: sd}
}

// runHeartbeatBranch measures the production ingestor and separate trust check
// for a baseline heartbeat (no prefix-cache fields).
func runHeartbeatBranch(ctx context.Context, ingestor *heartbeat.Ingestor, trustOwner *trust.Owner, providerID string, provider *registry.Provider, hb *protocol.HeartbeatMessage) {
	ingestor.Apply(providerID, provider, hb)
	trustOwner.MaybeRearmCodeAttest(ctx, providerID, provider, hb)
}

// runHeartbeatTail isolates the capacity snapshot, wedge/MLX telemetry and
// separate trust check. prev is the pre-ingest capacity snapshot the MLX
// telemetry diffs its reclaimer counters against.
func runHeartbeatTail(ctx context.Context, ingestor *heartbeat.Ingestor, trustOwner *trust.Owner, providerID string, provider *registry.Provider, prev *protocol.BackendCapacity, hb *protocol.HeartbeatMessage) {
	capacity := provider.BackendCapacitySnapshot()
	ingestor.RecordBackendWedgeTelemetry(capacity)
	ingestor.RecordMLXCacheTelemetry(provider, prev, capacity)
	trustOwner.MaybeRearmCodeAttest(ctx, providerID, provider, hb)
}

// BenchmarkHeartbeatBranchNoDD is the whole branch with Datadog unconfigured
// (metric calls are no-ops): registry ingest + snapshot + telemetry extraction.
func BenchmarkHeartbeatBranchNoDD(b *testing.B) {
	s, trustOwner, p := benchHeartbeatFixture(b)
	hb := benchHeartbeatMessage()
	ctx := context.Background()
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		runHeartbeatBranch(ctx, s.ingestor, trustOwner, benchHeartbeatProviderID, p, hb)
	}
}

// BenchmarkHeartbeatBranchStatsd is the same branch with a real DogStatsD
// client attached, so the nine per-heartbeat gauge emissions are paid.
func BenchmarkHeartbeatBranchStatsd(b *testing.B) {
	s, trustOwner, p := benchHeartbeatFixture(b)
	s.observation.SetDatadog(benchLocalStatsd(b))
	hb := benchHeartbeatMessage()
	ctx := context.Background()
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		runHeartbeatBranch(ctx, s.ingestor, trustOwner, benchHeartbeatProviderID, p, hb)
	}
}

// BenchmarkHeartbeatBranchTelemetryOnly isolates the API-side tail (snapshot
// + wedge + MLX cache telemetry + code-attest re-arm check) from the registry
// ingest, with Datadog unconfigured.
func BenchmarkHeartbeatBranchTelemetryOnly(b *testing.B) {
	s, trustOwner, p := benchHeartbeatFixture(b)
	hb := benchHeartbeatMessage()
	ctx := context.Background()
	b.ReportAllocs()
	b.ResetTimer()
	// Steady state: the previous snapshot equals the current one, so the MLX
	// reclaimer deltas are zero — the realistic per-heartbeat tail cost.
	prev := p.BackendCapacitySnapshot()
	for i := 0; i < b.N; i++ {
		runHeartbeatTail(ctx, s.ingestor, trustOwner, benchHeartbeatProviderID, p, prev, hb)
	}
}

// BenchmarkHeartbeatBranchTelemetryOnlyStatsd is the API-side tail with a real
// DogStatsD client attached.
func BenchmarkHeartbeatBranchTelemetryOnlyStatsd(b *testing.B) {
	s, trustOwner, p := benchHeartbeatFixture(b)
	s.observation.SetDatadog(benchLocalStatsd(b))
	hb := benchHeartbeatMessage()
	ctx := context.Background()
	b.ReportAllocs()
	b.ResetTimer()
	// Steady state: the previous snapshot equals the current one, so the MLX
	// reclaimer deltas are zero — the realistic per-heartbeat tail cost.
	prev := p.BackendCapacitySnapshot()
	for i := 0; i < b.N; i++ {
		runHeartbeatTail(ctx, s.ingestor, trustOwner, benchHeartbeatProviderID, p, prev, hb)
	}
}
