package registry

// Fleet-scale routing benchmarks.
//
// The 2026-09-01 congestion collapse (PR #799) was a CPU cliff: every request
// walked ~1,260 providers, and the failure path re-walked them up to 64 times.
// These benchmarks reproduce that fleet shape in-process so a scheduler change
// can be measured (ns/op, allocs/op, pprof) instead of argued about:
//
//	go test ./registry/ -run '^$' -bench 'Fleet' -benchmem
//	go test ./registry/ -run '^$' -bench 'FleetReserveProviderEx$' -cpuprofile /tmp/fleet.prof
//	go tool pprof -top -nodecount=40 registry.test /tmp/fleet.prof
//
// The fleet is deliberately heterogeneous: providers advertise one to three of
// benchFleetModels, half of them have the requested model resident, every
// provider carries a live BackendCapacity heartbeat (token budgets, observed
// TPS, running/waiting counts) and a few in-flight pending requests, and the
// catalog is populated so the catalog gates take their real path. Nothing here
// depends on a store, a WebSocket, or Postgres.

import (
	"fmt"
	"io"
	"log/slog"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

const (
	benchFleetProviders = 1260
	benchFleetModels    = 15
	// benchFleetPublicKey is a syntactically valid base64 X25519 key so the
	// private-text gate passes; it is never used for real encryption here.
	benchFleetPublicKey = "fX6XYH7p2hmM3ogeXaAsY+p8M6UKD1df/LJUN9Nj9Nw="
)

type benchFleet struct {
	reg    *Registry
	models []string
	ids    []string
}

func benchFleetModelID(i int) string {
	return fmt.Sprintf("mlx-community/bench-model-%02d-4bit", i)
}

// buildBenchFleet registers providers synthetic providers. Provider i
// advertises model i%models always, model (i+1)%models when i is even, and
// model (i+2)%models when i%3 == 0, so each model has ~3× providers/models
// advertisers and the scan sees a realistic mix of "advertises the model" and
// "does not". The primary model is resident (warm) on even providers only.
func buildBenchFleet(tb testing.TB, providers, models int) *benchFleet {
	tb.Helper()
	logger := slog.New(slog.NewTextHandler(io.Discard, &slog.HandlerOptions{Level: slog.LevelError}))
	reg := New(logger)

	f := &benchFleet{reg: reg}
	catalog := make([]CatalogEntry, 0, models)
	for m := 0; m < models; m++ {
		id := benchFleetModelID(m)
		f.models = append(f.models, id)
		catalog = append(catalog, CatalogEntry{ID: id, SizeGB: 16 + float64(m), MinRAMGB: 32})
	}
	reg.SetModelCatalog(catalog)

	for i := 0; i < providers; i++ {
		id := fmt.Sprintf("bench-%04d", i)
		f.ids = append(f.ids, id)
		advertised := []string{f.models[i%models]}
		if i%2 == 0 {
			advertised = append(advertised, f.models[(i+1)%models])
		}
		if i%3 == 0 {
			advertised = append(advertised, f.models[(i+2)%models])
		}
		infos := make([]protocol.ModelInfo, 0, len(advertised))
		for _, m := range advertised {
			infos = append(infos, protocol.ModelInfo{ID: m, ModelType: "chat", Quantization: "4bit"})
		}
		msg := &protocol.RegisterMessage{
			Type: protocol.TypeRegister,
			Hardware: protocol.Hardware{
				MachineModel:       "Mac15,8",
				ChipName:           "Apple M3 Max",
				ChipFamily:         "M3",
				ChipTier:           "Max",
				MemoryGB:           64 + 32*(i%3),
				MemoryAvailableGB:  60,
				MemoryBandwidthGBs: 400,
				CPUCores:           protocol.CPUCores{Total: 16, Performance: 12, Efficiency: 4},
				GPUCores:           40,
			},
			Models:                  infos,
			Backend:                 BackendMLXSwift,
			Version:                 "0.8.15",
			DecodeTPS:               20 + float64(i%25),
			PublicKey:               benchFleetPublicKey,
			EncryptedResponseChunks: true,
			PrivacyCapabilities: &protocol.PrivacyCapabilities{
				TextBackendInprocess:    true,
				TextProxyDisabled:       true,
				PythonRuntimeLocked:     true,
				DangerousModulesBlocked: true,
				SIPEnabled:              true,
				AntiDebugEnabled:        true,
				CoreDumpsDisabled:       true,
				EnvScrubbed:             true,
			},
		}
		p := reg.Register(id, nil, msg)
		makeProviderRoutable(p)

		// One realistic heartbeat per provider: the primary model resident on
		// even providers, the others cold; live token budgets and observed rates.
		reg.Heartbeat(id, benchHeartbeat(i, advertised))

		// A few in-flight requests so pending accounting is exercised.
		for k := 0; k < i%4; k++ {
			p.AddPending(&PendingRequest{
				RequestID:             fmt.Sprintf("%s-pending-%d", id, k),
				Model:                 advertised[k%len(advertised)],
				EstimatedPromptTokens: 800,
				RequestedMaxTokens:    512,
			})
		}
	}
	return f
}

func benchHeartbeat(i int, advertised []string) *protocol.HeartbeatMessage {
	var slots []protocol.BackendSlotCapacity
	if i%2 == 0 {
		running := i % 3
		slots = append(slots, protocol.BackendSlotCapacity{
			Model:                 advertised[0],
			State:                 "running",
			NumRunning:            running,
			NumWaiting:            i % 2,
			MaxConcurrency:        8,
			ActiveTokens:          int64(running) * 900,
			MaxTokensPotential:    int64(running) * 1400,
			ObservedDecodeTPS:     18 + float64(i%20),
			ObservedPrefillTPS:    900 + float64(i%300),
			ActiveTokenBudgetUsed: int64(running) * 1400,
			ActiveTokenBudgetMax:  120000,
			QueuedTokenBudget:     int64(i%2) * 1400,
			KVBytesPerToken:       98304,
		})
	}
	active := advertised[0]
	free := 30.0
	return &protocol.HeartbeatMessage{
		Type:        protocol.TypeHeartbeat,
		Status:      "idle",
		ActiveModel: &active,
		WarmModels:  advertised[:1],
		SystemMetrics: protocol.SystemMetrics{
			MemoryPressure: 0.2 + 0.01*float64(i%30),
			CPUUsage:       0.1 + 0.01*float64(i%40),
			ThermalState:   "nominal",
		},
		BackendCapacity: &protocol.BackendCapacity{
			Slots:             slots,
			GPUMemoryActiveGB: 18,
			GPUMemoryPeakGB:   22,
			GPUMemoryCacheGB:  2,
			TotalMemoryGB:     float64(64 + 32*(i%3)),
			FreeForLoadGB:     &free,
		},
	}
}

func benchPendingRequest(model string, n int) *PendingRequest {
	return &PendingRequest{
		RequestID:             fmt.Sprintf("bench-req-%d", n),
		Model:                 model,
		EstimatedPromptTokens: 600,
		RequestedMaxTokens:    512,
		FirstContentBudgetMS:  10_000,
		FirstContentDeadline:  time.Now().Add(10 * time.Second),
	}
}

// TestFleetScaleBenchFixture pins the fixture itself: the benchmark must be
// measuring a fleet that actually routes, or its numbers are meaningless.
func TestFleetScaleBenchFixture(t *testing.T) {
	f := buildBenchFleet(t, benchFleetProviders, benchFleetModels)
	model := f.models[0]

	candidates, capacityRejections, tooLarge := f.reg.QuickCapacityCheckForRequest(model, 600, 512, RequestTraits{}, false)
	if candidates == 0 {
		t.Fatalf("fixture has no routable candidates for %s (capacity=%d tooLarge=%d)", model, capacityRejections, tooLarge)
	}
	// Providers advertising model 0: i%15==0 (84) + even i with (i+1)%15==0 (42)
	// + i%3==0 with (i+2)%15==0 (28) — a few hundred, never the whole fleet.
	if candidates > benchFleetProviders/2 {
		t.Fatalf("fixture is too homogeneous: %d/%d providers route %s", candidates, benchFleetProviders, model)
	}

	pr := benchPendingRequest(model, 0)
	p, decision := f.reg.ReserveProviderEx(model, pr)
	if p == nil {
		t.Fatalf("fixture cannot reserve a provider: %+v", decision)
	}
	if got := p.RemovePending(pr.RequestID); got != pr {
		t.Fatalf("pending request not released from %s", p.ID)
	}
	t.Logf("fixture: %d providers, %d models, %d candidates for %s (capacity rejections %d)",
		benchFleetProviders, benchFleetModels, candidates, model, capacityRejections)
}

// BenchmarkFleetReserveProviderEx is the dispatch-path reservation: shared scan
// + serialized commit + release, one request at a time.
func BenchmarkFleetReserveProviderEx(b *testing.B) {
	f := buildBenchFleet(b, benchFleetProviders, benchFleetModels)
	model := f.models[0]
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		pr := benchPendingRequest(model, i)
		p, _ := f.reg.ReserveProviderEx(model, pr)
		if p == nil {
			b.Fatal("no provider reserved")
		}
		p.RemovePending(pr.RequestID)
	}
}

