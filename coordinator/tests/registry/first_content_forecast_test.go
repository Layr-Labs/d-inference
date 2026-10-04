package registry_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/forecast"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/performance"
	"github.com/eigeninference/d-inference/coordinator/protocol"

	"math"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/capacityvalue"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/measurements"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestFirstContentUsesMeasuredPrefillAboveOldCeiling(t *testing.T) {
	r := production.New(testLogger())
	for _, tc := range []struct {
		id   string
		rate float64
	}{{"slower", 5000}, {"fast", 12000}} {
		p := makeSchedulerProvider(t, r, tc.id, "model", 100)
		bc := p.BackendCapacitySnapshot()
		bc.CapacitySeq = 1
		bc.Slots[0].ObservedPrefillTPS = tc.rate
		if !r.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: bc}) {
			t.Fatal("heartbeat rejected")
		}
		if got := p.BackendCapacitySnapshot().Slots[0].ObservedPrefillTPS; got != tc.rate {
			t.Fatalf("lost plausible prefill rate %v", got)
		}
	}
	pr := &production.PendingRequest{RequestID: "request", Model: "model", EstimatedPromptTokens: 8000, RequestedMaxTokens: 100000}
	p, d := r.ReserveProviderEx("model", pr)
	if p == nil || p.ID != "fast" {
		t.Fatalf("fast measured prefill should win: %+v", d)
	}
	p.RemovePending(pr.RequestID)
	for _, rate := range []float64{math.NaN(), math.Inf(1), -1, 20001} {
		bc := &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{{ObservedPrefillTPS: rate, Telemetry: &protocol.SlotTelemetry{IsolatedPrefillTPS: &rate}}}}
		capacityvalue.ClampBackendCapacity(testLogger(), "invalid", bc)
		if bc.Slots[0].ObservedPrefillTPS != 0 || bc.Slots[0].Telemetry.IsolatedPrefillTPS != nil {
			t.Fatal("invalid rate became evidence")
		}
	}
}

func TestFirstContentForecastConfidenceAndCacheBeforeDeadline(t *testing.T) {
	now := time.Now()
	pr := forecast.Request{PromptTokens: 4000, UpperBoundTokens: 4000,
		Incoming: performance.IncomingWork{RequestedMaxTokens: 128}, Deadline: now.Add(3 * time.Second)}
	measured := func() forecast.Evidence {
		return forecast.Evidence{Calibration: performance.CalibrationEvidence{
			HasCapacity: true, ModelLoaded: true, IsolatedPrefillTPS: 2000, IsolatedInitialized: true,
		}, CapacityAcceptedAt: now, PrefillTPS: 2000, DecodeTPS: 100, ObservedDecodeTPS: 100,
			Workload: forecast.Workload{WholeMacKnown: true}}
	}
	c := measured()
	estimate := forecast.Evaluate(c, pr, now).Estimate
	if estimate.Status != forecast.PredictedLate || estimate.ExpectedMs >= estimate.ConservativeMs {
		t.Fatalf("need distinct expected/late conservative prediction: %+v", estimate)
	}
	benefit := forecast.CacheBenefit{Tokens: 9000, Weight: 1, RestoreMS: 80, ExpiresAt: now.Add(time.Minute)}
	cachedRequest := pr
	benefit.Apply(&cachedRequest, now)
	estimate = forecast.Evaluate(c, cachedRequest, now).Estimate
	if estimate.Status != forecast.Feasible || estimate.CachedTokens != 4000 || estimate.RestoreMs != 80 {
		t.Fatalf("cache should fit deadline, bound reuse, and charge restore once: %+v", estimate)
	}
	benefit.ExpiresAt = now
	cachedRequest = pr
	benefit.Apply(&cachedRequest, now)
	estimate = forecast.Evaluate(c, cachedRequest, now).Estimate
	if estimate.Status != forecast.PredictedLate || estimate.CachedTokens != 0 {
		t.Fatal("expired proof retained credit")
	}
	for _, tc := range []struct {
		name   string
		change func(*forecast.Evidence)
	}{
		{"capacity_stale", func(c *forecast.Evidence) { c.Calibration.CapacityAgeMS = 6000 }},
		{"missing_performance_age", func(c *forecast.Evidence) { c.Calibration.PerformanceAgeMS = -1 }},
		{"performance_stale", func(c *forecast.Evidence) { c.Calibration.PerformanceAgeMS = 180000 }},
		{"busy", func(c *forecast.Evidence) { c.Workload.WholeMacBusy = true }},
		{"missing_work", func(c *forecast.Evidence) { c.Workload.WholeMacKnown = false }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := measured()
			tc.change(&c)
			estimate := forecast.Evaluate(c, pr, now).Estimate
			if estimate.Status != forecast.Unknown || estimate.ExpectedMs <= 0 {
				t.Fatalf("unknown must have nonzero estimate: %+v", estimate)
			}
		})
	}
}

