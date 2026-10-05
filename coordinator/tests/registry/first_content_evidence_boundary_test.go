package registry_test

import (
	"math"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/capacityvalue"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/forecast"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/measurements"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/performance"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// These tables pin the exact edges of the evidence predicates that routing
// uses today. Each row is one side of one limit.

// TestFirstContentUnknownReasonBoundaries covers the capacity and
// performance freshness limits and the order in which reasons are reported.
func TestFirstContentUnknownReasonBoundaries(t *testing.T) {
	capacityLimit := int32(forecast.CapacityFreshness / time.Millisecond)
	performanceLimit := int32(forecast.PerformanceFreshness / time.Millisecond)
	for _, tc := range []struct {
		name   string
		change func(e *forecast.Evidence, r *forecast.Request)
		want   string
	}{
		{"qualified", func(*forecast.Evidence, *forecast.Request) {}, ""},
		{"no_capacity_report", func(e *forecast.Evidence, _ *forecast.Request) { e.Calibration.HasCapacity = false }, "capacity_missing"},
		{"capacity_age_unknown", func(e *forecast.Evidence, _ *forecast.Request) { e.Calibration.CapacityAgeMS = -1 }, "capacity_stale"},
		{"capacity_age_at_limit", func(e *forecast.Evidence, _ *forecast.Request) { e.Calibration.CapacityAgeMS = capacityLimit }, ""},
		{"capacity_age_past_limit", func(e *forecast.Evidence, _ *forecast.Request) {
			e.Calibration.CapacityAgeMS = capacityLimit + 1
		}, "capacity_stale"},
		{"capacity_equal_to_refusal", func(e *forecast.Evidence, r *forecast.Request) { r.FreshAfter = e.CapacityAcceptedAt }, "capacity_before_refusal"},
		{"capacity_after_refusal", func(e *forecast.Evidence, r *forecast.Request) {
			r.FreshAfter = e.CapacityAcceptedAt.Add(-time.Nanosecond)
		}, ""},
		{"performance_age_unknown", func(e *forecast.Evidence, _ *forecast.Request) {
			e.Calibration.PerformanceAgeMS = -1
		}, "performance_age_unknown_or_stale"},
		{"performance_age_at_limit", func(e *forecast.Evidence, _ *forecast.Request) {
			e.Calibration.PerformanceAgeMS = performanceLimit
		}, ""},
		{"performance_age_past_limit", func(e *forecast.Evidence, _ *forecast.Request) {
			e.Calibration.PerformanceAgeMS = performanceLimit + 1
		}, "performance_age_unknown_or_stale"},
		{"prefill_not_initialized", func(e *forecast.Evidence, _ *forecast.Request) {
			e.Calibration.IsolatedInitialized = false
		}, "performance_missing"},
		{"prefill_not_finite", func(e *forecast.Evidence, _ *forecast.Request) {
			e.Calibration.IsolatedPrefillTPS = math.Inf(1)
		}, "performance_missing"},
		{"decode_missing", func(e *forecast.Evidence, _ *forecast.Request) { e.ObservedDecodeTPS = 0 }, "performance_missing"},
		{"vision", func(_ *forecast.Evidence, r *forecast.Request) { r.Incoming.RequiresVision = true }, "vision_work_unknown"},
		{"model_not_loaded", func(e *forecast.Evidence, _ *forecast.Request) { e.Calibration.ModelLoaded = false }, "load_work_unknown"},
		{"work_unknown", func(e *forecast.Evidence, _ *forecast.Request) { e.Workload.WholeMacKnown = false }, "competing_work_unknown"},
		{"busy", func(e *forecast.Evidence, _ *forecast.Request) { e.Workload.WholeMacBusy = true }, "competing_work_unknown"},
		{"partial_prefill", func(e *forecast.Evidence, _ *forecast.Request) { e.Workload.PartialPrefillRows = 1 }, "competing_work_unknown"},
		{"prompt_zero", func(_ *forecast.Evidence, r *forecast.Request) { r.PromptTokens = 0 }, "prompt_unknown"},
		// The first failing check wins, so a stale report hides the rest.
		{"capacity_before_performance", func(e *forecast.Evidence, _ *forecast.Request) {
			e.Calibration.CapacityAgeMS, e.Calibration.PerformanceAgeMS, e.Workload.WholeMacBusy = capacityLimit+1, -1, true
		}, "capacity_stale"},
		{"performance_before_busy", func(e *forecast.Evidence, _ *forecast.Request) {
			e.Calibration.PerformanceAgeMS, e.Workload.WholeMacBusy = performanceLimit+1, true
		}, "performance_age_unknown_or_stale"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := measuredFirstContentEvidence(time.Now())
			r := forecast.Request{PromptTokens: 1000}
			tc.change(&e, &r)
			if got := forecast.UnknownReason(&e, r, false, false); got != tc.want {
				t.Fatalf("reason = %q, want %q", got, tc.want)
			}
		})
	}
	// A quote may refresh request-specific refusal evidence, so the refusal
	// cutoff is the one check that a caller can skip.
	e := measuredFirstContentEvidence(time.Now())
	r := forecast.Request{PromptTokens: 1000, FreshAfter: e.CapacityAcceptedAt}
	if got := forecast.UnknownReason(&e, r, false, true); got != "" {
		t.Fatalf("ignored refusal cutoff still reported %q", got)
	}
}

