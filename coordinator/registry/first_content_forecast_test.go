package registry

import (
	"math"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func measuredFirstContentCandidate(now time.Time) *routingCandidate {
	return &routingCandidate{snapshot: routingSnapshot{
		firstContentSnapshot: firstContentSnapshot{capacityAgeMs: 0, capacityAcceptedAt: now,
			performanceAgeMs: 0, isolatedPrefillTPS: 2000, isolatedPrefillInitialized: true,
			wholeMacWorkKnown: true, queuedPrefillKnown: true},
		modelLoaded: true, slotState: "idle", hasBackendCapacity: true,
		prefillTPS: 2000, observedPrefillTPS: 2000, observedDecodeTPS: 100, decodeTPS: 100,
	}}
}

func TestFirstContentForecastConfidenceAndCacheBeforeDeadline(t *testing.T) {
	now := time.Now()
	r := New(testLogger())
	pr := &PendingRequest{EstimatedPromptTokens: 4000, RequestedMaxTokens: 128, FirstContentDeadline: now.Add(3 * time.Second)}
	c := measuredFirstContentCandidate(now)
	r.estimateFirstContent(c, pr, now)
	if c.firstContent.Status != FirstContentPredictedLate || c.firstContent.ExpectedMs >= c.firstContent.ConservativeMs {
		t.Fatalf("need distinct expected/late conservative prediction: %+v", c.firstContent)
	}
	c.firstContentCachedTokens, c.firstContentCacheWeight = 9000, 1
	c.firstContentRestoreMs, c.firstContentCacheExpiresAt = 80, now.Add(time.Minute)
	r.estimateFirstContent(c, pr, now)
	if c.firstContent.Status != FirstContentFeasible || c.firstContent.CachedTokens != 4000 || c.firstContent.RestoreMs != 80 {
		t.Fatalf("cache should fit deadline, bound reuse, and charge restore once: %+v", c.firstContent)
	}
	c.firstContentCacheExpiresAt = now
	r.estimateFirstContent(c, pr, now)
	if c.firstContent.Status != FirstContentPredictedLate || c.firstContent.CachedTokens != 0 {
		t.Fatal("expired proof retained credit")
	}
	for _, tc := range []struct {
		name   string
		change func(*routingCandidate)
	}{
		{"capacity_stale", func(c *routingCandidate) { c.snapshot.capacityAgeMs = 6000 }},
		{"missing_performance_age", func(c *routingCandidate) { c.snapshot.performanceAgeMs = -1 }},
		{"performance_stale", func(c *routingCandidate) { c.snapshot.performanceAgeMs = 180000 }},
		{"busy", func(c *routingCandidate) { c.snapshot.wholeMacBusy = true }},
		{"missing_work", func(c *routingCandidate) { c.snapshot.wholeMacWorkKnown = false }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := measuredFirstContentCandidate(now)
			tc.change(c)
			r.estimateFirstContent(c, pr, now)
			if c.firstContent.Status != FirstContentUnknown || c.firstContent.ExpectedMs <= 0 {
				t.Fatalf("unknown must have nonzero estimate: %+v", c.firstContent)
			}
		})
	}
}

func TestFirstContentUsesMeasuredPrefillAboveOldCeiling(t *testing.T) {
	r := New(testLogger())
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
	pr := &PendingRequest{RequestID: "request", Model: "model", EstimatedPromptTokens: 8000, RequestedMaxTokens: 100000}
	p, d := r.ReserveProviderEx("model", pr)
	if p == nil || p.ID != "fast" {
		t.Fatalf("fast measured prefill should win: %+v", d)
	}
	p.RemovePending(pr.RequestID)
	for _, rate := range []float64{math.NaN(), math.Inf(1), -1, 20001} {
		bc := &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{{ObservedPrefillTPS: rate, Telemetry: &protocol.SlotTelemetry{IsolatedPrefillTPS: &rate}}}}
		clampBackendCapacity(testLogger(), "invalid", bc)
		if bc.Slots[0].ObservedPrefillTPS != 0 || bc.Slots[0].Telemetry.IsolatedPrefillTPS != nil {
			t.Fatal("invalid rate became evidence")
		}
	}
}

