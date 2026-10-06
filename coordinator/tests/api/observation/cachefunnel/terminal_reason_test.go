package cachefunnel_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/observation/cachefunnel"
)

var (
	selectedScoped = cachefunnel.Attempt{Routing: cachefunnel.RoutingSelected, Scoped: true}
	coldScoped     = cachefunnel.Attempt{Routing: cachefunnel.RoutingNoRepeat, Scoped: true}
	unknownTokens  = cachefunnel.Tokens{}
)

func completedWith(lookup cachefunnel.Lookup, reused cachefunnel.Tokens) cachefunnel.Completion {
	return cachefunnel.Completion{Lookup: lookup, Reused: reused}
}

type lifecycle struct {
	name      string
	drive     func(*cachefunnel.Request)
	cancelled bool
	want      cachefunnel.Reason
}

func planned(request *cachefunnel.Request) {
	request.NotePlanning(cachefunnel.PlanningPlanned, cachefunnel.KnownTokens(4096))
	request.NotePlan(4096, 2048)
}

func dispatchedAs(attempt cachefunnel.Attempt) func(*cachefunnel.Request) {
	return func(request *cachefunnel.Request) {
		planned(request)
		request.NoteAttemptDispatched(attempt)
	}
}

func completedAs(attempt cachefunnel.Attempt, completion cachefunnel.Completion) func(*cachefunnel.Request) {
	return func(request *cachefunnel.Request) {
		dispatchedAs(attempt)(request)
		request.NoteAttemptCompleted(attempt, completion)
	}
}

func planningOnly(planning cachefunnel.Planning) func(*cachefunnel.Request) {
	return func(request *cachefunnel.Request) {
		request.NotePlanning(planning, unknownTokens)
		request.NoteAttemptDispatched(cachefunnel.Attempt{})
		request.NoteAttemptCompleted(cachefunnel.Attempt{}, cachefunnel.Completion{})
	}
}

// At least one lifecycle per terminal reason, in lifecycle order.
func everyLifecycle() []lifecycle {
	routed := func(routing cachefunnel.Routing) cachefunnel.Attempt {
		return cachefunnel.Attempt{Routing: routing, Scoped: true}
	}
	miss := completedWith(cachefunnel.LookupMiss, cachefunnel.KnownTokens(0))
	return []lifecycle{
		{name: "not eligible", drive: planningOnly(cachefunnel.PlanningNotEligible), want: cachefunnel.NotEligible},
		{name: "planner unavailable", drive: planningOnly(cachefunnel.PlanningPlannerUnavailable), want: cachefunnel.PlannerUnavailable},
		{name: "outer gate refused", drive: planningOnly(cachefunnel.PlanningGateRefused), want: cachefunnel.GateRefused},
		{name: "sampled out", drive: planningOnly(cachefunnel.PlanningSampledOut), want: cachefunnel.SampledOut},
		{name: "rate limited", drive: planningOnly(cachefunnel.PlanningRateLimited), want: cachefunnel.RateLimited},
		{name: "plan failed", drive: planningOnly(cachefunnel.PlanningFailed), want: cachefunnel.PlanFailed},
		{name: "plan empty", drive: planningOnly(cachefunnel.PlanningEmpty), want: cachefunnel.PlanEmpty},
		{name: "served without a planning decision", drive: planningOnly(cachefunnel.PlanningNotObserved), want: cachefunnel.PlanningUnobserved},
		{name: "client cancelled before dispatch", drive: planned, cancelled: true, want: cachefunnel.CancelledBeforeDispatch},
		{name: "failed before dispatch", drive: planned, want: cachefunnel.ErroredBeforeDispatch},
		{name: "routing not evaluated", drive: completedAs(routed(cachefunnel.RoutingNotObserved), miss), want: cachefunnel.RoutingUnobserved},
		{name: "first-time prompt", drive: completedAs(routed(cachefunnel.RoutingNoRepeat), miss), want: cachefunnel.NoRepeatObserved},
		{name: "repeat without holder", drive: completedAs(routed(cachefunnel.RoutingRepeatWithoutHolder), miss), want: cachefunnel.RepeatWithoutHolder},
		{name: "holder unusable", drive: completedAs(routed(cachefunnel.RoutingHolderUnusableOrUnavailable), miss), want: cachefunnel.HolderUnusableOrUnavailable},
		{name: "holder not selected", drive: completedAs(routed(cachefunnel.RoutingHolderNotSelected), miss), want: cachefunnel.HolderNotSelected},
		{name: "selected without scope", drive: completedAs(cachefunnel.Attempt{Routing: cachefunnel.RoutingSelected}, miss), want: cachefunnel.SelectedWithoutScope},
		{name: "client cancelled after dispatch", drive: dispatchedAs(selectedScoped), cancelled: true, want: cachefunnel.CancelledAfterDispatch},
		{name: "failed after dispatch", drive: dispatchedAs(selectedScoped), want: cachefunnel.ErroredAfterDispatch},
		{name: "selected, usage missing", drive: completedAs(selectedScoped, cachefunnel.Completion{}), want: cachefunnel.SelectedOutcomeUnknown},
		{name: "selected skip", drive: completedAs(selectedScoped, completedWith(cachefunnel.LookupSkip, cachefunnel.KnownTokens(0))), want: cachefunnel.SelectedSkip},
		{name: "selected miss", drive: completedAs(selectedScoped, miss), want: cachefunnel.SelectedMiss},
		{name: "hit without selection", drive: completedAs(coldScoped, completedWith(cachefunnel.LookupHit, cachefunnel.KnownTokens(1024))), want: cachefunnel.HitWithoutSelection},
		{name: "hit on a request served without a plan", drive: func(request *cachefunnel.Request) {
			request.NotePlanning(cachefunnel.PlanningSampledOut, unknownTokens)
			request.NoteAttemptDispatched(cachefunnel.Attempt{})
			request.NoteAttemptCompleted(cachefunnel.Attempt{}, completedWith(cachefunnel.LookupHit, cachefunnel.KnownTokens(512)))
		}, want: cachefunnel.HitWithoutSelection},
		{name: "hit", drive: completedAs(selectedScoped, completedWith(cachefunnel.LookupHit, cachefunnel.KnownTokens(2048))), want: cachefunnel.Hit},
	}
}

