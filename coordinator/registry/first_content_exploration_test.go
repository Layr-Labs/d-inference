package registry

import (
	"testing"
	"time"
)

// explorationPair registers a provider with current qualified evidence and a
// faster idle provider on the same model whose evidence is shaped by gap.
func explorationPair(t *testing.T, r *Registry, model string, gap func(p *Provider, now time.Time)) (qualified, idle *Provider) {
	t.Helper()
	qualified = planTestProvider(t, r, "qualified", model, 0)
	idle = planTestProvider(t, r, "idle", model, 0)
	now := time.Now()
	idle.mu.Lock()
	// Faster than the qualified peer's measured 1,200 tok/s by more than the
	// 100 ms fast band on these prompts, so it wins whenever it may compete,
	// yet within the range real providers measure. A provider priced by the
	// registration fallback (no rates reported) may not rank at all; that is
	// a cost question outside exploration eligibility (#1238).
	idle.PrefillTPS = 2_000
	gap(idle, now)
	idle.mu.Unlock()
	return qualified, idle
}

func deadlineRequest() *PendingRequest {
	pr := planTestRequest("request", 500, 128)
	pr.FirstContentDeadline = time.Now().Add(10 * time.Second)
	return pr
}

// A provider that has never been selected since it connected has no evidence,
// and qualified-evidence-first meant it could never get the request that would
// produce some. Past the exploration bound it competes on ranking.
func TestFirstContentIdleProviderWithoutEvidenceIsExploredAfterBound(t *testing.T) {
	cases := []struct {
		name string
		gap  func(p *Provider, now time.Time)
	}{
		{"never_measured", func(p *Provider, now time.Time) {
			p.firstContentMeasurements = nil
			p.registeredAt = now.Add(-10 * time.Minute)
		}},
		{"measured_then_idle", func(p *Provider, now time.Time) {
			old := now.Add(-10 * time.Minute)
			p.firstContentMeasurements = map[string]firstContentMeasurement{
				"explore": {rate: 20_000, observedAfter: old, decodeObservedAfter: old}}
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			r := New(testLogger())
			_, idle := explorationPair(t, r, "explore", tc.gap)
			if selected, _ := r.ReserveProviderEx("explore", deadlineRequest()); selected != idle {
				t.Fatalf("selected=%v, want the idle provider explored past the bound", selected)
			}
		})
	}
}

// Everything the bound must not change: a short gap, a provider with pending
// work, and requests that require fresh feasible evidence keep qualified first.
func TestFirstContentExplorationKeepsQualifiedEvidenceFirstOtherwise(t *testing.T) {
	recent := func(p *Provider, now time.Time) {
		p.firstContentMeasurements = nil
		p.registeredAt = now.Add(-3 * time.Minute)
	}
	longIdle := func(p *Provider, now time.Time) {
		p.firstContentMeasurements = nil
		p.registeredAt = now.Add(-10 * time.Minute)
	}
	cases := []struct {
		name    string
		gap     func(p *Provider, now time.Time)
		request func(pr *PendingRequest)
		prepare func(r *Registry, idle *Provider)
	}{
		{name: "gap_within_bound", gap: recent},
		{name: "hedge", gap: longIdle, request: func(pr *PendingRequest) { pr.Hedge = true }},
		{name: "require_fresh_feasible", gap: longIdle, request: func(pr *PendingRequest) {
			pr.RequireFreshFeasible = true
			pr.RequireFreshFeasibleAfter = time.Now().Add(-time.Second)
		}},
		{name: "pending_reservation", gap: longIdle, prepare: func(r *Registry, idle *Provider) {
			held := planTestRequest("held", 100, 16)
			held.Model = "explore"
			idle.mu.Lock()
			idle.pendingReqs[held.RequestID] = held
			idle.mu.Unlock()
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			r := New(testLogger())
			qualified, idle := explorationPair(t, r, "explore", tc.gap)
			if tc.prepare != nil {
				tc.prepare(r, idle)
			}
			pr := deadlineRequest()
			if tc.request != nil {
				tc.request(pr)
			}
			if selected, _ := r.ReserveProviderEx("explore", pr); selected != qualified {
				t.Fatalf("selected=%v, want qualified evidence first", selected)
			}
		})
	}
}

func TestFirstContentEvidenceGapAge(t *testing.T) {
	now := time.Now()
	s := &routingSnapshot{}
	s.performanceAgeMs = 1234
	if got := firstContentEvidenceGapAgeMs(s, now.Add(-time.Hour), now); got != 1234 {
		t.Fatalf("dated evidence: got %d, want its own age", got)
	}
	s.performanceAgeMs = -1
	if got := firstContentEvidenceGapAgeMs(s, now.Add(-time.Minute), now); got != 60_000 {
		t.Fatalf("undated evidence: got %d, want connection age", got)
	}
	if got := firstContentEvidenceGapAgeMs(s, time.Time{}, now); got != -1 {
		t.Fatalf("unknown connection time: got %d, want -1 (never explorable)", got)
	}
}

func TestFirstContentExplorationThreshold(t *testing.T) {
	threshold := int32(firstContentEvidenceExplorationAfter / time.Millisecond)
	for _, age := range []int32{-1, threshold - 1, threshold, threshold + 1} {
		c := &routingCandidate{
			firstContent: FirstContentEstimate{Status: FirstContentUnknown, Reason: "performance_age_unknown_or_stale"},
			snapshot: routingSnapshot{modelLoaded: true, firstContentSnapshot: firstContentSnapshot{
				wholeMacWorkKnown: true, evidenceGapAgeMs: age,
			}},
		}
		if got, want := firstContentEvidenceExplorable(c), age >= threshold; got != want {
			t.Errorf("age=%d: explorable=%v, want %v", age, got, want)
		}
	}
}