// TestFirstContentStatusAtBudgetBoundary checks that a conservative forecast
// equal to the budget is feasible and one just over it is predicted late.
func TestFirstContentStatusAtBudgetBoundary(t *testing.T) {
	now := time.Now()
	evaluate := func(r forecast.Request) forecast.Estimate {
		e := measuredFirstContentEvidence(now)
		r.PromptTokens, r.UpperBoundTokens = 1000, 1000
		return forecast.Evaluate(&e, r, now).Estimate
	}
	conservative := evaluate(forecast.Request{MaxTTFTMS: 1e9}).ConservativeMs
	for _, tc := range []struct {
		budget float64
		want   string
	}{
		{conservative, forecast.Feasible},
		{math.Nextafter(conservative, 0), forecast.PredictedLate},
	} {
		if got := evaluate(forecast.Request{MaxTTFTMS: tc.budget}); got.Status != tc.want {
			t.Fatalf("budget %v for conservative %v: status %s, want %s", tc.budget, conservative, got.Status, tc.want)
		}
	}
	// Without a deadline, a MaxTTFTMs ceiling, or a hedge planning horizon,
	// evidence can rank but can never establish feasibility.
	if got := evaluate(forecast.Request{}); got.Status != forecast.Unknown || got.Reason != "no_deadline" {
		t.Fatalf("request without a deadline: %+v", got)
	}
	// A deadline that has already passed leaves a zero budget.
	if got := evaluate(forecast.Request{Deadline: now.Add(-time.Second)}); got.BudgetMs != 0 || got.Status != forecast.PredictedLate {
		t.Fatalf("expired deadline: %+v", got)
	}
}

// TestFirstContentCandidateAllowedTable covers every branch of the gate that
// keeps a candidate in the scan. Routing passes occupied when the whole Mac
// is busy or the provider holds a pending reservation;
// TestFirstContentHedgeSkipsProviderWithPendingReservation covers that input
// through the scheduler.
func TestFirstContentCandidateAllowedTable(t *testing.T) {
	for _, tc := range []struct {
		name     string
		status   string
		occupied bool
		request  func(*forecast.Request)
		want     bool
	}{
		{"ordinary_unknown", forecast.Unknown, false, nil, true},
		{"ordinary_late_without_ceiling", forecast.PredictedLate, false, nil, true},
		{"ceiling_late", forecast.PredictedLate, false, func(r *forecast.Request) { r.MaxTTFTMS = 1 }, false},
		{"ceiling_unknown", forecast.Unknown, false, func(r *forecast.Request) { r.MaxTTFTMS = 1 }, true},
		{"ceiling_feasible", forecast.Feasible, false, func(r *forecast.Request) { r.MaxTTFTMS = 1 }, true},
		{"fresh_feasible_required_feasible", forecast.Feasible, false, func(r *forecast.Request) { r.RequireFreshFeasible = true }, true},
		{"fresh_feasible_required_unknown", forecast.Unknown, false, func(r *forecast.Request) { r.RequireFreshFeasible = true }, false},
		{"fresh_feasible_required_late", forecast.PredictedLate, false, func(r *forecast.Request) { r.RequireFreshFeasible = true }, false},
		{"hedge_idle_feasible", forecast.Feasible, false, func(r *forecast.Request) { r.Hedge = true }, true},
		{"hedge_idle_unknown", forecast.Unknown, false, func(r *forecast.Request) { r.Hedge = true }, false},
		{"hedge_occupied_feasible", forecast.Feasible, true, func(r *forecast.Request) { r.Hedge = true }, false},
		{"occupied_ordinary", forecast.Unknown, true, nil, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := forecast.Request{}
			if tc.request != nil {
				tc.request(&r)
			}
			if got := forecast.Allows(forecast.Estimate{Status: tc.status}, r, tc.occupied); got != tc.want {
				t.Fatalf("allowed = %v, want %v", got, tc.want)
			}
		})
	}
}

