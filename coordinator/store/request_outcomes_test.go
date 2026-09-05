package store

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/outcomes"
)

func outcomeStoreRecord(id string, received time.Time) outcomes.Record {
	tr := outcomes.New(id, "/v1/chat/completions", received, nil)
	tr.Shape("fixture-model", true)
	a := tr.NewAttempt(id+"-attempt", 0, "")
	a.Observe("write_completed", "", 0)
	a.Observe("committed", "", 0)
	a.Observe("provider_complete", "", 0)
	tr.Egress(true, false, "completed")
	tr.Finish(200, false, false)
	return tr.Snapshot()
}

func readOutcomeRows(t *testing.T, s RequestOutcomeStore, from, to time.Time) []outcomes.Record {
	t.Helper()
	rows, err := s.RequestOutcomesBetween(context.Background(), from, to, 100)
	if err != nil {
		t.Fatal(err)
	}
	return rows
}

func TestRequestOutcomesReplayAndReceiptWindows(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			from := time.Date(2026, 11, 1, 5, 0, 0, 0, time.UTC) // repeated ET fall-back hour
			to := from.Add(time.Hour)
			terminal := outcomeStoreRecord("window-request", from)
			initial := outcomes.New(terminal.CoordRequestID, terminal.Endpoint, from, nil).Snapshot()
			boundary := outcomeStoreRecord("next-window", to)
			if err := s.RecordRequestOutcomes([]*outcomes.Record{&terminal, &initial, &terminal, &boundary}); err != nil {
				t.Fatal(err)
			}
			rows := readOutcomeRows(t, s, from, to)
			if len(rows) != 1 || rows[0].CoordRequestID != terminal.CoordRequestID || rows[0].Termination != "completed" || rows[0].EvidenceConflict {
				t.Fatalf("replay or receipt window drifted: %+v", rows)
			}
			later := terminal
			later.Revision++
			later.ObservedAt = to.Add(time.Hour)
			if err := s.RecordRequestOutcomes([]*outcomes.Record{&later}); err != nil {
				t.Fatal(err)
			}
			if rows = readOutcomeRows(t, s, from, to); len(rows) != 1 || rows[0].Revision != later.Revision {
				t.Fatalf("late evidence lost original request: %+v", rows)
			}
			if rows = readOutcomeRows(t, s, to, to.Add(time.Hour)); len(rows) != 1 || rows[0].CoordRequestID != boundary.CoordRequestID {
				t.Fatalf("late persistence double-counted adjacent window: %+v", rows)
			}
		})
	}
}

func TestRequestOutcomesConflictsAreSticky(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			from := time.Date(2026, 9, 5, 0, 0, 0, 0, time.UTC)
			r := outcomeStoreRecord("conflicting-request", from)
			if err := s.RecordRequestOutcomes([]*outcomes.Record{&r}); err != nil {
				t.Fatal(err)
			}
			conflict := r
			conflict.Termination = "rejected"
			if err := s.RecordRequestOutcomes([]*outcomes.Record{&conflict}); err != nil {
				t.Fatal(err)
			}
			rows := readOutcomeRows(t, s, from, from.Add(time.Hour))
			if len(rows) != 1 || !rows[0].EvidenceConflict || rows[0].Termination != "completed" {
				t.Fatalf("same-revision conflict selected arbitrary outcome: %+v", rows)
			}
			r.Revision++
			if err := s.RecordRequestOutcomes([]*outcomes.Record{&r}); err != nil {
				t.Fatal(err)
			}
			if rows = readOutcomeRows(t, s, from, from.Add(time.Hour)); len(rows) != 1 || !rows[0].EvidenceConflict {
				t.Fatalf("new revision hid conflict: %+v", rows)
			}
			reused := r
			reused.Revision++
			reused.ReceivedAt = from.Add(time.Hour)
			reused.Endpoint = "/v1/messages"
			if err := s.RecordRequestOutcomes([]*outcomes.Record{&reused}); err != nil {
				t.Fatal(err)
			}
			if rows = readOutcomeRows(t, s, from.Add(time.Hour), from.Add(2*time.Hour)); len(rows) != 0 {
				t.Fatalf("reused ID moved cohort: %+v", rows)
			}
			rows = readOutcomeRows(t, s, from, from.Add(time.Hour))
			if len(rows) != 1 || !rows[0].EvidenceConflict || rows[0].Endpoint != r.Endpoint {
				t.Fatalf("identity conflict overwrote authoritative identity: %+v", rows)
			}
		})
	}
}

