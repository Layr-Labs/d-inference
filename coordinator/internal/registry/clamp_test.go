package registry

import (
	"log/slog"
	"math"
	"os"
	"testing"

	"github.com/darkbloom/coordinator/internal/protocol"
)

func TestClampNonNeg(t *testing.T) {
	tests := []struct {
		name    string
		v, max  float64
		wantV   float64
		wantChg bool
	}{
		{"in range", 42.0, 100.0, 42.0, false},
		{"zero", 0.0, 100.0, 0.0, false},
		{"max boundary", 100.0, 100.0, 100.0, false},
		{"negative", -1.0, 100.0, 0.0, true},
		{"over max", 200.0, 100.0, 100.0, true},
		{"NaN", math.NaN(), 100.0, 0.0, true},
		{"+Inf", math.Inf(1), 100.0, 100.0, true},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, chg := clampNonNeg(tc.v, tc.max)
			if got != tc.wantV {
				t.Errorf("clampNonNeg(%v, %v) value = %v, want %v", tc.v, tc.max, got, tc.wantV)
			}
			if chg != tc.wantChg {
				t.Errorf("clampNonNeg(%v, %v) changed = %v, want %v", tc.v, tc.max, chg, tc.wantChg)
			}
		})
	}
}

func TestClampBackendCapacityNil(t *testing.T) {
	// Must not panic when bc is nil (old providers don't send BackendCapacity).
	logger := slog.New(slog.NewTextHandler(os.Stderr, nil))
	clampBackendCapacity(logger, "p1", nil)
}

func TestClampBackendCapacityMaliciousValues(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, nil))
	bc := &protocol.BackendCapacity{
		TotalMemoryGB:     1e9, // impossible
		GPUMemoryActiveGB: -5,  // negative
		GPUMemoryPeakGB:   math.NaN(),
		GPUMemoryCacheGB:  2048,
		Slots: []protocol.BackendSlotCapacity{
			{Model: "qwen", MaxTokensPotential: 1 << 60, NumRunning: -1, NumWaiting: -1},
		},
	}
	clampBackendCapacity(logger, "p1", bc)

	if bc.TotalMemoryGB != maxMemoryGBFloat {
		t.Errorf("TotalMemoryGB = %v, want %v", bc.TotalMemoryGB, maxMemoryGBFloat)
	}
	if bc.GPUMemoryActiveGB != 0 {
		t.Errorf("GPUMemoryActiveGB = %v, want 0", bc.GPUMemoryActiveGB)
	}
	if bc.GPUMemoryPeakGB != 0 {
		t.Errorf("GPUMemoryPeakGB = %v, want 0 (NaN clamped)", bc.GPUMemoryPeakGB)
	}
	if bc.GPUMemoryCacheGB != maxMemoryGBFloat {
		t.Errorf("GPUMemoryCacheGB = %v, want %v", bc.GPUMemoryCacheGB, maxMemoryGBFloat)
	}
	s := bc.Slots[0]
	if s.MaxTokensPotential != maxTokensPotential {
		t.Errorf("MaxTokensPotential = %v, want %v", s.MaxTokensPotential, maxTokensPotential)
	}
	if s.NumRunning != 0 || s.NumWaiting != 0 {
		t.Errorf("NumRunning=%d NumWaiting=%d, want both 0", s.NumRunning, s.NumWaiting)
	}
}

func TestClampBackendCapacityReasonableValues(t *testing.T) {
	// Realistic values should pass through unchanged.
	logger := slog.New(slog.NewTextHandler(os.Stderr, nil))
	bc := &protocol.BackendCapacity{
		TotalMemoryGB:     128,
		GPUMemoryActiveGB: 45.3,
		GPUMemoryPeakGB:   50.1,
		GPUMemoryCacheGB:  5.2,
		Slots: []protocol.BackendSlotCapacity{
			{Model: "qwen", MaxTokensPotential: 32000, NumRunning: 2, NumWaiting: 0},
		},
	}
	clampBackendCapacity(logger, "p1", bc)

	if bc.TotalMemoryGB != 128 {
		t.Errorf("TotalMemoryGB mutated: %v", bc.TotalMemoryGB)
	}
	if bc.Slots[0].MaxTokensPotential != 32000 {
		t.Errorf("MaxTokensPotential mutated: %v", bc.Slots[0].MaxTokensPotential)
	}
}
