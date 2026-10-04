package store_test

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func modelDemandRetainedEvidenceContract(t *testing.T, s demandTestStore) {
	t.Helper()
	ctx := context.Background()
	end := time.Now().UTC().Truncate(time.Hour)
	start := end.Add(-30 * 24 * time.Hour)
	at := end.Add(-20 * 24 * time.Hour)
	rows := make([]store.RequestOutcomeRecord, 24)
	for i := range rows {
		rows[i] = store.RequestOutcomeRecord{
			CoordRequestID: fmt.Sprintf("retained-demand-%d", i), SchemaVersion: 1, Revision: 2,
			ReceivedAt: at, UpdatedAt: at, Endpoint: "/v1/messages", HTTPStatus: 200,
			PublicDemand: &store.PublicDemandScope{Model: "retained-model", ConsumerHash: store.HashKey(fmt.Sprint(i % 3)), Outcome: "completed"},
		}
	}
	if err := s.RecordRequestOutcomes(ctx, rows); err != nil {
		t.Fatal(err)
	}
	pruneLedger := func() {
		t.Helper()
		if _, err := s.PruneTelemetry(ctx, end.Add(-14*24*time.Hour), time.Time{}, 100); err != nil {
			t.Fatal(err)
		}
	}
	check := func(unknown int64) {
		t.Helper()
		snapshot, err := s.ModelDemand(ctx, start, end)
		if err != nil {
			t.Fatal(err)
		}
		if len(snapshot.Models) != 1 {
			t.Fatalf("retained model cohort: %+v", snapshot)
		}
		assertModelDemandPublishedSums(t, snapshot.Models)
		model := snapshot.Models[0]
		want := store.DemandOutcomeCounts{Requests: 24, Completed: 24 - unknown, Unknown: unknown}
		if model.Model != "retained-model" || model.DemandOutcomeCounts != want {
			t.Fatalf("retained totals: %+v, want %+v", model, want)
		}
		bucket := model.TimeSeries[10].Counts
		if bucket == nil || *bucket != want {
			t.Fatalf("original receipt cohort: %+v, want %+v", bucket, want)
		}
	}
	pruneLedger()
	if err := s.RecordRequestOutcomes(ctx, rows[:1]); err != nil {
		t.Fatal(err)
	}
	check(0) // An identical replay after ledger expiry is still idempotent.

	mutations := []struct {
		name  string
		apply func(*store.RequestOutcomeRecord)
	}{
		{"same revision outcome", func(r *store.RequestOutcomeRecord) { r.PublicDemand.Outcome = "failed" }},
		{"same revision status", func(r *store.RequestOutcomeRecord) { r.HTTPStatus = 429 }},
		{"new revision receipt", func(r *store.RequestOutcomeRecord) { r.Revision++; r.ReceivedAt = end.Add(time.Hour) }},
		{"new revision model", func(r *store.RequestOutcomeRecord) { r.Revision++; r.PublicDemand.Model = "changed-model" }},
		{"new revision consumer", func(r *store.RequestOutcomeRecord) {
			r.Revision++
			r.PublicDemand.ConsumerHash = store.HashKey("changed-consumer")
		}},
	}
	for i, mutation := range mutations {
		t.Log(mutation.name)
		pruneLedger()
		conflict := cloneRequestOutcomeFixture(rows[i])
		mutation.apply(&conflict)
		if err := s.RecordRequestOutcomes(ctx, []store.RequestOutcomeRecord{conflict}); err != nil {
			t.Fatal(err)
		}
		check(int64(i + 1))
		// Losing the diagnostic ledger again must not erase the conflict,
		// even when a newer revision claims successful completion.
		pruneLedger()
		newer := rows[i]
		newer.Revision = conflict.Revision + 1
		if err := s.RecordRequestOutcomes(ctx, []store.RequestOutcomeRecord{newer}); err != nil {
			t.Fatal(err)
		}
		check(int64(i + 1))
	}
}

func TestModelDemandRetainedEvidenceMemory(t *testing.T) {
	modelDemandRetainedEvidenceContract(t, memory.NewMemory(store.Config{}))
}

func TestModelDemandRetainedEvidencePostgres(t *testing.T) {
	modelDemandRetainedEvidenceContract(t, testPostgresStore(t))
}