func TestRequestOutcomesRejectMissingIdentityAndBoundHistory(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			for _, id := range []string{"", " \t", strings.Repeat("x", 65)} {
				r := outcomeStoreRecord(id, time.Now())
				if err := s.RecordRequestOutcomes([]*outcomes.Record{&r}); err == nil {
					t.Errorf("accepted invalid request ID %q", id)
				}
			}
			r := outcomeStoreRecord("oversized-history", time.Now())
			r.Attempts = make([]outcomes.AttemptRecord, outcomes.MaxAttempts+1)
			if err := s.RecordRequestOutcomes([]*outcomes.Record{&r}); err == nil {
				t.Fatal("accepted unbounded attempt history")
			}
		})
	}
}

func TestRequestOutcomesLateConflictCannotBeHiddenByRevision(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			from := time.Date(2026, 9, 5, 0, 0, 0, 0, time.UTC)
			terminal := outcomeStoreRecord("late-conflict", from)
			older := terminal
			older.Revision--
			older.EvidenceConflict = true
			if err := s.RecordRequestOutcomes([]*outcomes.Record{&terminal, &older}); err != nil {
				t.Fatal(err)
			}
			rows := readOutcomeRows(t, s, from, from.Add(time.Hour))
			if len(rows) != 1 || !rows[0].EvidenceConflict || rows[0].Revision != terminal.Revision {
				t.Fatalf("late conflict hidden by revision: %+v", rows)
			}
		})
	}
}

func TestRequestOutcomesPruneAndReadAreBounded(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			from := time.Date(2026, 9, 5, 0, 0, 0, 0, time.UTC)
			var records []*outcomes.Record
			for _, id := range []string{"prune-a", "prune-b", "prune-c"} {
				r := outcomeStoreRecord(id, from)
				records = append(records, &r)
			}
			boundary := outcomeStoreRecord("keep-boundary", from.Add(time.Hour))
			records = append(records, &boundary)
			if err := s.RecordRequestOutcomes(records); err != nil {
				t.Fatal(err)
			}
			rows, err := s.RequestOutcomesBetween(context.Background(), from, from.Add(2*time.Hour), 2)
			if err != nil || len(rows) != 2 || rows[0].CoordRequestID != boundary.CoordRequestID {
				t.Fatalf("bounded ordered read: rows=%+v err=%v", rows, err)
			}
			n, err := s.PruneRequestOutcomes(context.Background(), boundary.ReceivedAt, 2)
			if err != nil || n != 2 {
				t.Fatalf("bounded prune=%d err=%v", n, err)
			}
			if rows = readOutcomeRows(t, s, from, from.Add(2*time.Hour)); len(rows) != 2 {
				t.Fatalf("prune exceeded batch: %+v", rows)
			}
			n, err = s.PruneRequestOutcomes(context.Background(), boundary.ReceivedAt, 2)
			if err != nil || n != 1 {
				t.Fatalf("second prune=%d err=%v", n, err)
			}
			if rows = readOutcomeRows(t, s, from, from.Add(2*time.Hour)); len(rows) != 1 || rows[0].CoordRequestID != boundary.CoordRequestID {
				t.Fatalf("prune removed boundary: %+v", rows)
			}
		})
	}
}

func TestMemoryRequestOutcomesDoNotAliasCallerRecords(t *testing.T) {
	s := NewMemory(Config{})
	from := time.Date(2026, 9, 5, 0, 0, 0, 0, time.UTC)
	r := outcomeStoreRecord("immutable-record", from)
	if err := s.RecordRequestOutcomes([]*outcomes.Record{&r}); err != nil {
		t.Fatal(err)
	}
	r.Attempts[0].RawReason = "caller-mutated"
	*r.HTTPStatus = 500
	rows := readOutcomeRows(t, s, from, from.Add(time.Hour))
	if *rows[0].HTTPStatus != 200 || rows[0].Attempts[0].RawReason != "" {
		t.Fatalf("write aliases caller: %+v", rows)
	}
	*rows[0].HTTPStatus = 503
	rows[0].Attempts[0].RawReason = "reader-mutated"
	rows = readOutcomeRows(t, s, from, from.Add(time.Hour))
	if *rows[0].HTTPStatus != 200 || rows[0].Attempts[0].RawReason != "" {
		t.Fatalf("read aliases storage: %+v", rows)
	}
}