func TestFirstContentPerformanceFreshnessDoesNotFollowHeartbeat(t *testing.T) {
	history := &measurements.History{}
	var acceptedAt time.Time
	rate := 1000.0
	initialized := true
	bc := &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{{Model: "model", State: "idle", Telemetry: &protocol.SlotTelemetry{IsolatedPrefillTPS: &rate, EWMAInitialized: &initialized}}}}
	history.Reconcile(bc, acceptedAt, time.Now(), time.Second)
	sample, _ := history.Lookup("model")
	if !sample.ObservedAfter.IsZero() {
		t.Fatal("first report invented sample age")
	}
	previous := time.Now().Add(-time.Second)
	acceptedAt = previous
	history.Reconcile(bc, acceptedAt, time.Now(), time.Second)
	sample, _ = history.Lookup("model")
	if !sample.ObservedAfter.IsZero() {
		t.Fatal("same EWMA renewed sample age")
	}
	rate = 1100
	history.Reconcile(bc, acceptedAt, time.Now(), time.Second)
	sample, _ = history.Lookup("model")
	if !sample.ObservedAfter.Equal(previous) {
		t.Fatal("changed EWMA must be bounded by preceding report")
	}
	acceptedAt = time.Now()
	history.Reconcile(bc, acceptedAt, time.Now(), time.Second)
	sample, _ = history.Lookup("model")
	if !sample.ObservedAfter.Equal(previous) {
		t.Fatal("heartbeat rejuvenated unchanged measurement")
	}
	history.Reconcile(nil, acceptedAt, time.Now(), time.Second)
	if history.Count() != 0 {
		t.Fatal("missing capacity retained old evidence")
	}
	for _, state := range []string{"idle_shutdown", "reloading", "crashed"} {
		bc.Slots[0].State = "idle"
		history.Reconcile(bc, acceptedAt, time.Now(), time.Second)
		rate++
		history.Reconcile(bc, acceptedAt, time.Now(), time.Second)
		bc.Slots[0].State = state
		history.Reconcile(bc, acceptedAt, time.Now(), time.Second)
		if history.Count() != 0 {
			t.Fatalf("%s retained measured evidence", state)
		}
		bc.Slots[0].State = "idle"
		rate++
		history.Reconcile(bc, acceptedAt, time.Now(), time.Second)
		sample, _ = history.Lookup("model")
		if !sample.ObservedAfter.IsZero() {
			t.Fatal("reloaded model inherited prior sample age")
		}
	}
}

func TestFirstContentDeadlineExemptHedgeUsesAdvisoryHorizon(t *testing.T) {
	now := time.Now()
	c := forecast.Evidence{Calibration: performance.CalibrationEvidence{
		HasCapacity: true, ModelLoaded: true, IsolatedPrefillTPS: 2000, IsolatedInitialized: true,
	}, CapacityAcceptedAt: now, PrefillTPS: 2000, DecodeTPS: 100, ObservedDecodeTPS: 100,
		Workload: forecast.Workload{WholeMacKnown: true}}
	pr := forecast.Request{PromptTokens: 2000, UpperBoundTokens: 2000,
		Incoming: performance.IncomingWork{RequestedMaxTokens: 128}, Hedge: true, PlanningHorizon: 10 * time.Minute}
	estimate := forecast.Evaluate(c, pr, now).Estimate
	if estimate.Status != forecast.Feasible || !forecast.Allows(estimate, pr, c.Workload.WholeMacBusy) || !pr.Deadline.IsZero() {
		t.Fatalf("exempt hedge lost credible advisory forecast or gained deadline: %+v", estimate)
	}
	pr.PlanningHorizon = 0
	estimate = forecast.Evaluate(c, pr, now).Estimate
	if forecast.Allows(estimate, pr, c.Workload.WholeMacBusy) {
		t.Fatal("hedge without deadline or planning horizon invented feasibility")
	}
	pr.PlanningHorizon = 10 * time.Minute
	c.Workload.WholeMacBusy = true
	estimate = forecast.Evaluate(c, pr, now).Estimate
	if forecast.Allows(estimate, pr, c.Workload.WholeMacBusy) {
		t.Fatal("exempt hedge consumed occupied whole-Mac allowance")
	}
}