func TestEveryLifecycleEndsInExactlyOneReason(t *testing.T) {
	cases := everyLifecycle()
	covered := make(map[string]bool)
	for _, c := range cases {
		covered[c.want.String()] = true
		t.Run(c.name, func(t *testing.T) {
			ledger, collector := newCollectedLedger()
			request := ledger.Enter()
			c.drive(request)
			request.Close(c.cancelled)

			records := collector.snapshot()
			if len(records) != 1 || records[0].Reason != c.want {
				t.Fatalf("records = %+v, want exactly one with reason %s", records, c.want)
			}
			status := ledger.Snapshot()
			for _, totals := range status.Reasons {
				want := uint64(0)
				if totals.Reason == c.want.String() {
					want = 1
				}
				if totals.Requests != want {
					t.Fatalf("reason %q counts %d requests, want %d", totals.Reason, totals.Requests, want)
				}
			}
			requireReconciled(t, status, records)
		})
	}
	for _, reason := range reasonNames() {
		if !covered[reason] {
			t.Errorf("no lifecycle reaches terminal reason %s", reason)
		}
	}
}

// The attempt is counted after its frame is on the wire, on a different
// goroutine from the provider reader that records the completion, so a fast
// provider's completion can be recorded first, or be the only one recorded
// before the handler closes the request.
func TestCompletionProvesDispatchInEitherHookOrder(t *testing.T) {
	miss := completedWith(cachefunnel.LookupMiss, cachefunnel.KnownTokens(0))
	for name, dispatchCountedLate := range map[string]bool{"dispatch never counted": false, "dispatch counted after completion": true} {
		t.Run(name, func(t *testing.T) {
			ledger, collector := newCollectedLedger()
			request := ledger.Enter()
			planned(request)
			request.NoteAttemptCompleted(selectedScoped, miss)
			if dispatchCountedLate {
				request.NoteAttemptDispatched(selectedScoped)
			}
			request.Close(false)

			status := ledger.Snapshot()
			if got := requestsFor(status, cachefunnel.SelectedMiss); got.Requests != 1 || got.Attempts != 1 || got.DispatchedWithoutScope != 0 {
				t.Fatalf("status = %+v, want the completed request under selected_miss with one attempt", status)
			}
			requireReconciled(t, status, collector.snapshot())
		})
	}
}

func TestNegativeCountIsUnknownInTheRecordAndTheAggregate(t *testing.T) {
	ledger, collector := newCollectedLedger()
	request := ledger.Enter()
	request.NotePlanning(cachefunnel.PlanningPlanned, cachefunnel.KnownTokens(-1))
	request.NotePlan(-1, -2)
	attempt := cachefunnel.Attempt{Routing: cachefunnel.RoutingSelected, Scoped: true, Predicted: cachefunnel.KnownTokens(-3)}
	request.NoteAttemptDispatched(attempt)
	request.NoteAttemptCompleted(attempt, completedWith(cachefunnel.LookupMiss, cachefunnel.KnownTokens(-4)))
	request.Close(false)

	record := collector.snapshot()[0]
	if record.PromptTokens.Known || record.RepeatedPrefixTokens.Known || record.PredictedTokens.Known || record.ReusedTokens.Known {
		t.Fatalf("record = %+v, want every negative count delivered as unknown", record)
	}
	status := ledger.Snapshot()
	want := cachefunnel.Totals{Requests: 1, Attempts: 1, LookupOutcomeReported: 1,
		PromptTokensUnknown: 1, RepeatedPrefixTokensUnknown: 1, PredictedTokensUnknown: 1, ReusedTokensUnknown: 1}
	if status.Total != want {
		t.Fatalf("total = %+v, want %+v", status.Total, want)
	}
	requireReconciled(t, status, collector.snapshot())
}

