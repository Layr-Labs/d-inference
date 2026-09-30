package registry

import (
	"math"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// These tables pin the exact edges of the evidence predicates that routing
// uses today. Each row is one side of one limit.

// TestFirstContentUnknownReasonBoundaries covers the capacity and
// performance freshness limits and the order in which reasons are reported.
func TestFirstContentUnknownReasonBoundaries(t *testing.T) {
	capacityLimit := int32(firstContentFreshness / time.Millisecond)
	performanceLimit := int32(firstContentPerformanceFreshness / time.Millisecond)
	for _, tc := range []struct {
		name   string
		change func(s *routingSnapshot, pr *PendingRequest, prompt *int)
		want   string
	}{
		{"qualified", func(*routingSnapshot, *PendingRequest, *int) {}, ""},
		{"no_capacity_report", func(s *routingSnapshot, _ *PendingRequest, _ *int) { s.hasBackendCapacity = false }, "capacity_missing"},
		{"capacity_age_unknown", func(s *routingSnapshot, _ *PendingRequest, _ *int) { s.capacityAgeMs = -1 }, "capacity_stale"},
		{"capacity_age_at_limit", func(s *routingSnapshot, _ *PendingRequest, _ *int) { s.capacityAgeMs = capacityLimit }, ""},
		{"capacity_age_past_limit", func(s *routingSnapshot, _ *PendingRequest, _ *int) { s.capacityAgeMs = capacityLimit + 1 }, "capacity_stale"},
		{"capacity_equal_to_refusal", func(s *routingSnapshot, pr *PendingRequest, _ *int) {
			pr.RequireFreshFeasibleAfter = s.capacityAcceptedAt
		}, "capacity_before_refusal"},
		{"capacity_after_refusal", func(s *routingSnapshot, pr *PendingRequest, _ *int) {
			pr.RequireFreshFeasibleAfter = s.capacityAcceptedAt.Add(-time.Nanosecond)
		}, ""},
		{"performance_age_unknown", func(s *routingSnapshot, _ *PendingRequest, _ *int) { s.performanceAgeMs = -1 }, "performance_age_unknown_or_stale"},
		{"performance_age_at_limit", func(s *routingSnapshot, _ *PendingRequest, _ *int) { s.performanceAgeMs = performanceLimit }, ""},
		{"performance_age_past_limit", func(s *routingSnapshot, _ *PendingRequest, _ *int) {
			s.performanceAgeMs = performanceLimit + 1
		}, "performance_age_unknown_or_stale"},
		{"prefill_not_initialized", func(s *routingSnapshot, _ *PendingRequest, _ *int) { s.isolatedPrefillInitialized = false }, "performance_missing"},
		{"prefill_not_finite", func(s *routingSnapshot, _ *PendingRequest, _ *int) { s.isolatedPrefillTPS = math.Inf(1) }, "performance_missing"},
		{"decode_missing", func(s *routingSnapshot, _ *PendingRequest, _ *int) { s.observedDecodeTPS = 0 }, "performance_missing"},
		{"vision", func(_ *routingSnapshot, pr *PendingRequest, _ *int) { pr.RequiresVision = true }, "vision_work_unknown"},
		{"model_not_loaded", func(s *routingSnapshot, _ *PendingRequest, _ *int) { s.modelLoaded = false }, "load_work_unknown"},
		{"work_unknown", func(s *routingSnapshot, _ *PendingRequest, _ *int) { s.wholeMacWorkKnown = false }, "competing_work_unknown"},
		{"busy", func(s *routingSnapshot, _ *PendingRequest, _ *int) { s.wholeMacBusy = true }, "competing_work_unknown"},
		{"partial_prefill", func(s *routingSnapshot, _ *PendingRequest, _ *int) { s.partialPrefillRows = 1 }, "competing_work_unknown"},
		{"prompt_zero", func(_ *routingSnapshot, _ *PendingRequest, prompt *int) { *prompt = 0 }, "prompt_unknown"},
		// The first failing check wins, so a stale report hides the rest.
		{"capacity_before_performance", func(s *routingSnapshot, _ *PendingRequest, _ *int) {
			s.capacityAgeMs, s.performanceAgeMs, s.wholeMacBusy = capacityLimit+1, -1, true
		}, "capacity_stale"},
		{"performance_before_busy", func(s *routingSnapshot, _ *PendingRequest, _ *int) {
			s.performanceAgeMs, s.wholeMacBusy = performanceLimit+1, true
		}, "performance_age_unknown_or_stale"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := measuredFirstContentCandidate(time.Now())
			pr := &PendingRequest{}
			prompt := 1000
			tc.change(&c.snapshot, pr, &prompt)
			if got := firstContentForecastUnknownReason(&c.snapshot, pr, prompt, false); got != tc.want {
				t.Fatalf("reason = %q, want %q", got, tc.want)
			}
		})
	}
	// A quote may refresh request-specific refusal evidence, so the refusal
	// cutoff is the one check that a caller can skip.
	c := measuredFirstContentCandidate(time.Now())
	pr := &PendingRequest{RequireFreshFeasibleAfter: c.snapshot.capacityAcceptedAt}
	if got := firstContentForecastUnknownReason(&c.snapshot, pr, 1000, true); got != "" {
		t.Fatalf("ignored refusal cutoff still reported %q", got)
	}
}