func TestFirstContentPerformanceFreshnessDoesNotFollowHeartbeat(t *testing.T) {
	p := &Provider{}
	rate := 1000.0
	initialized := true
	bc := &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{{Model: "model", State: "idle", Telemetry: &protocol.SlotTelemetry{IsolatedPrefillTPS: &rate, EWMAInitialized: &initialized}}}}
	p.reconcileFirstContentMeasurementsLocked(bc)
	if !p.firstContentMeasurements["model"].observedAfter.IsZero() {
		t.Fatal("first report invented sample age")
	}
	previous := time.Now().Add(-time.Second)
	p.CapacityAcceptedAt = previous
	p.reconcileFirstContentMeasurementsLocked(bc)
	if !p.firstContentMeasurements["model"].observedAfter.IsZero() {
		t.Fatal("same EWMA renewed sample age")
	}
	rate = 1100
	p.reconcileFirstContentMeasurementsLocked(bc)
	if !p.firstContentMeasurements["model"].observedAfter.Equal(previous) {
		t.Fatal("changed EWMA must be bounded by preceding report")
	}
	p.CapacityAcceptedAt = time.Now()
	p.reconcileFirstContentMeasurementsLocked(bc)
	if !p.firstContentMeasurements["model"].observedAfter.Equal(previous) {
		t.Fatal("heartbeat rejuvenated unchanged measurement")
	}
	p.reconcileFirstContentMeasurementsLocked(nil)
	if len(p.firstContentMeasurements) != 0 {
		t.Fatal("missing capacity retained old evidence")
	}
	for _, state := range []string{"idle_shutdown", "reloading", "crashed"} {
		bc.Slots[0].State = "idle"
		p.reconcileFirstContentMeasurementsLocked(bc)
		rate++
		p.reconcileFirstContentMeasurementsLocked(bc)
		bc.Slots[0].State = state
		p.reconcileFirstContentMeasurementsLocked(bc)
		if len(p.firstContentMeasurements) != 0 {
			t.Fatalf("%s retained measured evidence", state)
		}
		bc.Slots[0].State = "idle"
		rate++
		p.reconcileFirstContentMeasurementsLocked(bc)
		if !p.firstContentMeasurements["model"].observedAfter.IsZero() {
			t.Fatal("reloaded model inherited prior sample age")
		}
	}
}

func TestFirstContentAcceptedCapacityCannotRejuvenatePerformance(t *testing.T) {
	r := New(testLogger())
	p := makeSchedulerProvider(t, r, "p", "model", 100)
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
	p.mu.Lock()
	p.CapacityAcceptedAt = old
	sample := p.firstContentMeasurements["model"]
	sample.observedAfter = old
	p.firstContentMeasurements["model"] = sample
	p.mu.Unlock()
	if send(2, 1200, 103) {
		t.Fatal("replayed capacity accepted")
	}
	p.mu.Lock()
	if !p.CapacityAcceptedAt.Equal(old) || !p.firstContentMeasurements["model"].observedAfter.Equal(old) {
		t.Fatal("replay freshened evidence")
	}
	p.mu.Unlock()
	if !send(3, 1100, 103) {
		t.Fatal("new sequence rejected")
	}
	pr := &PendingRequest{Model: "model", EstimatedPromptTokens: 1000, RequestedMaxTokens: 128, FirstContentDeadline: time.Now().Add(10 * time.Second)}
	forecast := func() FirstContentEstimate {
		c := &routingCandidate{}
		p.mu.Lock()
		r.fillRoutingSnapshotPLocked(&c.snapshot, p, "model", time.Now())
		p.mu.Unlock()
		r.estimateFirstContent(c, pr, time.Now())
		return c.firstContent
	}
	if e := forecast(); e.Status != FirstContentUnknown || e.Reason != "performance_age_unknown_or_stale" {
		t.Fatalf("unchanged sample became fresh: %+v", e)
	}
	if !send(4, 1200, 104) {
		t.Fatal("new measured sequence rejected")
	}
	if e := forecast(); e.Status != FirstContentFeasible {
		t.Fatalf("recently changed measurement failed to supply evidence: %+v", e)
	}
	p.mu.Lock()
	sample = p.firstContentMeasurements["model"]
	sample.decodeObservedAfter = old
	p.firstContentMeasurements["model"] = sample
	p.mu.Unlock()
	if !send(5, 1300, 104) {
		t.Fatal("new prefill sequence rejected")
	}
	if e := forecast(); e.Status != FirstContentUnknown {
		t.Fatalf("fresh prefill rejuvenated unchanged decode: %+v", e)
	}
	if !send(6, 1400, 105) {
		t.Fatal("new phase measurements rejected")
	}
	if e := forecast(); e.Status != FirstContentFeasible {
		t.Fatalf("recent measurements failed to restore evidence: %+v", e)
	}
}

func TestFirstContentServiceCountsOtherModelsWithoutOutputReservationBacklog(t *testing.T) {
	r := New(testLogger())
	p := makeSchedulerProvider(t, r, "p", "model", 100)
	pr := &PendingRequest{RequestID: "other", Model: "other-model", EstimatedPromptTokens: 100, RequestedMaxTokens: 100000}
	p.AddPending(pr)
	p.mu.Lock()
	var snap routingSnapshot
	r.fillRoutingSnapshotPLocked(&snap, p, "model", time.Now())
	p.mu.Unlock()
	if snap.wholeMacServiceMs <= 0 || snap.wholeMacServiceMs > 10000 {
		t.Fatalf("expected bounded work across models, got %v", snap.wholeMacServiceMs)
	}
	if !snap.wholeMacBusy {
		t.Fatal("other-model work looked idle")
	}
	p.RemovePending(pr.RequestID)
}

