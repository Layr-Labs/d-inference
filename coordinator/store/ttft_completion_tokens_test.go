package store

import (
	"testing"
	"time"
)

// assertCancelledRowPersistsZeroCompletionTokens drives the shared scenario
// against any Store impl: a route row gets a stale non-zero completion count from
// an earlier (non-terminal) update, then a terminal cancel with
// CompletionTokensSet=true must FORCE-write 0 — proving the flag overrides the
// "treat 0 as absent" merge so the 0-token cancel population is queryable (not
// NULL / not the stale value).
func assertCancelledRowPersistsZeroCompletionTokens(t *testing.T, s Store) {
	t.Helper()
	const reqID = "req-cancel-0tok"

	if err := s.RecordInferenceRoute(&InferenceRouteRecord{
		RequestID: reqID,
		Attempt:   0,
		Model:     "gpt-oss-20b",
		Outcome:   "selected",
		CreatedAt: time.Now(),
	}); err != nil {
		t.Fatalf("RecordInferenceRoute: %v", err)
	}

	// Stale non-zero count from a non-terminal update (no flag).
	if err := s.UpdateInferenceRouteOutcome(reqID, 0, &InferenceRouteOutcome{CompletionTokens: 7}); err != nil {
		t.Fatalf("stale update: %v", err)
	}

	// Terminal cancel: 0 tokens delivered, force-persisted via the flag.
	if err := s.UpdateInferenceRouteOutcome(reqID, 0, &InferenceRouteOutcome{
		FinalStatus:         "cancelled",
		ErrorClass:          "client_gone",
		CompletionTokens:    0,
		CompletionTokensSet: true,
	}); err != nil {
		t.Fatalf("terminal cancel update: %v", err)
	}

	all := s.InferenceRouteRecordsSince(time.Time{})
	var got *InferenceRouteRecord
	for i := range all {
		if all[i].RequestID == reqID {
			got = &all[i]
			break
		}
	}
	if got == nil {
		t.Fatalf("route row %q not found", reqID)
	}
	if got.FinalStatus != "cancelled" {
		t.Fatalf("final_status = %q, want cancelled", got.FinalStatus)
	}
	if got.CompletionTokens != 0 {
		t.Fatalf("completion_tokens = %d, want 0 (forced, not the stale 7)", got.CompletionTokens)
	}
}

func TestMemoryCancelledRowPersistsZeroCompletionTokens(t *testing.T) {
	assertCancelledRowPersistsZeroCompletionTokens(t, NewMemory(Config{}))
}

func TestPostgresCancelledRowPersistsZeroCompletionTokens(t *testing.T) {
	assertCancelledRowPersistsZeroCompletionTokens(t, testPostgresStore(t))
}
