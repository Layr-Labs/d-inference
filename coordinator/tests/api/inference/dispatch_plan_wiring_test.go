package inference_test

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/estimate"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	inferhedge "github.com/eigeninference/d-inference/coordinator/internal/inference/hedge"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

// Reserve through the production scan, then release only its primary. The
// retained alternates keep the production ordering and attempted identities.
func planWiringPlan(t *testing.T, reg *registry.Registry, model string) *registry.DispatchPlan {
	t.Helper()
	probe := &registry.PendingRequest{
		RequestID: "plan-wiring-probe", Model: model,
		EstimatedPromptTokens: 500, RequestedMaxTokens: 256,
	}
	primary, decision, plan := reg.ReserveProviderWithPlan(model, probe)
	if primary == nil || plan == nil {
		t.Fatalf("plan reservation failed: decision=%+v", decision)
	}
	primary.RemovePending(probe.RequestID)
	reg.SetProviderIdle(primary.ID)
	return plan
}

func TestPlanFirstRetryConsumesPlanBeforeRescanAndRefreshesOnce(t *testing.T) {
	s := newTestServerForDispatch(t)
	const model = "plan-wiring-retry-model"
	for i := range 6 {
		planWiringProvider(t, s.registry, fmt.Sprintf("pw%d", i), model, int64(i)*400)
	}
	plan := planWiringPlan(t, s.registry, model)
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader("{}"))
	exclusions := dispatch.NewExclusions()
	in := dispatch.Input{
		Request: req, Model: model, PublicModel: model,
		Body: []byte(`{"model":"` + model + `"}`), Deadline: 5 * time.Second,
		Timing: &registry.RequestTiming{ReceivedAt: time.Now()}, Exclusions: exclusions,
		Forecast: firstcontent.NewForecast(estimate.NewContextCalibration(), exclusions.Exclude),
	}
	retained := s.NewDispatcher().NewPlan(plan)
	entries := plan.Len()
	if entries == 0 {
		t.Fatal("fixture retained no alternates")
	}
	for i := range entries {
		out, selection := retained.Next(in)
		if !selection.Tried() {
			t.Fatalf("entry %d: machinery yielded nothing with %d entries remaining", i, plan.Remaining())
		}
		if out.Provider != nil || out.Pending != nil {
			t.Fatalf("entry %d: socketless provider must fail the funnel write, got provider=%v", i, out.Provider)
		}
		if out.Error != "failed to send request to provider" {
			t.Fatalf("entry %d: lastErr=%q — the plan entry did not go through the single dispatch funnel", i, out.Error)
		}
		if selection != dispatch.PlanRetained {
			t.Fatalf("entry %d: consuming a retained entry must not spend the refresh", i)
		}
	}
	if got := plan.Remaining(); got != 0 {
		t.Fatalf("remaining=%d after consuming every entry", got)
	}
	// The primary and every alternate have been attempted. The one refresh
	// carries those exclusions and finds nothing; a second call cannot refresh.
	_, selection := retained.Next(in)
	if selection.Tried() {
		t.Fatal("refresh over a fully-attempted fleet must yield nothing")
	}
	if selection != dispatch.PlanRefreshEmpty {
		t.Fatal("exhausted plan must spend the request's one refresh")
	}
	if _, selection = retained.Next(in); selection != dispatch.PlanExhausted {
		t.Fatal("second refresh must not run")
	}
}

func TestCollectCapacityQuotesRefinesOnlyOnHighConfidence(t *testing.T) {
	s := newTestServerForDispatch(t)
	const model = "collect-quotes-model"
	for i := range 4 {
		p := planWiringProvider(t, s.registry, fmt.Sprintf("cq%d", i), model, 0)
		// Quotes may refine a qualified forecast, not create feasibility from
		// missing performance or workload evidence.
		reportIdleFirstContentEvidence(s.registry, p.ID, model)
	}
	receivedAt := time.Now()
	deadline := 9 * time.Second
	speculativeAt := 4500 * time.Millisecond
	run := func(confidence string) (time.Time, bool) {
		plan := planWiringPlan(t, s.registry, model)
		next, ok := plan.PeekNext()
		if !ok {
			t.Fatal("plan retained no alternates")
		}
		quote := &protocol.CapacityQuoteMessage{
			Type: protocol.TypeCapacityQuote, QuoteID: "q-" + confidence,
			CapacitySeq: 2, AdmissibleNow: true, TTFTP50MS: 6000, TTFTP90MS: 7000,
			Confidence: confidence,
		}
		plan.ConfirmEntry(next.ProviderID, quote)
		outcomes := make(chan registry.QuoteOutcome, 1)
		outcomes <- registry.QuoteOutcome{ProviderID: next.ProviderID, Quote: quote}
		close(outcomes)
		advance := make(chan time.Time, 1)
		dispatch.CollectCapacityQuotes(outcomes, plan, receivedAt, deadline, speculativeAt, advance)
		select {
		case at := <-advance:
			return at, true
		default:
			return time.Time{}, false
		}
	}
	at, delivered := run(protocol.CapacityConfidenceHigh)
	if !delivered {
		t.Fatal("high-confidence slow backup must refine the launch point")
	}
	// 9s minus the 7s q90 and 500ms commit guard leaves 1.5s.
	if want := receivedAt.Add(1500 * time.Millisecond); !at.Equal(want) {
		t.Fatalf("refined instant=%s, want receivedAt+1.5s (%s)", at, want)
	}
	if _, delivered := run(protocol.CapacityConfidenceLow); delivered {
		t.Fatal("low-confidence quote must never move the launch off the 50% ceiling")
	}
	deadline = 0
	if _, delivered := run(protocol.CapacityConfidenceHigh); delivered {
		t.Fatal("an exempt request must not acquire an immediate SLA-based hedge")
	}
}

