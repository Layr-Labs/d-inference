package cachefunnel_test

import (
	"encoding/json"
	"sync"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/observation/cachefunnel"
)

func TestRequestOutsideThePopulationIsNeverCounted(t *testing.T) {
	var ledger *cachefunnel.Ledger
	request := ledger.Enter()
	planned(request)
	request.NoteAttemptDispatched(selectedScoped)
	request.NoteAttemptCompleted(selectedScoped, cachefunnel.Completion{})
	request.Close(false)

	status := ledger.Snapshot()
	if request != nil || status.Entered != 0 || len(status.Reasons) != len(reasonNames()) {
		t.Fatalf("request = %v status = %+v, want no request and an all-zero funnel listing every reason", request, status)
	}
}

func TestLedgerKeepsNoRecordsWithoutASink(t *testing.T) {
	ledger := cachefunnel.NewLedger(nil)
	request := ledger.Enter()
	planned(request)
	request.Close(false)
	if status := ledger.Snapshot(); status.Closed != 1 || requestsFor(status, cachefunnel.ErroredBeforeDispatch).Requests != 1 {
		t.Fatalf("status = %+v, want the aggregate counted with no sink installed", status)
	}
}

func TestConcurrentRequestsConserve(t *testing.T) {
	ledger, collector := newCollectedLedger()
	cases := everyLifecycle()
	const rounds = 40
	var wait sync.WaitGroup
	for range rounds {
		for _, c := range cases {
			wait.Add(1)
			go func() {
				defer wait.Done()
				request := ledger.Enter()
				c.drive(request)
				var closers sync.WaitGroup
				for range 2 {
					closers.Add(1)
					go func() { defer closers.Done(); request.Close(c.cancelled) }()
				}
				closers.Wait()
			}()
		}
	}
	wait.Wait()

	status := ledger.Snapshot()
	if want := uint64(rounds * len(cases)); status.Entered != want || status.Closed != want || status.InFlight != 0 {
		t.Fatalf("entered %d closed %d in flight %d, want %d, %d, 0", status.Entered, status.Closed, status.InFlight, want, want)
	}
	lifecycles := make(map[cachefunnel.Reason]uint64)
	for _, c := range cases {
		lifecycles[c.want] += rounds
	}
	for reason, want := range lifecycles {
		if got := requestsFor(status, reason).Requests; got != want {
			t.Fatalf("reason %s counts %d requests, want %d", reason, got, want)
		}
	}
	requireReconciled(t, status, collector.snapshot())
}

// The handler closes a request while provider readers may still be reporting
// on it. Whichever side wins, the request is counted once and the record the
// sink received is the one the aggregates hold.
func TestEvidenceRacingCloseStillReconciles(t *testing.T) {
	ledger, collector := newCollectedLedger()
	const requests = 400
	var wait sync.WaitGroup
	for range requests {
		request := ledger.Enter()
		planned(request)
		wait.Add(3)
		go func() { defer wait.Done(); request.NoteAttemptDispatched(selectedScoped) }()
		go func() {
			defer wait.Done()
			request.NoteAttemptCompleted(selectedScoped, completedWith(cachefunnel.LookupHit, cachefunnel.KnownTokens(2048)))
		}()
		go func() { defer wait.Done(); request.Close(false) }()
	}
	wait.Wait()

	status := ledger.Snapshot()
	if status.Entered != requests || status.Closed != requests || status.InFlight != 0 {
		t.Fatalf("entered %d closed %d in flight %d, want %d, %d, 0", status.Entered, status.Closed, status.InFlight, requests, requests)
	}
	// Close can only have seen: nothing, the dispatch alone, or the completion.
	seen := requestsFor(status, cachefunnel.ErroredBeforeDispatch).Requests +
		requestsFor(status, cachefunnel.ErroredAfterDispatch).Requests + requestsFor(status, cachefunnel.Hit).Requests
	if seen != requests {
		t.Fatalf("status = %+v, want every request under one of the three reasons the race allows", status)
	}
	// Evidence that lost the race to Close is counted as late, never dropped.
	if got := requestsFor(status, cachefunnel.Hit).Requests + status.Late.Completions; got != requests {
		t.Fatalf("hits %d + late completions %d = %d, want all %d completions accounted for",
			requestsFor(status, cachefunnel.Hit).Requests, status.Late.Completions, got, requests)
	}
	if got := status.Total.Attempts + status.Late.AttemptDispatches; got != requests {
		t.Fatalf("attempts %d + late attempt dispatches %d = %d, want all %d dispatch notes accounted for",
			status.Total.Attempts, status.Late.AttemptDispatches, got, requests)
	}
	requireReconciled(t, status, collector.snapshot())
}

func TestStatusNamesWhatItCannotObserve(t *testing.T) {
	encoded, err := json.Marshal(cachefunnel.NewLedger(nil).Snapshot())
	if err != nil {
		t.Fatal(err)
	}
	var decoded struct {
		Reasons    []map[string]any    `json:"reasons"`
		Unobserved []map[string]string `json:"unobserved"`
	}
	if err := json.Unmarshal(encoded, &decoded); err != nil {
		t.Fatal(err)
	}
	// The lifecycle table is in lifecycle order and reaches every reason.
	var lifecycleOrder []string
	for _, c := range everyLifecycle() {
		if len(lifecycleOrder) == 0 || lifecycleOrder[len(lifecycleOrder)-1] != c.want.String() {
			lifecycleOrder = append(lifecycleOrder, c.want.String())
		}
	}
	if len(decoded.Reasons) != len(lifecycleOrder) {
		t.Fatalf("encoded %d reasons, want %d", len(decoded.Reasons), len(lifecycleOrder))
	}
	for i, reason := range lifecycleOrder {
		if decoded.Reasons[i]["reason"] != reason {
			t.Fatalf("reason %d = %v, want %s in lifecycle order", i, decoded.Reasons[i]["reason"], reason)
		}
	}
	stages := make(map[string]bool)
	for _, stage := range decoded.Unobserved {
		if stage["reason"] == "" {
			t.Fatalf("unobserved stage %q has no reason", stage["stage"])
		}
		stages[stage["stage"]] = true
	}
	if len(stages) != 1 || !stages["lookup_receipt"] {
		t.Fatalf("unobserved = %v, want lookup_receipt and nothing else declared", decoded.Unobserved)
	}
}