// TestFirstContentHedgeSkipsProviderWithPendingReservation checks that a
// pending reservation occupies the provider for a hedge, while an ordinary
// request still reaches it.
func TestFirstContentHedgeSkipsProviderWithPendingReservation(t *testing.T) {
	f := newObservedForecastFixture(t, "provider", "model", 100)
	f.fresh(2000)
	request := func(id string, hedge bool) *production.PendingRequest {
		return &production.PendingRequest{RequestID: id, Model: "model", EstimatedPromptTokens: 1000,
			RequestedMaxTokens: 128, FirstContentDeadline: time.Now().Add(10 * time.Second), Hedge: hedge}
	}
	idleHedge := request("idle-hedge", true)
	if selected, decision := f.r.ReserveProviderEx("model", idleHedge); selected != f.p {
		t.Fatalf("idle feasible provider refused a hedge: %+v", decision.FirstContent)
	}
	f.p.RemovePending(idleHedge.RequestID)
	held := &production.PendingRequest{RequestID: "held", Model: "model", EstimatedPromptTokens: 100, RequestedMaxTokens: 16}
	f.p.AddPending(held)
	defer f.p.RemovePending(held.RequestID)
	if selected, _ := f.r.ReserveProviderEx("model", request("occupied-hedge", true)); selected != nil {
		t.Fatal("a hedge reserved a provider that holds a pending reservation")
	}
	ordinary := request("ordinary", false)
	if selected, decision := f.r.ReserveProviderEx("model", ordinary); selected != f.p {
		t.Fatalf("a pending reservation refused an ordinary request: %+v", decision.FirstContent)
	}
	f.p.RemovePending(ordinary.RequestID)
}

// TestExplicitMeasurementTimeBoundaries covers the validity limits and the
// same-epoch rules that date an explicit performance observation.
func TestExplicitMeasurementTimeBoundaries(t *testing.T) {
	now := time.Unix(2_000_000, 0)
	handoff := time.Duration(forecast.ConservativeHandoffMS) * time.Millisecond
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
		{"age_at_limit", obs(100, 1, capacityvalue.MaxPerformanceSampleAgeMS), 0, 0, time.Time{}, false,
			now.Add(-time.Duration(capacityvalue.MaxPerformanceSampleAgeMS)*time.Millisecond - handoff), 1},
		{"age_past_limit", obs(100, 1, capacityvalue.MaxPerformanceSampleAgeMS+1), 0, 0, time.Time{}, false, time.Time{}, 0},
		{"rate_at_limit", obs(capacityvalue.MaxPrefillTPS, 1, 0), 0, 0, time.Time{}, false, now.Add(-handoff), 1},
		{"rate_past_limit", obs(math.Nextafter(capacityvalue.MaxPrefillTPS, math.Inf(1)), 1, 0), 0, 0, time.Time{}, false, time.Time{}, 0},
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
			history := &measurements.History{}
			if tc.oldCount > 0 {
				epoch := "previous-engine"
				if tc.sameEpoch {
					epoch = "engine"
				}
				seedExplicitPrefillSample(t, history, epoch, tc.oldCount, tc.oldRate, tc.oldAt, handoff)
			}
			history.Reconcile(explicitPrefillCapacity("engine", tc.o), time.Time{}, now, handoff)
			sample, _ := history.Lookup("model")
			if !sample.ObservedAfter.Equal(tc.wantAt) || sample.PrefillCount != tc.wantCount {
				t.Fatalf("got (%v, %d), want (%v, %d)", sample.ObservedAfter, sample.PrefillCount, tc.wantAt, tc.wantCount)
			}
		})
	}
}