// BenchmarkFleetReserveProviderExParallel runs reservations from GOMAXPROCS
// goroutines to expose lock contention between the shared scan and the commit
// section.
func BenchmarkFleetReserveProviderExParallel(b *testing.B) {
	f := buildBenchFleet(b, benchFleetProviders, benchFleetModels)
	b.ReportAllocs()
	b.ResetTimer()
	b.RunParallel(func(pb *testing.PB) {
		n := 0
		for pb.Next() {
			model := f.models[n%len(f.models)]
			pr := benchPendingRequest(model, n)
			p, _ := f.reg.ReserveProviderEx(model, pr)
			if p == nil {
				b.Fatal("no provider reserved")
			}
			p.RemovePending(pr.RequestID)
			n++
		}
	})
}

// BenchmarkFleetQuickCapacityCheck is the consumer preflight (runs once per
// request before dispatch, and again per failover attempt).
func BenchmarkFleetQuickCapacityCheck(b *testing.B) {
	f := buildBenchFleet(b, benchFleetProviders, benchFleetModels)
	model := f.models[0]
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		candidates, _, _, _, _ := f.reg.QuickCapacityCheckWithTTFTForRequest(model, 600, 512, RequestTraits{}, false)
		if candidates == 0 {
			b.Fatal("no candidates")
		}
	}
}

// BenchmarkFleetHeartbeat is the ingest path: ~1,260 providers × one baseline
// heartbeat every 5s is ~250 applications/s in production.
func BenchmarkFleetHeartbeat(b *testing.B) {
	f := buildBenchFleet(b, benchFleetProviders, benchFleetModels)
	msgs := make([]*protocol.HeartbeatMessage, len(f.ids))
	for i := range f.ids {
		msgs[i] = benchHeartbeat(i, []string{f.models[i%benchFleetModels]})
	}
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		idx := i % len(f.ids)
		f.reg.Heartbeat(f.ids[idx], msgs[idx])
	}
}

// BenchmarkFleetListModels is the /v1/models aggregation over the whole fleet.
func BenchmarkFleetListModels(b *testing.B) {
	f := buildBenchFleet(b, benchFleetProviders, benchFleetModels)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if len(f.reg.ListModels()) == 0 {
			b.Fatal("no models")
		}
	}
}
