package registry_test

import (
	"math"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/forecast"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/performance"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestResolvePrefillTPSKeepsQualifiedRate(t *testing.T) {
	var catalog *performance.Catalog
	r, p, profile := reviewedServingProvider(t, func(deps *production.Dependencies) { catalog = deps.PerformanceProfiles })
	profile.BatchCurve = []performance.BatchPoint{
		{Width: 1, DecodeP10TPS: 90, AggregateDecodeTPS: 100, PrefillTPS: 6000, FirstContentP95MS: 1200},
		{Width: 4, DecodeP10TPS: 50, AggregateDecodeTPS: 250, PrefillTPS: 3000, FirstContentP95MS: 1500},
		{Width: 16, DecodeP10TPS: 35, AggregateDecodeTPS: 700, PrefillTPS: 1000, FirstContentP95MS: 2800},
	}
	for _, tc := range []struct {
		name           string
		running        int
		observed, want float64
	}{
		{"solo with hot EWMA", 0, 18000, 6000},
		{"intermediate width with hot EWMA", 2, 18000, 3000},
		{"largest qualified width with hot EWMA", 15, 18000, 1000},
		{"solo with slower EWMA", 0, 500, 6000},
	} {
		t.Run(tc.name, func(t *testing.T) {
			p.Mu().Lock()
			p.PrefillTPS = 700
			p.BackendCapacity.Slots[0].State = "idle"
			p.BackendCapacity.Slots[0].NumRunning = tc.running
			p.BackendCapacity.Slots[0].ObservedPrefillTPS = tc.observed
			qualified := catalog.Qualified(performance.Identity{Version: p.Version, Hardware: p.Hardware, Models: p.Models,
				Capacity: p.BackendCapacity, ThermalState: p.SystemMetrics.ThermalState}, profile.ModelID)
			p.Mu().Unlock()
			if qualified != profile {
				t.Fatal("exact reviewed identity did not reach routing snapshot")
			}
			rates := performance.Rates{Profile: qualified, StaticPrefill: 700, ObservedPrefill: tc.observed, Occupancy: tc.running}
			if got := rates.Prefill(); got != tc.want {
				t.Fatalf("prefill TPS = %v, want qualified %v", got, tc.want)
			}
			selected, decision := r.ReserveProviderEx(profile.ModelID, &production.PendingRequest{
				RequestID: "prefill-check", Model: profile.ModelID, EstimatedPromptTokens: 6000, RequestedMaxTokens: 1,
			})
			if selected != p {
				t.Fatalf("qualified identity failed real reservation: %+v", decision)
			}
			p.RemovePending("prefill-check")
			point, _ := profile.BatchAt(tc.running + 1)
			want := forecast.HandoffMS + 6000/tc.want*1000 + 1000/point.DecodeP10TPS
			if math.Abs(decision.FirstContent.ExpectedMs-want) > 1e-6 {
				t.Fatalf("first-content forecast = %v ms, want qualified %v ms", decision.FirstContent.ExpectedMs, want)
			}
		})
	}
}

func TestResolvePrefillTPSFallsBackWithoutQualifiedPoint(t *testing.T) {
	for _, noPoint := range []string{"unmatched artifact", "width beyond qualification"} {
		t.Run(noPoint, func(t *testing.T) {
			var catalog *performance.Catalog
			r, p, profile := reviewedServingProvider(t, func(deps *production.Dependencies) { catalog = deps.PerformanceProfiles })
			p.PrefillTPS = 700
			p.BackendCapacity.Slots[0].ObservedPrefillTPS = 18000
			if noPoint == "unmatched artifact" {
				p.Models[0].WeightHash = "unverified"
			} else {
				p.BackendCapacity.Slots[0].NumRunning = profile.MaxConcurrency
			}
			qualified := catalog.Qualified(performance.Identity{Version: p.Version, Hardware: p.Hardware, Models: p.Models,
				Capacity: p.BackendCapacity, ThermalState: p.SystemMetrics.ThermalState}, profile.ModelID)
			rates := performance.Rates{Profile: qualified, StaticPrefill: 700, ObservedPrefill: 18000, Occupancy: p.BackendCapacity.Slots[0].NumRunning}
			if got := rates.Prefill(); got != 18000 {
				t.Fatalf("live fallback = %v, want 18000", got)
			}
			rates.ObservedPrefill = 0
			if got := rates.Prefill(); got != 700 {
				t.Fatalf("static fallback = %v, want 700", got)
			}
			if noPoint == "unmatched artifact" {
				selected, decision := r.ReserveProviderEx(profile.ModelID, &production.PendingRequest{
					RequestID: "fallback-check", Model: profile.ModelID, EstimatedPromptTokens: 18000, RequestedMaxTokens: 1,
				})
				if selected != p || math.Abs(decision.FirstContent.ExpectedMs-(forecast.HandoffMS+1000+1000/decision.EffectiveTPS)) > 1e-6 {
					t.Fatalf("unmatched identity bypassed real prefill fallback: %+v", decision)
				}
				p.RemovePending("fallback-check")
			}
		})
	}
}