// TestFirstContentStatusAtBudgetBoundary checks that a conservative forecast
// equal to the budget is feasible and one just over it is predicted late.
func TestFirstContentStatusAtBudgetBoundary(t *testing.T) {
	now := time.Now()
	r := New(testLogger())
	probe := measuredFirstContentCandidate(now)
	r.estimateFirstContent(probe, &PendingRequest{EstimatedPromptTokens: 1000, MaxTTFTMs: 1e9}, now)
	conservative := probe.firstContent.ConservativeMs
	for _, tc := range []struct {
		budget float64
		want   string
	}{
		{conservative, FirstContentFeasible},
		{math.Nextafter(conservative, 0), FirstContentPredictedLate},
	} {
		c := measuredFirstContentCandidate(now)
		r.estimateFirstContent(c, &PendingRequest{EstimatedPromptTokens: 1000, MaxTTFTMs: tc.budget}, now)
		if c.firstContent.Status != tc.want {
			t.Fatalf("budget %v for conservative %v: status %s, want %s", tc.budget, conservative, c.firstContent.Status, tc.want)
		}
	}
	// Without a deadline, a MaxTTFTMs ceiling, or a hedge planning horizon,
	// evidence can rank but can never establish feasibility.
	c := measuredFirstContentCandidate(now)
	r.estimateFirstContent(c, &PendingRequest{EstimatedPromptTokens: 1000}, now)
	if c.firstContent.Status != FirstContentUnknown || c.firstContent.Reason != "no_deadline" {
		t.Fatalf("request without a deadline: %+v", c.firstContent)
	}
	// A deadline that has already passed leaves a zero budget.
	c = measuredFirstContentCandidate(now)
	r.estimateFirstContent(c, &PendingRequest{EstimatedPromptTokens: 1000, FirstContentDeadline: now.Add(-time.Second)}, now)
	if c.firstContent.BudgetMs != 0 || c.firstContent.Status != FirstContentPredictedLate {
		t.Fatalf("expired deadline: %+v", c.firstContent)
	}
}

