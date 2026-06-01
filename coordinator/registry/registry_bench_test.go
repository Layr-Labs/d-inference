package registry

import (
	"fmt"
	"log/slog"
	"os"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// populateRegistry creates a registry with n providers, all serving the target model.
func populateRegistry(n int, model string) *Registry {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	reg := New(logger)
	reg.MinTrustLevel = TrustNone

	for i := range n {
		id := fmt.Sprintf("provider-%d", i)
		msg := &protocol.RegisterMessage{
			Type: protocol.TypeRegister,
			Hardware: protocol.Hardware{
				MachineModel:       "Mac15,8",
				ChipName:           "Apple M3 Max",
				ChipFamily:         "M3",
				ChipTier:           "Max",
				MemoryGB:           64,
				MemoryAvailableGB:  58.5,
				CPUCores:           protocol.CPUCores{Total: 16, Performance: 12, Efficiency: 4},
				GPUCores:           40,
				MemoryBandwidthGBs: 400,
			},
			Models: []protocol.ModelInfo{
				{ID: model, SizeBytes: 5_700_000_000, ModelType: "qwen3", Quantization: "4bit"},
			},
			Backend:    "vllm_mlx",
			DecodeTPS:  40.0 + float64(i%30),
			PrefillTPS: 200.0 + float64(i%50),
		}
		p := reg.Register(id, nil, msg)
		p.mu.Lock()
		p.TrustLevel = TrustHardware
		p.LastChallengeVerified = time.Now()
		p.WarmModels = []string{model}
		p.SystemMetrics = protocol.SystemMetrics{
			MemoryPressure: 0.1 + float64(i%5)*0.1,
			CPUUsage:       0.1 + float64(i%4)*0.1,
			ThermalState:   "nominal",
		}
		p.mu.Unlock()
		// Build some reputation.
		for range 20 {
			p.Reputation.RecordJobSuccess(time.Duration(100+i%50) * time.Millisecond)
		}
	}
	return reg
}

func BenchmarkFindProvider_10(b *testing.B) {
	b.ReportAllocs()
	model := "mlx-community/Qwen3.5-9B-Instruct-4bit"
	reg := populateRegistry(10, model)

	b.ResetTimer()
	for range b.N {
		p := reg.SelectProvider(model)
		if p != nil {
			// Reset status so provider can be found again.
			p.mu.Lock()
			p.Status = StatusOnline
			p.mu.Unlock()
		}
	}
}

func BenchmarkFindProvider_100(b *testing.B) {
	b.ReportAllocs()
	model := "mlx-community/Qwen3.5-9B-Instruct-4bit"
	reg := populateRegistry(100, model)

	b.ResetTimer()
	for range b.N {
		p := reg.SelectProvider(model)
		if p != nil {
			p.mu.Lock()
			p.Status = StatusOnline
			p.mu.Unlock()
		}
	}
}

func BenchmarkFindProvider_1000(b *testing.B) {
	b.ReportAllocs()
	model := "mlx-community/Qwen3.5-9B-Instruct-4bit"
	reg := populateRegistry(1000, model)

	b.ResetTimer()
	for range b.N {
		p := reg.SelectProvider(model)
		if p != nil {
			p.mu.Lock()
			p.Status = StatusOnline
			p.mu.Unlock()
		}
	}
}