func explicitPrefillCapacity(epoch string, o *protocol.PerformanceRateObservation) *protocol.BackendCapacity {
	return &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{{Model: "model", State: "idle",
		Telemetry: &protocol.SlotTelemetry{}, PerformanceMeasurements: &protocol.PerformanceMeasurements{Epoch: epoch, IsolatedPrefill: o}}}}
}

// seedExplicitPrefillSample leaves history holding one prefill sample with
// the given count, rate and time. An undated sample is made the way a
// provider makes one: a same-epoch report whose count regressed.
func seedExplicitPrefillSample(t *testing.T, history *measurements.History, epoch string, count int64, rate float64, at time.Time, handoff time.Duration) {
	t.Helper()
	observation := &protocol.PerformanceRateObservation{TokensPerSecond: rate, SampleCount: count}
	if at.IsZero() {
		reportedAt := time.Unix(1_000_000, 0)
		history.Reconcile(explicitPrefillCapacity(epoch, observation), time.Time{}, reportedAt, handoff)
		regressed := *observation
		regressed.SampleCount--
		history.Reconcile(explicitPrefillCapacity(epoch, &regressed), time.Time{}, reportedAt, handoff)
	} else {
		history.Reconcile(explicitPrefillCapacity(epoch, observation), time.Time{}, at.Add(handoff), handoff)
	}
	sample, _ := history.Lookup("model")
	if sample.Epoch != epoch || sample.PrefillCount != count || sample.Rate != rate || !sample.ObservedAfter.Equal(at) {
		t.Fatalf("seeded sample %+v, want epoch %s count %d rate %v at %v", sample, epoch, count, rate, at)
	}
}

// TestResolveEffectiveTPSPrecedence pins the decode-rate fallback chain for
// providers without a qualified performance profile.
//
// After #1243 merges, this table needs a stale-idle row: an idle, loaded
// provider with an observed decode rate of 40 whose decode measurement is
// 30 min + 1 ms old, and a fleet median of 60, gives 60. The row is not here
// yet because the decode measurement age does not exist on master.
func TestResolveEffectiveTPSPrecedence(t *testing.T) {
	for _, tc := range []struct {
		name  string
		rates performance.Rates
		want  float64
	}{
		{"observed_first", performance.Rates{ObservedDecode: 40, FleetMedian: 60, StaticDecode: 80}, 40},
		{"fleet_median_without_observation", performance.Rates{FleetMedian: 60, StaticDecode: 80}, 60},
		{"negative_observation_ignored", performance.Rates{ObservedDecode: -5, FleetMedian: 60, StaticDecode: 80}, 60},
		{"static_without_median", performance.Rates{StaticDecode: 80}, 80},
		{"static_derated_by_running", performance.Rates{StaticDecode: 80, ObservedBatch: 2, Occupancy: 2},
			80 / (1 + warmplan.DecodeLoadFactor*2)},
		{"derated_rate_floored", performance.Rates{StaticDecode: 2, ObservedBatch: 100, Occupancy: 100}, 1},
		{"no_rate_at_all", performance.Rates{}, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := tc.rates.EffectiveDecode(warmplan.DecodeLoadFactor); math.Abs(got-tc.want) > 1e-9 {
				t.Fatalf("EffectiveDecode = %v, want %v", got, tc.want)
			}
		})
	}
}

// TestResolvePrefillTPSPrecedence pins the prefill-rate fallback chain and
// its bounds.
func TestResolvePrefillTPSPrecedence(t *testing.T) {
	for _, tc := range []struct {
		name  string
		rates performance.Rates
		want  float64
	}{
		{"observed_first", performance.Rates{ObservedPrefill: 900, StaticPrefill: 600}, 900},
		{"static_without_observation", performance.Rates{StaticPrefill: 600}, 600},
		{"observation_not_finite", performance.Rates{ObservedPrefill: math.Inf(1), StaticPrefill: 600}, 600},
		{"observation_capped", performance.Rates{ObservedPrefill: capacityvalue.MaxPrefillTPS * 2}, capacityvalue.MaxPrefillTPS},
		{"static_capped", performance.Rates{StaticPrefill: capacityvalue.MaxPrefillTPS + 1}, capacityvalue.MaxPrefillTPS},
		{"no_rate_at_all", performance.Rates{}, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := tc.rates.Prefill(); got != tc.want {
				t.Fatalf("Prefill = %v, want %v", got, tc.want)
			}
		})
	}
}
