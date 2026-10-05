package postgres_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// TestPostgresRouteWritesAfterPoolCloseAreTransient pins the shutdown case the
// sink relies on: once the pool is closed every route write fails with an
// error the classifier calls transient, so the sink drops the group instead
// of replaying N rows that would each fail the same way.
func TestPostgresRouteWritesAfterPoolCloseAreTransient(t *testing.T) {
	s := tracedPostgresStore(t, &statementCounter{})
	s.pool.Close()

	id := uniqueID("closed")
	records := []*store.InferenceRouteRecord{
		{RequestID: id + "-1", Attempt: 1, Outcome: "selected"},
		{RequestID: id + "-2", Attempt: 1, Outcome: "selected"},
	}
	if err := s.RecordInferenceRoutes(records); err == nil || !store.IsTransientWriteError(err) {
		t.Fatalf("batch insert on closed pool: err=%v, want transient", err)
	}
	if err := s.RecordInferenceRoute(records[0]); err == nil || !store.IsTransientWriteError(err) {
		t.Fatalf("single insert on closed pool: err=%v, want transient", err)
	}
	updates := []store.InferenceRouteOutcomeUpdate{
		{RequestID: id + "-1", Attempt: 1, Outcome: &store.InferenceRouteOutcome{FinalStatus: "success"}},
		{RequestID: id + "-2", Attempt: 1, Outcome: &store.InferenceRouteOutcome{FinalStatus: "success"}},
	}
	if err := s.UpdateInferenceRouteOutcomes(updates); err == nil || !store.IsTransientWriteError(err) {
		t.Fatalf("batch update on closed pool: err=%v, want transient", err)
	}
	if err := s.UpdateInferenceRouteOutcome(id+"-1", 1, updates[0].Outcome); err == nil || !store.IsTransientWriteError(err) {
		t.Fatalf("single update on closed pool: err=%v, want transient", err)
	}
}
