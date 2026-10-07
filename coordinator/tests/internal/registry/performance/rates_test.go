package performance_test

import (
	"math"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/performance"
)

func TestEffectiveDecodeExpiresOnlyDatedIdleMeasurements(t *testing.T) {
	boundary := int32((30 * time.Minute).Milliseconds())
	for _, tc := range []struct {
		name   string
		change func(*performance.Rates)
		want   float64
	}{
		{"stale_idle", func(*performance.Rates) {}, 100},
		{"fresh", func(r *performance.Rates) { r.DecodeAgeMs = 1000 }, 1},
		{"current", func(r *performance.Rates) { r.DecodeAgeMs = 0 }, 1},
		{"boundary", func(r *performance.Rates) { r.DecodeAgeMs = boundary }, 1},
		{"unknown_age", func(r *performance.Rates) { r.DecodeAgeMs = -1 }, 1},
		{"not_idle_loaded", func(r *performance.Rates) { r.IdleLoaded = false }, 1},
		{"no_median", func(r *performance.Rates) { r.FleetMedian = 0 }, 80},
		{"no_fallback", func(r *performance.Rates) { r.FleetMedian, r.StaticDecode = 0, 0 }, 1},
		{"explored", func(r *performance.Rates) { r.ExploredDecode = 120 }, 120},
		{"reviewed_profile", func(r *performance.Rates) {
			r.Profile = &performance.Profile{MaxConcurrency: 1,
				BatchCurve: []performance.BatchPoint{{Width: 1, DecodeP10TPS: 35, PrefillTPS: 900}}}
			r.ExploredDecode = 120
		}, 35},
	} {
		t.Run(tc.name, func(t *testing.T) {
			rates := performance.Rates{IdleLoaded: true, DecodeAgeMs: boundary + 1,
				ObservedDecode: 1, FleetMedian: 100, StaticDecode: 80,
				ObservedPrefill: 400, StaticPrefill: 900}
			tc.change(&rates)
			if got := rates.EffectiveDecode(0); got != tc.want {
				t.Fatalf("decode TPS=%v, want %v", got, tc.want)
			}
			if rates.Profile == nil && rates.Prefill() != 400 {
				t.Fatal("decode age altered independent prefill pricing")
			}
		})
	}
}

func TestStaleIdleDecodeDoesNotChangeProjectedAdmission(t *testing.T) {
	rates := performance.Rates{IdleLoaded: true, DecodeAgeMs: int32((31 * time.Minute).Milliseconds()),
		ObservedDecode: 1, FleetMedian: 100, StaticDecode: 80, ExploredDecode: 120}
	for _, useMedian := range []bool{false, true} {
		for _, batch := range []int{0, 1, 4} {
			if got, want := rates.ProjectedDecode(batch, 0.1, useMedian), 1/(1+0.1*float64(batch+1)); got != want {
				t.Fatalf("batch=%d median=%t: projected decode=%v, want %v", batch, useMedian, got, want)
			}
		}
	}
}

func TestUsesExplorationMatchesResolvedRatePrecedence(t *testing.T) {
	profile := &performance.Profile{MaxConcurrency: 2,
		BatchCurve: []performance.BatchPoint{{Width: 1, DecodeP10TPS: 35, PrefillTPS: 900}}}
	for _, tc := range []struct {
		name  string
		rates performance.Rates
		want  bool
	}{
		{"no_medians", performance.Rates{ObservedDecode: 10, ObservedPrefill: 100}, false},
		{"ordinary_fleet_fallback", performance.Rates{FleetMedian: 100}, false},
		{"decode", performance.Rates{ExploredDecode: 100}, true},
		{"prefill", performance.Rates{ExploredPrefill: 2000}, true},
		{"invalid_prefill", performance.Rates{ExploredPrefill: math.Inf(1)}, false},
		{"invalid_decode", performance.Rates{ExploredDecode: math.NaN()}, false},
		{"reviewed_profile", performance.Rates{Profile: profile, ExploredDecode: 100, ExploredPrefill: 2000}, false},
		{"profile_point_missing", performance.Rates{Profile: profile, Occupancy: 1, ExploredDecode: 100}, true},
		{"profile_width_exceeded", performance.Rates{Profile: profile, Occupancy: 2, ExploredPrefill: 2000}, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := tc.rates.UsesExploration(); got != tc.want {
				t.Fatalf("UsesExploration=%t, want %t", got, tc.want)
			}
		})
	}
}