func TestFirstContentSLAExemptionPreservesCapacityProbes(t *testing.T) {
	s := newTestServerForDispatch(t)
	const model = "exempt-capacity-probe-model"
	for i := 0; i < 3; i++ {
		planWiringProvider(t, s.registry, fmt.Sprintf("exempt-probe-%d", i), model, int64(i)*400)
	}
	retained := s.NewDispatcher().NewPlan(planWiringPlan(t, s.registry, model))
	in := dispatch.ProbeInput{Model: model, ReceivedAt: time.Now(), Deadline: 0, SpeculativeAt: time.Second}
	if _, started := retained.Probe(in); !started {
		t.Fatal("account exemption disabled capacity probes")
	}
	if firstcontent.NewClock(in.ReceivedAt, in.Deadline, in.SpeculativeAt).Expired() || in.Deadline != 0 {
		t.Fatal("capacity probe reinstated SLA")
	}
}

// A reporting but fully occupied fleet must take the same no-backup wait.
func TestGovernorSuppressionFallsThroughToNoBackup(t *testing.T) {
	d, _ := newContentWaitFixture(t, 0, 500*time.Millisecond)
	d.speculativeAt = 30 * time.Millisecond
	busy := planWiringProvider(t, d.s.registry, "busy-alt", d.pr.Model, 0)
	busy.Mu().Lock()
	busy.BackendCapacity.Slots[0].NumRunning = 2
	busy.BackendCapacity.Slots[0].ActiveTokens = 5000
	busy.Mu().Unlock()

	if got := d.first(); got != attempt.Retry {
		t.Fatalf("waitFirstChunk=%v, want timeout-driven outcomeRetry", got)
	}
	if d.speculativeResult.GovernorVerdict != inferhedge.SuppressNoIdleCapacity.String() {
		t.Fatalf("verdict=%q, want %q", d.speculativeResult.GovernorVerdict, inferhedge.SuppressNoIdleCapacity.String())
	}
	if d.failure.Message.StatusCode != http.StatusGatewayTimeout {
		t.Fatalf("lastErrCode=%d, want the legacy no-backup 504", d.failure.Message.StatusCode)
	}
	if got := d.s.hedgeGov.ActiveCount(); got != 0 {
		t.Fatalf("activeHedges=%d after suppression, want 0", got)
	}
}

// A capacity-silent fleet cannot establish a feasible spare hedge.
func TestGovernorSuppressesCapacitySilentFleet(t *testing.T) {
	d, _ := newContentWaitFixture(t, 0, 500*time.Millisecond)
	d.speculativeAt = 30 * time.Millisecond

	if got := d.first(); got != attempt.Retry {
		t.Fatalf("waitFirstChunk=%v, want timeout-driven outcomeRetry", got)
	}
	if d.speculativeResult.GovernorVerdict != inferhedge.SuppressNoIdleCapacity.String() {
		t.Fatalf("verdict=%q, want %q — capacity-silent fleet cannot justify a hedge", d.speculativeResult.GovernorVerdict, inferhedge.SuppressNoIdleCapacity.String())
	}
	if got := d.s.hedgeGov.ActiveCount(); got != 0 {
		t.Fatalf("activeHedges=%d after resolution, want 0", got)
	}
}

// Allow must run the legacy funnel and release an admitted but unwritten hedge.
func TestGovernorAllowKeepsLegacyBackupPath(t *testing.T) {
	d, _ := newContentWaitFixture(t, 0, 3*time.Second)
	d.speculativeAt = 30 * time.Millisecond
	d.estimatedPromptTokens = 500
	d.body = []byte(`{"model":"first-token-deadline-model"}`)
	planWiringProvider(t, d.s.registry, "idle-backup", d.pr.Model, 0)
	reportIdleFirstContentEvidence(d.s.registry, "idle-backup", d.pr.Model)

	if got := d.first(); got != attempt.Retry {
		t.Fatalf("waitFirstChunk=%v, want timeout-driven outcomeRetry", got)
	}
	if d.speculativeResult.GovernorVerdict != inferhedge.Allow.String() {
		t.Fatalf("verdict=%q, want %q (idle capacity exists, no queue)", d.speculativeResult.GovernorVerdict, inferhedge.Allow.String())
	}
	// The request-local backup exclusions are not the observation: the real
	// deferred-write funnel must persist the reserved backup's routing row.
	st, ok := d.s.store.(*memory.MemoryStore)
	if !ok {
		t.Fatalf("store = %T", d.s.store)
	}
	backupRouted := false
	deadline := time.Now().Add(2 * time.Second)
	for !backupRouted && time.Now().Before(deadline) {
		for _, route := range st.InferenceRouteRecordsSince(time.Time{}) {
			if route.ProviderID == "idle-backup" {
				backupRouted = true
				break
			}
		}
		if !backupRouted {
			time.Sleep(10 * time.Millisecond)
		}
	}
	if !backupRouted {
		t.Fatal("allow path must have run the legacy backup dispatch (no route row for the reserved backup)")
	}
	if got := d.s.hedgeGov.ActiveCount(); got != 0 {
		t.Fatalf("activeHedges=%d, want 0 — an admitted hedge that never dispatched must be released", got)
	}
}