func TestFunnelConservesRequestsAndTokensAtEveryStage(t *testing.T) {
	ledger, collector := newCollectedLedger()
	cases := everyLifecycle()
	open := make([]*cachefunnel.Request, 0, len(cases))
	for _, c := range cases {
		request := ledger.Enter()
		c.drive(request)
		open = append(open, request)
		requireReconciled(t, ledger.Snapshot(), collector.snapshot())
	}
	if status := ledger.Snapshot(); status.InFlight != uint64(len(cases)) || status.Closed != 0 {
		t.Fatalf("before any close: in flight %d closed %d, want %d and 0", status.InFlight, status.Closed, len(cases))
	}
	for i, c := range cases {
		open[i].Close(c.cancelled)
		status := ledger.Snapshot()
		if status.Closed != uint64(i+1) || status.Entered != uint64(len(cases)) {
			t.Fatalf("after %d closes: entered %d closed %d", i+1, status.Entered, status.Closed)
		}
		requireReconciled(t, status, collector.snapshot())
	}
	if status := ledger.Snapshot(); status.InFlight != 0 || status.Total.Requests != uint64(len(cases)) {
		t.Fatalf("after every close: in flight %d, total requests %d, want 0 and %d", status.InFlight, status.Total.Requests, len(cases))
	}
}

func TestRetriedRequestIsCountedOnceByItsCompletingAttempt(t *testing.T) {
	ledger, collector := newCollectedLedger()
	request := ledger.Enter()
	planned(request)
	request.NoteAttemptDispatched(coldScoped)
	request.NoteAttemptDispatched(selectedScoped)
	request.NoteAttemptCompleted(selectedScoped, completedWith(cachefunnel.LookupHit, cachefunnel.KnownTokens(2048)))
	request.Close(false)

	status := ledger.Snapshot()
	if status.Entered != 1 || status.Total.Requests != 1 || status.Total.Attempts != 2 {
		t.Fatalf("entered %d requests %d attempts %d, want 1, 1, 2", status.Entered, status.Total.Requests, status.Total.Attempts)
	}
	if hit := requestsFor(status, cachefunnel.Hit); hit.Requests != 1 || hit.Attempts != 2 {
		t.Fatalf("hit = %+v, want the one request with both attempts annotated", hit)
	}
	requireReconciled(t, status, collector.snapshot())
}

func TestHedgedRequestIsCountedOnceByTheAttemptThatCompleted(t *testing.T) {
	ledger, collector := newCollectedLedger()
	request := ledger.Enter()
	planned(request)
	request.NoteAttemptDispatched(selectedScoped)
	request.NoteAttemptDispatched(coldScoped)
	// The primary completes; the hedge dispatched after it must not reclassify
	// the request, and a second completion is ignored.
	request.NoteAttemptCompleted(selectedScoped, completedWith(cachefunnel.LookupMiss, cachefunnel.KnownTokens(0)))
	request.NoteAttemptCompleted(coldScoped, completedWith(cachefunnel.LookupHit, cachefunnel.KnownTokens(512)))
	request.Close(false)

	status := ledger.Snapshot()
	if miss := requestsFor(status, cachefunnel.SelectedMiss); miss.Requests != 1 || miss.Attempts != 2 {
		t.Fatalf("selected_miss = %+v, want one request with two attempts", miss)
	}
	if status.Total.Requests != 1 || status.Total.ReusedTokens != 0 {
		t.Fatalf("total = %+v, want one request and no reused tokens from the ignored hedge", status.Total)
	}
	requireReconciled(t, status, collector.snapshot())
}

func TestCloseIsFinal(t *testing.T) {
	ledger, collector := newCollectedLedger()
	request := ledger.Enter()
	planned(request)
	request.NoteAttemptDispatched(selectedScoped)
	request.Close(true)
	// A parked completion that lands after the client left changes nothing.
	request.NoteAttemptCompleted(selectedScoped, completedWith(cachefunnel.LookupHit, cachefunnel.KnownTokens(2048)))
	request.Close(false)

	status := ledger.Snapshot()
	if got := requestsFor(status, cachefunnel.CancelledAfterDispatch); got.Requests != 1 || status.Closed != 1 {
		t.Fatalf("cancelled_after_dispatch = %+v closed = %d, want one request closed once", got, status.Closed)
	}
	requireReconciled(t, status, collector.snapshot())
}

