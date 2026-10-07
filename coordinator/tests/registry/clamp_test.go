package registry_test

import (
	"log/slog"
	"math"
	"os"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/capacityvalue"

	"github.com/eigeninference/d-inference/coordinator/protocol"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestBackendCapacitySnapshotDetachesLoadDiagnostics(t *testing.T) {
	usable, headroom := 14.3, 6.5
	p := &production.Provider{BackendCapacity: &protocol.BackendCapacity{
		LoadUsableGB: &usable, LoadHeadroomGB: &headroom,
	}}
	snapshot := p.BackendCapacitySnapshot()
	usable, headroom = 20, 7
	if snapshot.LoadUsableGB == nil || *snapshot.LoadUsableGB != 14.3 ||
		snapshot.LoadHeadroomGB == nil || *snapshot.LoadHeadroomGB != 6.5 {
		t.Fatalf("snapshot aliased live load diagnostics: %+v", snapshot)
	}
}

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
			got, chg := capacityvalue.ClampNonNeg(tc.v, tc.max)
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
	capacityvalue.ClampBackendCapacity(logger, "p1", nil)
}

func TestClampBackendCapacityMaliciousValues(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, nil))
	bc := &protocol.BackendCapacity{
		TotalMemoryGB:     1e9, // impossible
		GPUMemoryActiveGB: -5,  // negative
		GPUMemoryPeakGB:   math.NaN(),
		GPUMemoryCacheGB:  2048,
		Slots: []protocol.BackendSlotCapacity{
			{Model: "qwen", MaxTokensPotential: 1 << 60, NumRunning: -1, NumWaiting: -1, MaxConcurrency: -3},
			{Model: "huge", MaxConcurrency: 99},
		},
	}
	capacityvalue.ClampBackendCapacity(logger, "p1", bc)

	if bc.TotalMemoryGB != capacityvalue.MaxMemoryGBFloat {
		t.Errorf("TotalMemoryGB = %v, want %v", bc.TotalMemoryGB, capacityvalue.MaxMemoryGBFloat)
	}
	if bc.GPUMemoryActiveGB != 0 {
		t.Errorf("GPUMemoryActiveGB = %v, want 0", bc.GPUMemoryActiveGB)
	}
	if bc.GPUMemoryPeakGB != 0 {
		t.Errorf("GPUMemoryPeakGB = %v, want 0 (NaN clamped)", bc.GPUMemoryPeakGB)
	}
	if bc.GPUMemoryCacheGB != capacityvalue.MaxMemoryGBFloat {
		t.Errorf("GPUMemoryCacheGB = %v, want %v", bc.GPUMemoryCacheGB, capacityvalue.MaxMemoryGBFloat)
	}
	s := bc.Slots[0]
	if s.MaxTokensPotential != capacityvalue.MaxTokensPotential {
		t.Errorf("MaxTokensPotential = %v, want %v", s.MaxTokensPotential, capacityvalue.MaxTokensPotential)
	}
	if s.NumRunning != 0 || s.NumWaiting != 0 {
		t.Errorf("NumRunning=%d NumWaiting=%d, want both 0", s.NumRunning, s.NumWaiting)
	}
	if s.MaxConcurrency != 0 {
		t.Errorf("negative MaxConcurrency = %d, want 0", s.MaxConcurrency)
	}
	if bc.Slots[1].MaxConcurrency != capacityvalue.MaxReportedMaxConcurrency {
		t.Errorf("huge MaxConcurrency = %d, want %d", bc.Slots[1].MaxConcurrency, capacityvalue.MaxReportedMaxConcurrency)
	}
}

func TestClampBackendCapacityFreeForLoad(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, nil))

	// Out-of-range reported values are nilled (→ cold-load gate falls back to the
	// heuristic) rather than trusted.
	for _, bad := range []float64{math.NaN(), math.Inf(1), -3, 1e9} {
		v := bad
		bc := &protocol.BackendCapacity{TotalMemoryGB: 64, FreeForLoadGB: &v}
		capacityvalue.ClampBackendCapacity(logger, "p1", bc)
		if bc.FreeForLoadGB != nil {
			t.Errorf("FreeForLoadGB=%v should be nilled, got %v", bad, *bc.FreeForLoadGB)
		}
	}

	// A legitimate value (including 0) is preserved.
	for _, ok := range []float64{0, 9, 128} {
		v := ok
		bc := &protocol.BackendCapacity{TotalMemoryGB: 64, FreeForLoadGB: &v}
		capacityvalue.ClampBackendCapacity(logger, "p1", bc)
		if bc.FreeForLoadGB == nil || *bc.FreeForLoadGB != ok {
			t.Errorf("FreeForLoadGB=%v should be preserved, got %v", ok, bc.FreeForLoadGB)
		}
	}
}

