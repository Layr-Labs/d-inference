package registry_test

import (
	"github.com/eigeninference/d-inference/coordinator/internal/registry/connectiontime"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/forecast"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/measurements"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"testing"
	"time"
)

func TestFirstContentIdleProviderWithoutEvidenceIsExploredAfterBound(t *testing.T) {
	cases := []struct {
		name string
		age  time.Duration
		gap  func(*production.Provider, *measurements.History, time.Time)
	}{
		{"never_measured", 10 * time.Minute, func(p *production.Provider, history *measurements.History, now time.Time) { history.Reset() }},
		{"measured_then_idle", 0, func(p *production.Provider, history *measurements.History, now time.Time) {
			old := now.Add(-10 * time.Minute)
			capacity := p.BackendCapacity
			capacity.Slots[0].PerformanceMeasurements = localRateMeasurements(20_000, capacity.Slots[0].ObservedDecodeTPS)
			history.Reset()
			history.Reconcile(capacity, p.CapacityAcceptedAt, old, 0)
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := newExplorationPair(t, "explore", tc.age, tc.gap)
			if selected, _ := f.registry.ReserveProviderEx("explore", deadlineRequest()); selected != f.idle {
				t.Fatalf("selected=%v, want the idle provider explored past the bound", selected)
			}
		})
	}
}

func TestFirstContentExplorationKeepsQualifiedEvidenceFirstOtherwise(t *testing.T) {
	cases := []struct {
		name    string
		age     time.Duration
		request func(*production.PendingRequest)
		prepare func(*production.Registry, *production.Provider)
	}{
		{name: "gap_within_bound", age: 3 * time.Minute},
		{name: "hedge", age: 10 * time.Minute, request: func(pr *production.PendingRequest) { pr.Hedge = true }},
		{name: "require_fresh_feasible", age: 10 * time.Minute, request: func(pr *production.PendingRequest) {
			pr.RequireFreshFeasible = true
			pr.RequireFreshFeasibleAfter = time.Now().Add(-time.Second)
		}},
		{name: "pending_reservation", age: 10 * time.Minute, prepare: func(r *production.Registry, idle *production.Provider) {
			held := &production.PendingRequest{RequestID: "held", EstimatedPromptTokens: 100, RequestedMaxTokens: 16}
			held.Model = "explore"
			idle.AddPending(held)
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := newExplorationPair(t, "explore", tc.age, func(_ *production.Provider, history *measurements.History, _ time.Time) { history.Reset() })
			if tc.prepare != nil {
				tc.prepare(f.registry, f.idle)
			}
			pr := deadlineRequest()
			if tc.request != nil {
				tc.request(pr)
			}
			if selected, _ := f.registry.ReserveProviderEx("explore", pr); selected != f.qualified {
				t.Fatalf("selected=%v, want qualified evidence first", selected)
			}
		})
	}
}

func TestFirstContentEvidenceGapAge(t *testing.T) {
	now := time.Now()
	performanceAge := int32(1234)
	if got := forecast.EvidenceGapAgeMS(performanceAge, connectiontime.New(now.Add(-time.Hour)), now); got != 1234 {
		t.Fatalf("dated evidence: got %d, want its own age", got)
	}
	performanceAge = -1
	if got := forecast.EvidenceGapAgeMS(performanceAge, connectiontime.New(now.Add(-time.Minute)), now); got != 60_000 {
		t.Fatalf("undated evidence: got %d, want connection age", got)
	}
	if got := forecast.EvidenceGapAgeMS(performanceAge, connectiontime.New(time.Time{}), now); got != -1 {
		t.Fatalf("unknown connection time: got %d, want -1 (never explorable)", got)
	}
}

func TestFirstContentExplorationThreshold(t *testing.T) {
	threshold := int32(forecast.EvidenceExplorationAfter / time.Millisecond)
	for _, age := range []int32{-1, threshold - 1, threshold, threshold + 1} {
		estimate := forecast.Estimate{Status: forecast.Unknown, Reason: "performance_age_unknown_or_stale"}
		work := forecast.Workload{WholeMacKnown: true}
		if got, want := forecast.EvidenceExplorable(estimate, true, work, 0, age), age >= threshold; got != want {
			t.Errorf("age=%d: explorable=%v, want %v", age, got, want)
		}
	}
}