func TestGateRefusalIsVisibleAndARetriedPlanReplacesIt(t *testing.T) {
	ledger, collector := newCollectedLedger()
	refused := ledger.Enter()
	refused.NotePlanning(cachefunnel.PlanningGateRefused, unknownTokens)
	refused.NoteAttemptDispatched(cachefunnel.Attempt{})
	refused.NoteAttemptCompleted(cachefunnel.Attempt{}, cachefunnel.Completion{})
	refused.Close(false)

	replanned := ledger.Enter()
	replanned.NotePlanning(cachefunnel.PlanningGateRefused, unknownTokens)
	completedAs(coldScoped, completedWith(cachefunnel.LookupMiss, cachefunnel.KnownTokens(0)))(replanned)
	replanned.Close(false)

	status := ledger.Snapshot()
	gate := requestsFor(status, cachefunnel.GateRefused)
	if gate.Requests != 1 || gate.PromptTokensUnknown != 1 || gate.PromptTokens != 0 || gate.DispatchedWithoutScope != 1 {
		t.Fatalf("gate_refused = %+v, want one request with unknown prompt tokens, dispatched without scope", gate)
	}
	if cold := requestsFor(status, cachefunnel.NoRepeatObserved); cold.Requests != 1 {
		t.Fatalf("no_repeat_observed = %+v, want the request planned after its refusal", cold)
	}
	requireReconciled(t, status, collector.snapshot())
}

func TestNoPlanTerminalsKeepWhatPlanningCounted(t *testing.T) {
	ledger, collector := newCollectedLedger()
	failed := ledger.Enter()
	failed.NotePlanning(cachefunnel.PlanningFailed, unknownTokens)
	failed.Close(false)
	empty := ledger.Enter()
	empty.NotePlanning(cachefunnel.PlanningEmpty, cachefunnel.KnownTokens(200))
	empty.Close(false)

	status := ledger.Snapshot()
	if got := requestsFor(status, cachefunnel.PlanFailed); got.Requests != 1 || got.PromptTokensUnknown != 1 || got.RepeatedPrefixTokensUnknown != 1 {
		t.Fatalf("plan_failed = %+v, want one request with unknown prompt and repeated-prefix tokens", got)
	}
	if got := requestsFor(status, cachefunnel.PlanEmpty); got.Requests != 1 || got.PromptTokens != 200 || got.PromptTokensUnknown != 0 {
		t.Fatalf("plan_empty = %+v, want one request with its 200 counted prompt tokens", got)
	}
	requireReconciled(t, status, collector.snapshot())
}

func TestHitReportsFewerReusedTokensThanPredicted(t *testing.T) {
	ledger, collector := newCollectedLedger()
	request := ledger.Enter()
	planned(request)
	attempt := cachefunnel.Attempt{Routing: cachefunnel.RoutingSelected, Scoped: true, Predicted: cachefunnel.KnownTokens(3072)}
	request.NoteAttemptDispatched(attempt)
	request.NoteAttemptCompleted(attempt, completedWith(cachefunnel.LookupHit, cachefunnel.KnownTokens(1024)))
	request.Close(false)

	hit := requestsFor(ledger.Snapshot(), cachefunnel.Hit)
	if hit.Requests != 1 || hit.PromptTokens != 4096 || hit.RepeatedPrefixTokens != 2048 ||
		hit.PredictedTokens != 3072 || hit.ReusedTokens != 1024 || hit.PredictedTokensUnknown != 0 || hit.ReusedTokensUnknown != 0 {
		t.Fatalf("hit = %+v, want prompt 4096, repeated 2048, predicted 3072, reused 1024, none unknown", hit)
	}
	requireReconciled(t, ledger.Snapshot(), collector.snapshot())
}

func TestMissingUsageIsUnknownNotZero(t *testing.T) {
	ledger, collector := newCollectedLedger()
	request := ledger.Enter()
	completedAs(selectedScoped, cachefunnel.Completion{})(request)
	request.Close(false)

	got := requestsFor(ledger.Snapshot(), cachefunnel.SelectedOutcomeUnknown)
	if got.Requests != 1 || got.ReusedTokens != 0 || got.ReusedTokensUnknown != 1 ||
		got.PredictedTokensUnknown != 1 || got.LookupOutcomeReported != 0 {
		t.Fatalf("selected_outcome_unknown = %+v, want reused and predicted tokens counted as unknown", got)
	}
	record := collector.snapshot()[0]
	if record.ReusedTokens.Known || record.PredictedTokens.Known || record.LookupOutcomeReported {
		t.Fatalf("record = %+v, want reused, predicted and lookup outcome all unobserved", record)
	}
	requireReconciled(t, ledger.Snapshot(), collector.snapshot())
}
