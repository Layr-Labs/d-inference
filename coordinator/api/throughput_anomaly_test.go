package api

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// makeDecodeProvider registers a provider reporting a single backend slot for
// model with the given observed decode TPS and hardware class. bandwidth=0 omits
// the provider-reported memory bandwidth so the chip table is exercised instead.
func makeDecodeProvider(t *testing.T, reg *registry.Registry, id, chipFamily, chipTier string, bandwidth, observedTPS float64, model string) {
	t.Helper()
	msg := &protocol.RegisterMessage{
		Type: protocol.TypeRegister,
		Hardware: protocol.Hardware{
			ChipName:           "Apple " + chipFamily + " " + chipTier,
			ChipFamily:         chipFamily,
			ChipTier:           chipTier,
			MemoryGB:           64,
			MemoryBandwidthGBs: bandwidth,
		},
		Models: []protocol.ModelInfo{
			{ID: model, SizeBytes: 5_000_000_000, ModelType: "chat", Quantization: "4bit"},
		},
		Backend: "mlx-swift",
	}
	p := reg.Register(id, nil, msg)
	p.Mu().Lock()
	p.BackendCapacity = &protocol.BackendCapacity{
		TotalMemoryGB: 64,
		Slots: []protocol.BackendSlotCapacity{
			{Model: model, State: "idle", ObservedDecodeTPS: observedTPS},
		},
	}
	p.Mu().Unlock()
}

// TestThroughputAnomalySweep_FlagsGemmaNotGptoss drives the full server sweep
// over a registry of providers reporting the production decode numbers and
// asserts the in-process counter (visible at /v1/admin/metrics) is incremented
// for gemma but not for gpt-oss.
func TestThroughputAnomalySweep_FlagsGemmaNotGptoss(t *testing.T) {
	logger := quietLogger()
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)

	// gemma: 3 M3 Max providers decoding ~21 tok/s (a dense-26B read). Report 0
	// bandwidth so the chip-table fallback (M3 Max → 400 GB/s) is exercised.
	makeDecodeProvider(t, reg, "g1", "M3", "Max", 0, 20, "gemma-4-26b-qat-4bit")
	makeDecodeProvider(t, reg, "g2", "M3", "Max", 0, 21, "gemma-4-26b-qat-4bit")
	makeDecodeProvider(t, reg, "g3", "M3", "Max", 0, 22, "gemma-4-26b-qat-4bit")
	// gpt-oss: 3 M3 Max providers decoding ~69 tok/s (healthy sparse read).
	// Report bandwidth explicitly to exercise the provider-reported override.
	makeDecodeProvider(t, reg, "o1", "M3", "Max", 400, 68, "gpt-oss-20b")
	makeDecodeProvider(t, reg, "o2", "M3", "Max", 400, 69, "gpt-oss-20b")
	makeDecodeProvider(t, reg, "o3", "M3", "Max", 400, 70, "gpt-oss-20b")

	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.sweepThroughputAnomalies(registry.DefaultThroughputAnomalyConfig())

	counters := srv.metrics.Snapshot().Counters
	const (
		gemmaKey  = "routing.throughput_anomaly{chip_family=M3 Max,model=gemma-4-26b-qat-4bit}"
		gptossKey = "routing.throughput_anomaly{chip_family=M3 Max,model=gpt-oss-20b}"
	)
	if counters[gemmaKey] != 1 {
		t.Fatalf("gemma anomaly counter = %d, want 1 (counters=%v)", counters[gemmaKey], counters)
	}
	if _, ok := counters[gptossKey]; ok {
		t.Fatalf("gpt-oss must NOT be flagged, but counter present (counters=%v)", counters)
	}
}

// TestThroughputAnomalySweep_InsufficientSamples confirms a single slow gemma
// provider does not trip the detector (min samples gate).
func TestThroughputAnomalySweep_InsufficientSamples(t *testing.T) {
	logger := quietLogger()
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)

	makeDecodeProvider(t, reg, "g1", "M3", "Max", 400, 21, "gemma-4-26b-qat-4bit")

	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.sweepThroughputAnomalies(registry.DefaultThroughputAnomalyConfig())

	for k, v := range srv.metrics.Snapshot().Counters {
		if v != 0 && k == "routing.throughput_anomaly{chip_family=M3 Max,model=gemma-4-26b-qat-4bit}" {
			t.Fatalf("should not flag with a single sample, got %s=%d", k, v)
		}
	}
}

// TestThroughputAnomalySweep_EmitsDatadog validates the DogStatsD emission path
// (s.ddIncr) and the {model, chip_family} tagging.
func TestThroughputAnomalySweep_EmitsDatadog(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()

	logger := quietLogger()
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	makeDecodeProvider(t, reg, "g1", "M3", "Max", 400, 20, "gemma-4-26b-qat-4bit")
	makeDecodeProvider(t, reg, "g2", "M3", "Max", 400, 21, "gemma-4-26b-qat-4bit")
	makeDecodeProvider(t, reg, "g3", "M3", "Max", 400, 22, "gemma-4-26b-qat-4bit")

	srv := NewServer(reg, st, ServerConfig{}, logger)
	ddClient := newTestDD(t, collector)
	defer ddClient.Close()
	srv.SetDatadog(ddClient)

	srv.sweepThroughputAnomalies(registry.DefaultThroughputAnomalyConfig())

	_ = ddClient.Statsd.Flush()
	packets := collector.drain()
	if !hasMetric(packets, "routing.throughput_anomaly") {
		t.Errorf("missing routing.throughput_anomaly DD metric; got packets: %v", packets)
	}
	if !hasMetric(packets, "model:gemma-4-26b-qat-4bit") {
		t.Errorf("missing model tag; got packets: %v", packets)
	}
	if !hasMetric(packets, "chip_family:M3 Max") {
		t.Errorf("missing chip_family tag; got packets: %v", packets)
	}
}