func TestFirstContentAcceptedCapacityCannotRejuvenatePerformance(t *testing.T) {
	f := newObservedForecastFixture(t, "p", "model", 100)
	r, p, history := f.r, f.p, f.history
	send := func(seq uint64, rate, decode float64) bool {
		bc := p.BackendCapacitySnapshot()
		bc.CapacitySeq = seq
		slot := &bc.Slots[0]
		slot.State = "idle"
		slot.ObservedDecodeTPS = decode
		slot.ObservedPrefillTPS = rate
		initialized := true
		slot.Telemetry = &protocol.SlotTelemetry{QueuedPrefillTokens: new(int64), PartialPrefillRows: new(int64), IsolatedPrefillTPS: &rate, EWMAInitialized: &initialized}
		return r.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: bc})
	}
	if !send(1, 1000, 101) || !send(2, 1100, 102) {
		t.Fatal("fresh sequence rejected")
	}
	old := time.Now().Add(-3 * time.Minute)
	p.Mu().Lock()
	p.CapacityAcceptedAt = old
	sample, _ := history.Lookup("model")
	history.Reset()
	history.Reconcile(legacyRateCapacity("model", sample.Rate+1, sample.DecodeRate+1), p.CapacityAcceptedAt, time.Now(), time.Second)
	history.Reconcile(legacyRateCapacity("model", sample.Rate, sample.DecodeRate+1), p.CapacityAcceptedAt, time.Now(), time.Second)
	p.CapacityAcceptedAt = sample.DecodeObservedAfter
	history.Reconcile(legacyRateCapacity("model", sample.Rate, sample.DecodeRate), p.CapacityAcceptedAt, time.Now(), time.Second)
	p.CapacityAcceptedAt = old
	p.Mu().Unlock()
	if send(2, 1200, 103) {
		t.Fatal("replayed capacity accepted")
	}
	p.Mu().Lock()
	current, _ := history.Lookup("model")
	if !p.CapacityAcceptedAt.Equal(old) || !current.ObservedAfter.Equal(old) {
		t.Fatal("replay freshened evidence")
	}
	p.Mu().Unlock()
	if !send(3, 1100, 103) {
		t.Fatal("new sequence rejected")
	}
	pr := forecast.Request{PromptTokens: 1000, UpperBoundTokens: 1000, Incoming: performance.IncomingWork{RequestedMaxTokens: 128}, Deadline: time.Now().Add(10 * time.Second)}
	evaluate := func() forecast.Estimate {
		p.Mu().Lock()
		e := f.evidence(time.Now())
		p.Mu().Unlock()
		return forecast.Evaluate(e, pr, time.Now()).Estimate
	}
	if e := evaluate(); e.Status != forecast.Unknown || e.Reason != "performance_age_unknown_or_stale" {
		t.Fatalf("unchanged sample became fresh: %+v", e)
	}
	if !send(4, 1200, 104) {
		t.Fatal("new measured sequence rejected")
	}
	if e := evaluate(); e.Status != forecast.Feasible {
		t.Fatalf("recently changed measurement failed to supply evidence: %+v", e)
	}
	p.Mu().Lock()
	sample, _ = history.Lookup("model")
	acceptedAt := p.CapacityAcceptedAt
	history.Reset()
	history.Reconcile(legacyRateCapacity("model", sample.Rate+1, sample.DecodeRate+1), p.CapacityAcceptedAt, time.Now(), time.Second)
	p.CapacityAcceptedAt = old
	history.Reconcile(legacyRateCapacity("model", sample.Rate+1, sample.DecodeRate), p.CapacityAcceptedAt, time.Now(), time.Second)
	p.CapacityAcceptedAt = sample.ObservedAfter
	history.Reconcile(legacyRateCapacity("model", sample.Rate, sample.DecodeRate), p.CapacityAcceptedAt, time.Now(), time.Second)
	p.CapacityAcceptedAt = acceptedAt
	p.Mu().Unlock()
	if !send(5, 1300, 104) {
		t.Fatal("new prefill sequence rejected")
	}
	if e := evaluate(); e.Status != forecast.Unknown {
		t.Fatalf("fresh prefill rejuvenated unchanged decode: %+v", e)
	}
	if !send(6, 1400, 105) {
		t.Fatal("new phase measurements rejected")
	}
	if e := evaluate(); e.Status != forecast.Feasible {
		t.Fatalf("recent measurements failed to restore evidence: %+v", e)
	}
}

