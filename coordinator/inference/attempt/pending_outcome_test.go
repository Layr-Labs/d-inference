package attempt

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type pendingPublicationObserver struct {
	cache func(*registry.PendingRequest)
	route func(string, int, string, *store.InferenceRouteOutcome)
}

func (o pendingPublicationObserver) CacheTerminal(pr *registry.PendingRequest) { o.cache(pr) }
func (o pendingPublicationObserver) RouteOutcome(id string, n int, model string, outcome *store.InferenceRouteOutcome) {
	o.route(id, n, model, outcome)
}

func TestPendingOutcomePublishesAfterClaimAndProfileWithoutHoldingRequestLock(t *testing.T) {
	ap := &registry.AttemptProfile{}
	pr := &registry.PendingRequest{RequestID: "before-cache", Attempt: 1, Model: "before-model", Profile: ap}
	outcome := &store.InferenceRouteOutcome{FinalStatus: "error", ErrorClass: "first_chunk_timeout"}
	cacheCalls, routeCalls := 0, 0
	var observer pendingPublicationObserver
	observer.cache = func(got *registry.PendingRequest) {
		cacheCalls++
		if cacheCalls > 1 {
			t.Error("reentrant publication acquired an already finalized terminal")
			return
		}
		if got != pr {
			t.Error("cache publication received a different pending request")
		}
		status, reason, _, _, _ := ap.Outcome()
		if status != "error" || reason != "first_chunk_timeout" || !ap.TerminalRecorded() {
			t.Errorf("cache publication preceded profile completion: %q %q terminal=%v", status, reason, ap.TerminalRecorded())
		}
		// Re-enter the actual claim operation from the observer. A held request
		// lock would deadlock; a missing claim would publish a second terminal.
		PublishPendingOutcome(pr, outcome, observer)
		pr.RequestID, pr.Attempt, pr.Model = "after-cache", 2, "after-model"
	}
	observer.route = func(id string, n int, model string, got *store.InferenceRouteOutcome) {
		routeCalls++
		if cacheCalls != 1 || id != "after-cache" || n != 2 || model != "after-model" || got != outcome {
			t.Errorf("route publication lost post-cache identity/order: cache=%d id=%q attempt=%d model=%q outcome=%p", cacheCalls, id, n, model, got)
		}
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		PublishPendingOutcome(pr, outcome, observer)
	}()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("pending outcome publication held a request lock across its observer")
	}
	if cacheCalls != 1 || routeCalls != 1 {
		t.Fatalf("terminal published cache=%d route=%d times, want one each", cacheCalls, routeCalls)
	}
	PublishPendingOutcome(pr, &store.InferenceRouteOutcome{FinalStatus: "success"}, observer)
	if cacheCalls != 1 || routeCalls != 1 {
		t.Fatal("losing terminal claim invoked an observer")
	}
}

func TestPendingOutcomeLeavesProviderOwnedProfileCompletionToProvider(t *testing.T) {
	for _, tc := range []struct {
		name    string
		status  string
		claimed bool
	}{
		{name: "successful commit", status: "success"},
		{name: "claimed error frame", status: "error", claimed: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ap := &registry.AttemptProfile{}
			if tc.claimed {
				ap.ClaimTerminal()
			}
			pr := &registry.PendingRequest{RequestID: tc.name, Profile: ap}
			calls := 0
			observer := pendingPublicationObserver{
				cache: func(*registry.PendingRequest) {
					if ap.TerminalRecorded() {
						t.Error("publication completed the provider-owned terminal")
					}
				},
				route: func(string, int, string, *store.InferenceRouteOutcome) { calls++ },
			}
			PublishPendingOutcome(pr, &store.InferenceRouteOutcome{FinalStatus: tc.status}, observer)
			status, _, _, _, _ := ap.Outcome()
			if status != tc.status || ap.TerminalRecorded() || calls != 1 {
				t.Fatalf("outcome=%q terminal=%v publications=%d", status, ap.TerminalRecorded(), calls)
			}
			ap.CompleteTerminal()
			if !ap.TerminalRecorded() {
				t.Fatal("provider could not complete its terminal")
			}
		})
	}
}

func TestPendingOutcomeNonterminalPublicationDoesNotClaimOrMutateProfile(t *testing.T) {
	PublishPendingOutcome(nil, nil, nil)
	for _, outcome := range []*store.InferenceRouteOutcome{nil, {}} {
		ap := &registry.AttemptProfile{}
		pr := &registry.PendingRequest{RequestID: "request", Attempt: 3, Model: "model", Profile: ap}
		calls := 0
		observer := pendingPublicationObserver{
			cache: func(*registry.PendingRequest) { t.Error("nonterminal publication closed cache telemetry") },
			route: func(id string, n int, model string, got *store.InferenceRouteOutcome) {
				calls++
				if id != "request" || n != 3 || model != "model" || got != outcome {
					t.Error("nonterminal publication lost the original identity or outcome")
				}
			},
		}
		PublishPendingOutcome(pr, outcome, observer)
		status, reason, _, _, _ := ap.Outcome()
		if calls != 1 || status != "" || reason != "" || ap.TerminalRecorded() || !pr.MarkRouteOutcomeFinalized() {
			t.Fatalf("nonterminal publication changed profile or claim: calls=%d status=%q reason=%q terminal=%v", calls, status, reason, ap.TerminalRecorded())
		}
	}
}
