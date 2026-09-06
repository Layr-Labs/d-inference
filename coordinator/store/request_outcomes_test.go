package store

import (
	"context"
	"testing"
	"time"
)

func requestOutcomeStoreContract(t *testing.T, s RequestOutcomeStore) {
	t.Helper()
	ctx := context.Background()
	now := time.Now()
	r := RequestOutcomeRecord{CoordRequestID: "coord-1", SchemaVersion: 1, Revision: 1, ReceivedAt: now, UpdatedAt: now, Endpoint: "/v1/messages", Termination: "in_progress", Attempts: []RequestAttemptOutcome{}}
	write := func(rows ...RequestOutcomeRecord) {
		t.Helper()
		if err := s.RecordRequestOutcomes(ctx, rows); err != nil {
			t.Fatal(err)
		}
	}
	read := func() RequestOutcomeRecord {
		t.Helper()
		rows, err := s.RequestOutcomes(ctx, now.Add(-time.Second), now.Add(time.Second), 10)
		if err != nil || len(rows) != 1 {
			t.Fatalf("read %v %v", rows, err)
		}
		return rows[0]
	}
	write(r, r)
	if got := read(); got.EvidenceConflict {
		t.Fatalf("identical replay falsely conflicted: %+v", got)
	}
	r.Revision = 2
	r.Termination = "client_departure"
	r.Attempts = []RequestAttemptOutcome{{RequestID: "attempt-1", Attempt: 0, WriteCompleted: true, ProviderOutcome: "completed", Finalized: true}}
	write(r)
	stale := r
	stale.Revision = 1
	stale.Termination = "in_progress"
	write(stale)
	if got := read(); got.Revision != 2 || got.Termination != "client_departure" || got.EvidenceConflict {
		t.Fatalf("stale update corrupted %+v", got)
	}
	flagged := r
	flagged.Revision = 1
	flagged.EvidenceConflict = true
	write(flagged)
	if got := read(); !got.EvidenceConflict {
		t.Fatal("stale conflict observation lost")
	}
	r.Termination = "completed"
	write(r)
	if got := read(); !got.EvidenceConflict || got.Termination != "client_departure" {
		t.Fatalf("same-revision conflict lost %+v", got)
	}
	r.Revision = 3
	r.ReceivedAt = now.Add(time.Hour)
	r.Endpoint = "/v1/completions"
	write(r)
	if got := read(); !got.EvidenceConflict || !got.ReceivedAt.Equal(now) || got.Endpoint != "/v1/messages" {
		t.Fatalf("identity moved: %+v", got)
	}
	// Losing a receipt snapshot does not move the cohort to terminal time;
	// losing a terminal snapshot must leave an explicitly unfinished row.
	receiptOnly := RequestOutcomeRecord{CoordRequestID: "receipt-only", SchemaVersion: 1, Revision: 1, ReceivedAt: now.Add(-3 * time.Hour), UpdatedAt: now, Termination: "in_progress", Attempts: []RequestAttemptOutcome{}}
	terminalOnly := receiptOnly
	terminalOnly.CoordRequestID = "terminal-only"
	terminalOnly.Revision = 3
	terminalOnly.Termination = "completed"
	terminalOnly.FinalizedAt = &now
	write(receiptOnly, terminalOnly)
	partial, err := s.RequestOutcomes(ctx, now.Add(-4*time.Hour), now.Add(-2*time.Hour), 10)
	if err != nil || len(partial) != 2 {
		t.Fatalf("snapshot-loss cohort shifted: %+v %v", partial, err)
	}
	for _, got := range partial {
		if got.CoordRequestID == "receipt-only" && (got.FinalizedAt != nil || got.Termination != "in_progress") {
			t.Fatalf("lost final snapshot fabricated completion: %+v", got)
		}
		if !got.ReceivedAt.Equal(receiptOnly.ReceivedAt) {
			t.Fatal("terminal-only snapshot lost original receipt")
		}
	}

	rows, err := s.RequestOutcomes(ctx, now, now, 10)
	if err != nil || len(rows) != 0 {
		t.Fatal("empty interval is not empty", rows, err)
	}
	r.CoordRequestID = ""
	if err := s.RecordRequestOutcomes(ctx, []RequestOutcomeRecord{r}); err == nil {
		t.Fatal("empty identity accepted")
	}
	r.CoordRequestID = "oversized"
	r.Attempts = make([]RequestAttemptOutcome, MaxRequestOutcomeAttempts+1)
	if err := s.RecordRequestOutcomes(ctx, []RequestOutcomeRecord{r}); err == nil {
		t.Fatal("oversized attempt history accepted")
	}
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	if _, err := s.RequestOutcomes(cancelled, now, now.Add(time.Hour), 10); err == nil {
		t.Fatal("cancelled read silently became known zero")
	}
}
func TestMemoryRequestOutcomeContract(t *testing.T) {
	requestOutcomeStoreContract(t, NewMemory(Config{}))
}
func TestPostgresRequestOutcomeContract(t *testing.T) {
	requestOutcomeStoreContract(t, testPostgresStore(t))
}
func TestRequestOutcomeRetention(t *testing.T) {
	for _, backend := range []string{"memory", "postgres"} {
		t.Run(backend, func(t *testing.T) {
			var s Store
			if backend == "memory" {
				s = NewMemory(Config{})
			} else {
				s = testPostgresStore(t)
			}
			ctx := context.Background()
			now := time.Now()
			r := RequestOutcomeRecord{CoordRequestID: "old", SchemaVersion: 1, Revision: 1, ReceivedAt: now.Add(-48 * time.Hour), UpdatedAt: now, Attempts: []RequestAttemptOutcome{}}
			if err := s.RecordRequestOutcomes(ctx, []RequestOutcomeRecord{r}); err != nil {
				t.Fatal(err)
			}
			if _, err := s.PruneTelemetry(ctx, now.Add(-24*time.Hour), time.Time{}, 2); err != nil {
				t.Fatal(err)
			}
			rows, err := s.RequestOutcomes(ctx, time.Time{}, now, 10)
			if err != nil || len(rows) != 0 {
				t.Fatalf("retention %v %v", rows, err)
			}
		})
	}
}