func TestFirstContentServiceCountsOtherModelsWithoutOutputReservationBacklog(t *testing.T) {
	f := newObservedForecastFixture(t, "p", "model", 100)
	p := f.p
	pr := &production.PendingRequest{RequestID: "other", Model: "other-model", EstimatedPromptTokens: 100, RequestedMaxTokens: 100000}
	p.AddPending(pr)
	p.Mu().Lock()
	e := f.evidence(time.Now(), forecast.PendingWork{Model: pr.Model, EstimatedPromptTokens: pr.EstimatedPromptTokens, RequestedMaxTokens: pr.RequestedMaxTokens})
	p.Mu().Unlock()
	if e.Workload.ServiceMS <= 0 || e.Workload.ServiceMS > 10000 {
		t.Fatalf("expected bounded work across models, got %v", e.Workload.ServiceMS)
	}
	if !e.Workload.WholeMacBusy {
		t.Fatal("other-model work looked idle")
	}
	p.RemovePending(pr.RequestID)
}

func TestFirstContentExemptRetryQuoteRequiresQualifiedAdvisoryForecast(t *testing.T) {
	now := time.Now()
	for _, tc := range []struct {
		name                               string
		retry, horizon, missingPerformance bool
		want                               string
	}{
		{"fresh_retry", true, true, false, forecast.Feasible},
		{"ordinary_exempt", false, true, false, forecast.Unknown},
		{"no_horizon", true, false, false, forecast.Unknown},
		{"missing_performance", true, true, true, forecast.Unknown},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := measuredFirstContentEvidence(now)
			c.CapacityAcceptedAt = now.Add(-time.Second)
			c.Calibration.CapacityAgeMS = 1000
			if tc.missingPerformance {
				c.Calibration.PerformanceAgeMS = -1
			}
			pr := forecast.Request{PromptTokens: 500, UpperBoundTokens: 500, Incoming: performance.IncomingWork{RequestedMaxTokens: 64}, RequireFreshFeasible: tc.retry, FreshAfter: now.Add(-time.Millisecond)}
			if tc.horizon {
				pr.PlanningHorizon = 10 * time.Minute
			}
			result := forecast.Evaluate(c, pr, now)
			if result.Estimate.Status != forecast.Unknown {
				t.Fatal("pre-refusal evidence allowed exempt recovery")
			}
			estimate := forecast.ApplyQuote(result, c, pr, forecast.Quote{Confirmed: true, Confidence: protocol.CapacityConfidenceHigh,
				ObservedAt: now, TTFTP50: time.Millisecond, TTFTP90: 2 * time.Millisecond}, forecast.QuoteContext{}, now)
			if estimate.Status != tc.want || !pr.Deadline.IsZero() || pr.MaxTTFTMS != 0 {
				t.Fatalf("forecast=%+v, want %s without deadline", estimate, tc.want)
			}
		})
	}
}

func TestFirstContentWholeMacWorkReconcilesReportAndNewReservations(t *testing.T) {
	f := newObservedForecastFixture(t, "p", "model", 100)
	p := f.p
	p.Mu().Lock()
	p.CapacityAcceptedAt = time.Now()
	p.BackendCapacity.Slots = append(p.BackendCapacity.Slots, protocol.BackendSlotCapacity{
		Model: "other", State: "running", NumRunning: 1, ObservedDecodeTPS: 100, ObservedPrefillTPS: 1000,
	})
	p.Mu().Unlock()
	pr := &production.PendingRequest{RequestID: "new", Model: "other", RequestedMaxTokens: 256, EstimatedPromptTokens: 100}
	p.AddPending(pr)
	// Capture a local reservation time between the same two capacity frames.
	pending := forecast.PendingWork{Model: pr.Model, RequestedMaxTokens: pr.RequestedMaxTokens, EstimatedPromptTokens: pr.EstimatedPromptTokens, ReservedAt: time.Now()}
	p.Mu().Lock()
	e := f.evidence(time.Now(), pending)
	if e.Workload.OtherModelOccupancy != 2 || e.Workload.ServiceMS != 5220 {
		t.Fatalf("new work hidden by old report: occupancy=%d work=%v", e.Workload.OtherModelOccupancy, e.Workload.ServiceMS)
	}
	p.CapacityAcceptedAt = time.Now()
	e = f.evidence(time.Now(), pending)
	p.Mu().Unlock()
	if e.Workload.OtherModelOccupancy != 1 || e.Workload.ServiceMS != 2660 {
		t.Fatalf("overlapping work charged twice: occupancy=%d work=%v", e.Workload.OtherModelOccupancy, e.Workload.ServiceMS)
	}
	p.RemovePending(pr.RequestID)
}
