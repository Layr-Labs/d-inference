package cachefunnel_test

import (
	"sync"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/observation/cachefunnel"
)

// recordCollector is the reconciliation seam's reader: it keeps every closed
// record so a test can rebuild the aggregates from raw records.
type recordCollector struct {
	mu      sync.Mutex
	records []cachefunnel.Record
}

func (c *recordCollector) ObserveCacheFunnelRecord(record cachefunnel.Record) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.records = append(c.records, record)
}

func (c *recordCollector) snapshot() []cachefunnel.Record {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]cachefunnel.Record(nil), c.records...)
}

func newCollectedLedger() (*cachefunnel.Ledger, *recordCollector) {
	collector := &recordCollector{}
	return cachefunnel.NewLedger(collector), collector
}

// reasonNames is the status response's own list of terminal reasons.
func reasonNames() []string {
	var names []string
	for _, totals := range cachefunnel.NewLedger(nil).Snapshot().Reasons {
		names = append(names, totals.Reason)
	}
	return names
}

// sumRecords rebuilds the per-reason totals with arithmetic that shares no
// code with the ledger.
func sumRecords(records []cachefunnel.Record) map[string]cachefunnel.Totals {
	sums := make(map[string]cachefunnel.Totals)
	for _, record := range records {
		totals := sums[record.Reason.String()]
		totals.Requests++
		totals.Attempts += uint64(record.Attempts)
		if record.DispatchedWithoutScope {
			totals.DispatchedWithoutScope++
		}
		if record.LookupOutcomeReported {
			totals.LookupOutcomeReported++
		}
		sumTokens(&totals.PromptTokens, &totals.PromptTokensUnknown, record.PromptTokens)
		sumTokens(&totals.RepeatedPrefixTokens, &totals.RepeatedPrefixTokensUnknown, record.RepeatedPrefixTokens)
		sumTokens(&totals.PredictedTokens, &totals.PredictedTokensUnknown, record.PredictedTokens)
		sumTokens(&totals.ReusedTokens, &totals.ReusedTokensUnknown, record.ReusedTokens)
		sums[record.Reason.String()] = totals
	}
	return sums
}

func sumTokens(sum, unknown *uint64, tokens cachefunnel.Tokens) {
	if tokens.Known {
		*sum += uint64(tokens.Count)
		return
	}
	*unknown++
}

// requireReconciled checks conservation and that summing the raw records
// reproduces every aggregate exactly.
func requireReconciled(t *testing.T, status cachefunnel.Status, records []cachefunnel.Record) {
	t.Helper()
	if status.Entered != status.Closed+status.InFlight {
		t.Fatalf("entered %d != closed %d + in flight %d", status.Entered, status.Closed, status.InFlight)
	}
	if status.Closed != uint64(len(records)) {
		t.Fatalf("closed %d != %d records delivered to the sink", status.Closed, len(records))
	}
	if len(status.Reasons) != len(reasonNames()) {
		t.Fatalf("status lists %d reasons, want %d", len(status.Reasons), len(reasonNames()))
	}
	want := sumRecords(records)
	var overReasons cachefunnel.Totals
	seen := make(map[string]bool)
	for _, got := range status.Reasons {
		if seen[got.Reason] {
			t.Fatalf("reason %q listed twice", got.Reason)
		}
		seen[got.Reason] = true
		if got.Totals != want[got.Reason] {
			t.Fatalf("reason %q aggregates = %+v, records sum to %+v", got.Reason, got.Totals, want[got.Reason])
		}
		overReasons.Requests += got.Requests
		overReasons.Attempts += got.Attempts
		overReasons.DispatchedWithoutScope += got.DispatchedWithoutScope
		overReasons.LookupOutcomeReported += got.LookupOutcomeReported
		overReasons.PromptTokens += got.PromptTokens
		overReasons.PromptTokensUnknown += got.PromptTokensUnknown
		overReasons.RepeatedPrefixTokens += got.RepeatedPrefixTokens
		overReasons.RepeatedPrefixTokensUnknown += got.RepeatedPrefixTokensUnknown
		overReasons.PredictedTokens += got.PredictedTokens
		overReasons.PredictedTokensUnknown += got.PredictedTokensUnknown
		overReasons.ReusedTokens += got.ReusedTokens
		overReasons.ReusedTokensUnknown += got.ReusedTokensUnknown
	}
	for reason := range want {
		if !seen[reason] {
			t.Fatalf("records carry reason %q that the status does not list", reason)
		}
	}
	if overReasons.Requests != status.Closed {
		t.Fatalf("requests over reasons = %d, closed = %d", overReasons.Requests, status.Closed)
	}
	if overReasons != status.Total {
		t.Fatalf("total = %+v, the reasons sum to %+v", status.Total, overReasons)
	}
}

func requestsFor(status cachefunnel.Status, reason cachefunnel.Reason) cachefunnel.Totals {
	for _, totals := range status.Reasons {
		if totals.Reason == reason.String() {
			return totals.Totals
		}
	}
	return cachefunnel.Totals{}
}
