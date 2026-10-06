package admission_test

import (
	"math"
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/registry/admission"
)

func TestModelFitsHardware(t *testing.T) {
	for _, tc := range []struct {
		min         int
		size, total float64
		want        bool
	}{
		{24, 100, 24, true}, {25, 1, 24, false}, {0, 12, 24, true}, {0, 12.1, 24, false},
		{0, 0, 24, true}, {100, 100, 0, true},
	} {
		if got := production.ModelFitsHardware(tc.min, tc.size, tc.total); got != tc.want {
			t.Fatalf("%+v: got %t", tc, got)
		}
	}
}

func TestReportedLoadAdmits(t *testing.T) {
	for _, tc := range []struct {
		name                   string
		catalog, native, free  float64
		reported, admit, known bool
	}{
		{"absent", 8, 0, 0, false, false, false},
		{"fits_padded", 8, 0, 9, true, true, true},
		{"raw_only_fits", 9.5, 0, 10, true, false, true},
		{"zero_report", 8, 0, 0, true, false, true},
		{"native_load", 100, 8, 9, true, true, true},
		{"native_fallback", 8, math.NaN(), 9, true, true, true},
		{"unknown_catalog", 0, 0, 9, true, false, false},
		{"invalid_report_first", 0, 0, math.NaN(), true, false, true},
		{"infinite_report", 8, 0, math.Inf(1), true, false, true},
		{"negative_report", 8, 0, -1, true, false, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			admit, known := production.ReportedLoadAdmits(tc.catalog, tc.native, tc.free, tc.reported)
			if admit != tc.admit || known != tc.known {
				t.Fatalf("got %t/%t, want %t/%t", admit, known, tc.admit, tc.known)
			}
		})
	}
}

func TestMemoryAdmission(t *testing.T) {
	for _, tc := range []struct {
		name   string
		memory production.Memory
		tokens int64
		want   bool
	}{
		{"unknown", production.Memory{}, 1, true},
		{"resident", production.Memory{ModelSizeGB: 8, TotalGB: 64, ActiveGB: 63, ModelLoaded: true}, 1000, true},
		{"cold_alongside", production.Memory{ModelSizeGB: 8, TotalGB: 64, ActiveGB: 63}, 1000, false},
		{"idle_eviction", production.Memory{ModelSizeGB: 8, TotalGB: 64, ActiveGB: 63, AvailableOnDisk: true}, 1000, true},
		{"no_busy_eviction", production.Memory{ModelSizeGB: 8, TotalGB: 64, ActiveGB: 63, AvailableOnDisk: true, TotalPending: 1}, 1000, false},
		{"reported_zero", production.Memory{ModelSizeGB: 8, TotalGB: 64, AvailableOnDisk: true, LoadReported: true}, 1000, false},
		{"os_reserve", production.Memory{ModelSizeGB: 8, TotalGB: 11, AvailableOnDisk: true}, 0, false},
		{"negative_tokens", production.Memory{ModelSizeGB: 8, TotalGB: 8}, -1, true},
		{"bounded_tokens", production.Memory{ModelSizeGB: 8, TotalGB: 7000}, math.MaxInt64, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := production.MemoryAdmits(tc.memory, tc.tokens); got != tc.want {
				t.Fatalf("got %t, want %t", got, tc.want)
			}
		})
	}
}