// TestFirstContentCandidateAllowedTable covers every branch of the gate that
// keeps a candidate in the scan.
func TestFirstContentCandidateAllowedTable(t *testing.T) {
	for _, tc := range []struct {
		name    string
		status  string
		busy    bool
		pending int
		request func(*PendingRequest)
		want    bool
	}{
		{"ordinary_unknown", FirstContentUnknown, false, 0, nil, true},
		{"ordinary_late_without_ceiling", FirstContentPredictedLate, false, 0, nil, true},
		{"ceiling_late", FirstContentPredictedLate, false, 0, func(pr *PendingRequest) { pr.MaxTTFTMs = 1 }, false},
		{"ceiling_unknown", FirstContentUnknown, false, 0, func(pr *PendingRequest) { pr.MaxTTFTMs = 1 }, true},
		{"ceiling_feasible", FirstContentFeasible, false, 0, func(pr *PendingRequest) { pr.MaxTTFTMs = 1 }, true},
		{"fresh_feasible_required_feasible", FirstContentFeasible, false, 0, func(pr *PendingRequest) { pr.RequireFreshFeasible = true }, true},
		{"fresh_feasible_required_unknown", FirstContentUnknown, false, 0, func(pr *PendingRequest) { pr.RequireFreshFeasible = true }, false},
		{"fresh_feasible_required_late", FirstContentPredictedLate, false, 0, func(pr *PendingRequest) { pr.RequireFreshFeasible = true }, false},
		{"hedge_idle_feasible", FirstContentFeasible, false, 0, func(pr *PendingRequest) { pr.Hedge = true }, true},
		{"hedge_idle_unknown", FirstContentUnknown, false, 0, func(pr *PendingRequest) { pr.Hedge = true }, false},
		{"hedge_busy_feasible", FirstContentFeasible, true, 0, func(pr *PendingRequest) { pr.Hedge = true }, false},
		{"hedge_pending_feasible", FirstContentFeasible, false, 1, func(pr *PendingRequest) { pr.Hedge = true }, false},
		{"busy_ordinary", FirstContentUnknown, true, 1, nil, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := &routingCandidate{firstContent: FirstContentEstimate{Status: tc.status}}
			c.snapshot.wholeMacBusy, c.snapshot.totalPending = tc.busy, tc.pending
			pr := &PendingRequest{}
			if tc.request != nil {
				tc.request(pr)
			}
			if got := firstContentCandidateAllowed(c, pr); got != tc.want {
				t.Fatalf("allowed = %v, want %v", got, tc.want)
			}
		})
	}
}

// TestExplicitMeasurementTimeBoundaries covers the validity limits and the
// same-epoch rules that date an explicit performance observation.
func TestExplicitMeasurementTimeBoundaries(t *testing.T) {
	now := time.Unix(2_000_000, 0)
	handoff := time.Duration(firstContentConservativeHandoffMs) * time.Millisecond
	obs := func(rate float64, count, ageMS int64) *protocol.PerformanceRateObservation {
		return &protocol.PerformanceRateObservation{TokensPerSecond: rate, SampleCount: count, SampleAgeMS: ageMS}
	}
	older := now.Add(-time.Hour)
	for _, tc := range []struct {
		name      string
		o         *protocol.PerformanceRateObservation
		oldCount  int64
		oldRate   float64
		oldAt     time.Time
		sameEpoch bool
		wantAt    time.Time
		wantCount int64
	}{
		{"missing", nil, 0, 0, time.Time{}, false, time.Time{}, 0},
		{"zero_count", obs(100, 0, 0), 0, 0, time.Time{}, false, time.Time{}, 0},
		{"negative_age", obs(100, 1, -1), 0, 0, time.Time{}, false, time.Time{}, 0},
		{"age_at_limit", obs(100, 1, maxPerformanceSampleAgeMS), 0, 0, time.Time{}, false,
			now.Add(-time.Duration(maxPerformanceSampleAgeMS)*time.Millisecond - handoff), 1},
		{"age_past_limit", obs(100, 1, maxPerformanceSampleAgeMS+1), 0, 0, time.Time{}, false, time.Time{}, 0},
		{"rate_at_limit", obs(maxPrefillTPS, 1, 0), 0, 0, time.Time{}, false, now.Add(-handoff), 1},
		{"rate_past_limit", obs(math.Nextafter(maxPrefillTPS, math.Inf(1)), 1, 0), 0, 0, time.Time{}, false, time.Time{}, 0},
		{"rate_not_finite", obs(math.NaN(), 1, 0), 0, 0, time.Time{}, false, time.Time{}, 0},
		{"new_epoch_ignores_history", obs(100, 1, 1000), 50, 90, older, false, now.Add(-time.Second - handoff), 1},
		{"same_epoch_new_sample", obs(100, 6, 1000), 5, 90, older, true, now.Add(-time.Second - handoff), 6},
		{"same_epoch_count_regressed", obs(100, 4, 0), 5, 100, older, true, time.Time{}, 5},
		{"same_epoch_rate_changed_without_sample", obs(101, 5, 0), 5, 100, older, true, time.Time{}, 5},
		{"same_epoch_unchanged_keeps_older_time", obs(100, 5, 0), 5, 100, older, true, older, 5},
		{"same_epoch_unchanged_undated_stays_undated", obs(100, 5, 0), 5, 100, time.Time{}, true, time.Time{}, 5},
		{"same_epoch_unchanged_takes_older_reported_age", obs(100, 5, 7_200_000), 5, 100, older.Add(time.Minute), true,
			now.Add(-2*time.Hour - handoff), 5},
	} {
		t.Run(tc.name, func(t *testing.T) {
			at, count := explicitMeasurementTime(tc.o, tc.oldCount, tc.oldRate, tc.oldAt, now, tc.sameEpoch)
			if !at.Equal(tc.wantAt) || count != tc.wantCount {
				t.Fatalf("got (%v, %d), want (%v, %d)", at, count, tc.wantAt, tc.wantCount)
			}
		})
	}
}