func TestFirstContentDeadlineExemptHedgeUsesAdvisoryHorizon(t *testing.T) {
	now := time.Now()
	r := New(testLogger())
	c := measuredFirstContentCandidate(now)
	pr := &PendingRequest{EstimatedPromptTokens: 2000, RequestedMaxTokens: 128, Hedge: true, FirstContentPlanningHorizon: 10 * time.Minute}
	r.estimateFirstContent(c, pr, now)
	if c.firstContent.Status != FirstContentFeasible || !firstContentCandidateAllowed(c, pr) || !pr.FirstContentDeadline.IsZero() {
		t.Fatalf("exempt hedge lost credible advisory forecast or gained deadline: %+v", c.firstContent)
	}
	pr.FirstContentPlanningHorizon = 0
	r.estimateFirstContent(c, pr, now)
	if firstContentCandidateAllowed(c, pr) {
		t.Fatal("hedge without deadline or planning horizon invented feasibility")
	}
	pr.FirstContentPlanningHorizon = 10 * time.Minute
	c.snapshot.wholeMacBusy = true
	r.estimateFirstContent(c, pr, now)
	if firstContentCandidateAllowed(c, pr) {
		t.Fatal("exempt hedge consumed occupied whole-Mac allowance")
	}
}

func TestFirstContentExemptRetryQuoteRequiresQualifiedAdvisoryForecast(t *testing.T) {
	now := time.Now()
	r := New(testLogger())
	for _, tc := range []struct {
		name                               string
		retry, horizon, missingPerformance bool
		want                               string
	}{
		{"fresh_retry", true, true, false, FirstContentFeasible},
		{"ordinary_exempt", false, true, false, FirstContentUnknown},
		{"no_horizon", true, false, false, FirstContentUnknown},
		{"missing_performance", true, true, true, FirstContentUnknown},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := measuredFirstContentCandidate(now)
			c.snapshot.capacityAcceptedAt = now.Add(-time.Second)
			c.snapshot.capacityAgeMs = 1000
			if tc.missingPerformance {
				c.snapshot.performanceAgeMs = -1
			}
			pr := &PendingRequest{EstimatedPromptTokens: 500, RequestedMaxTokens: 64,
				RequireFreshFeasible: tc.retry, RequireFreshFeasibleAfter: now.Add(-time.Millisecond)}
			if tc.horizon {
				pr.FirstContentPlanningHorizon = 10 * time.Minute
			}
			r.estimateFirstContent(c, pr, now)
			if c.firstContent.Status != FirstContentUnknown {
				t.Fatal("pre-refusal evidence allowed exempt recovery")
			}
			applyFirstContentQuote(c, pr, PlanEntry{Confirmed: true, QuoteConfidence: protocol.CapacityConfidenceHigh,
				QuoteObservedAt: now, QuoteTTFTP50: time.Millisecond, QuoteTTFTP90: 2 * time.Millisecond}, now)
			if c.firstContent.Status != tc.want || !pr.FirstContentDeadline.IsZero() || pr.MaxTTFTMs != 0 {
				t.Fatalf("forecast=%+v, want %s without deadline", c.firstContent, tc.want)
			}
		})
	}
}

func TestFirstContentWholeMacWorkReconcilesReportAndNewReservations(t *testing.T) {
	r := New(testLogger())
	p := makeSchedulerProvider(t, r, "p", "model", 100)
	p.mu.Lock()
	p.CapacityAcceptedAt = time.Now()
	p.BackendCapacity.Slots = append(p.BackendCapacity.Slots, protocol.BackendSlotCapacity{
		Model: "other", State: "running", NumRunning: 1, ObservedDecodeTPS: 100, ObservedPrefillTPS: 1000,
	})
	p.mu.Unlock()
	pr := &PendingRequest{RequestID: "new", Model: "other", RequestedMaxTokens: 256, EstimatedPromptTokens: 100}
	p.AddPending(pr)
	p.mu.Lock()
	var snapshot routingSnapshot
	r.fillRoutingSnapshotPLocked(&snapshot, p, "model", time.Now())
	if snapshot.otherModelOccupancy != 2 || snapshot.wholeMacServiceMs != 5220 {
		t.Fatalf("new work hidden by old report: occupancy=%d work=%v", snapshot.otherModelOccupancy, snapshot.wholeMacServiceMs)
	}
	// A subsequent capacity frame may already reflect the local request.
	p.CapacityAcceptedAt = time.Now()
	r.fillRoutingSnapshotPLocked(&snapshot, p, "model", time.Now())
	p.mu.Unlock()
	if snapshot.otherModelOccupancy != 1 || snapshot.wholeMacServiceMs != 2660 {
		t.Fatalf("overlapping work charged twice: occupancy=%d work=%v", snapshot.otherModelOccupancy, snapshot.wholeMacServiceMs)
	}
	p.RemovePending(pr.RequestID)
}