func TestClampBackendCapacityLoadDiagnostics(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, nil))
	for _, bad := range []float64{math.NaN(), math.Inf(1), -1, 1e9} {
		usable, headroom := bad, bad
		bc := &protocol.BackendCapacity{LoadUsableGB: &usable, LoadHeadroomGB: &headroom}
		capacityvalue.ClampBackendCapacity(logger, "p1", bc)
		if bc.LoadUsableGB != nil || bc.LoadHeadroomGB != nil {
			t.Errorf("bad load diagnostic %v should be omitted", bad)
		}
	}
	zero := 0.0
	bc := &protocol.BackendCapacity{LoadUsableGB: &zero, LoadHeadroomGB: &zero}
	capacityvalue.ClampBackendCapacity(logger, "p1", bc)
	if bc.LoadUsableGB == nil || bc.LoadHeadroomGB == nil {
		t.Fatal("legitimate zero must remain present")
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
			{Model: "qwen", MaxTokensPotential: 32000, NumRunning: 2, NumWaiting: 0, MaxConcurrency: 8},
		},
	}
	capacityvalue.ClampBackendCapacity(logger, "p1", bc)

	if bc.TotalMemoryGB != 128 {
		t.Errorf("TotalMemoryGB mutated: %v", bc.TotalMemoryGB)
	}
	if bc.Slots[0].MaxTokensPotential != 32000 {
		t.Errorf("MaxTokensPotential mutated: %v", bc.Slots[0].MaxTokensPotential)
	}
	if bc.Slots[0].MaxConcurrency != 8 {
		t.Errorf("MaxConcurrency mutated: %v", bc.Slots[0].MaxConcurrency)
	}
}

func TestClampBackendCapacityPrefillOverflowIgnored(t *testing.T) {
	// A provider-side overflow (billions of tok/s, seen when the
	// admitted->first-token window collapses on a prefix-cache hit) must be
	// treated as NO measurement (0) so resolvePrefillTPS falls back to the
	// conservative decode×ratio estimate — NOT clamped UP to maxPrefillTPS, which
	// would make the TTFT estimate over-optimistic and the hard gate over-accept.
	logger := slog.New(slog.NewTextHandler(os.Stderr, nil))
	bc := &protocol.BackendCapacity{
		Slots: []protocol.BackendSlotCapacity{
			{Model: "gpt-oss-20b", ObservedPrefillTPS: 3.5e9}, // overflow garbage
			{Model: "gemma", ObservedPrefillTPS: -1},          // negative
			{Model: "nan", ObservedPrefillTPS: math.NaN()},    // NaN
			{Model: "ok", ObservedPrefillTPS: 1600},           // plausible -> kept
		},
	}
	capacityvalue.ClampBackendCapacity(logger, "p1", bc)

	if bc.Slots[0].ObservedPrefillTPS != 0 {
		t.Errorf("overflow ObservedPrefillTPS = %v, want 0 (ignored, not clamped to max)", bc.Slots[0].ObservedPrefillTPS)
	}
	if bc.Slots[1].ObservedPrefillTPS != 0 {
		t.Errorf("negative ObservedPrefillTPS = %v, want 0", bc.Slots[1].ObservedPrefillTPS)
	}
	if bc.Slots[2].ObservedPrefillTPS != 0 {
		t.Errorf("NaN ObservedPrefillTPS = %v, want 0", bc.Slots[2].ObservedPrefillTPS)
	}
	if bc.Slots[3].ObservedPrefillTPS != 1600 {
		t.Errorf("plausible ObservedPrefillTPS = %v, want 1600 (unchanged)", bc.Slots[3].ObservedPrefillTPS)
	}
}