// TestResolveEffectiveTPSPrecedence pins the decode-rate fallback chain for
// providers without a qualified performance profile.
func TestResolveEffectiveTPSPrecedence(t *testing.T) {
	for _, tc := range []struct {
		name string
		snap routingSnapshot
		want float64
	}{
		{"observed_first", routingSnapshot{observedDecodeTPS: 40, fleetMedianTPS: 60, decodeTPS: 80}, 40},
		{"fleet_median_without_observation", routingSnapshot{fleetMedianTPS: 60, decodeTPS: 80}, 60},
		{"negative_observation_ignored", routingSnapshot{observedDecodeTPS: -5, fleetMedianTPS: 60, decodeTPS: 80}, 60},
		{"static_without_median", routingSnapshot{decodeTPS: 80}, 80},
		{"static_derated_by_running", routingSnapshot{decodeTPS: 80, backendRunning: 2}, 80 / (1 + effectiveTPSLoadFactor*2)},
		{"derated_rate_floored", routingSnapshot{decodeTPS: 2, backendRunning: 100}, 1},
		{"no_rate_at_all", routingSnapshot{}, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := resolveEffectiveTPS(&tc.snap); math.Abs(got-tc.want) > 1e-9 {
				t.Fatalf("resolveEffectiveTPS = %v, want %v", got, tc.want)
			}
		})
	}
}

// TestResolvePrefillTPSPrecedence pins the prefill-rate fallback chain and
// its bounds.
func TestResolvePrefillTPSPrecedence(t *testing.T) {
	for _, tc := range []struct {
		name string
		snap routingSnapshot
		want float64
	}{
		{"observed_first", routingSnapshot{observedPrefillTPS: 900, prefillTPS: 600}, 900},
		{"static_without_observation", routingSnapshot{prefillTPS: 600}, 600},
		{"observation_not_finite", routingSnapshot{observedPrefillTPS: math.Inf(1), prefillTPS: 600}, 600},
		{"observation_capped", routingSnapshot{observedPrefillTPS: maxPrefillTPS * 2}, maxPrefillTPS},
		{"static_capped", routingSnapshot{prefillTPS: maxPrefillTPS + 1}, maxPrefillTPS},
		{"no_rate_at_all", routingSnapshot{}, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := resolvePrefillTPS(&tc.snap); got != tc.want {
				t.Fatalf("resolvePrefillTPS = %v, want %v", got, tc.want)
			}
		})
	}
}
