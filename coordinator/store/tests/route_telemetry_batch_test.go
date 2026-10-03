package store_test

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/internal/shared"
)

func TestInferenceRouteBatch(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) { testInferenceRouteBatch(t, s) })
	}
}

func testInferenceRouteBatch(t *testing.T, s store.Store) {
	t.Helper()

	if err := s.RecordInferenceRoutes(nil); err != nil {
		t.Fatalf("RecordInferenceRoutes(nil): %v", err)
	}
	if err := s.RecordInferenceRoutes([]*store.InferenceRouteRecord{nil}); err != nil {
		t.Fatalf("RecordInferenceRoutes([nil]): %v", err)
	}
	if err := s.UpdateInferenceRouteOutcomes(nil); err != nil {
		t.Fatalf("UpdateInferenceRouteOutcomes(nil): %v", err)
	}

	prefix := uniqueID("batch")
	id := func(i int) string { return fmt.Sprintf("%s-%d", prefix, i) }
	firstCreated := time.Now().Add(-time.Hour).UTC().Truncate(time.Microsecond)

	// One batch: four distinct keys, one re-record of key 1 (queued -> selected,
	// the live dispatch.go pattern) and a nil entry. The re-record must land
	// AFTER the first write (later record wins the snapshot) and must keep the
	// original created_at, exactly like sequential single-row upserts.
	records := []*store.InferenceRouteRecord{
		{RequestID: id(1), Attempt: 1, ProviderID: "", Outcome: "queued", Model: "m", CreatedAt: firstCreated, UpdatedAt: firstCreated},
		{RequestID: id(2), Attempt: 1, ProviderID: "p2", Outcome: "selected", Model: "m", CandidateCount: 2},
		nil,
		{RequestID: id(3), Attempt: 1, ProviderID: "p3", Outcome: "selected", Model: "m", ProviderRegion: "us-east"},
		{RequestID: id(1), Attempt: 1, ProviderID: "p1", Outcome: "selected", Model: "m", CandidateCount: 5},
		{RequestID: id(1), Attempt: 2, ProviderID: "p1b", Outcome: "selected", Model: "m"},
	}
	if err := s.RecordInferenceRoutes(records); err != nil {
		t.Fatalf("RecordInferenceRoutes: %v", err)
	}

	// One pipelined update batch, in order: a commit-style latency update, a
	// terminal on the same key (must merge on top, not replace), a terminal for
	// another key, a nil outcome (skipped), and an unknown key (no-op).
	updates := []store.InferenceRouteOutcomeUpdate{
		{RequestID: id(1), Attempt: 1, Outcome: &store.InferenceRouteOutcome{ActualTTFTMs: 42, UsedBackup: true}},
		{RequestID: id(1), Attempt: 1, Outcome: &store.InferenceRouteOutcome{FinalStatus: "error", ErrorCode: 502, ErrorClass: "provider_error", CompletionTokensSet: true}},
		{RequestID: id(1), Attempt: 1, Outcome: &store.InferenceRouteOutcome{FinalStatus: "partial_success"}},
		{RequestID: id(2), Attempt: 1, Outcome: &store.InferenceRouteOutcome{FinalStatus: "success", PromptTokens: 10, CompletionTokens: 20, CostMicroUSD: 7, CompletionTokensSet: true}},
		{RequestID: id(3), Attempt: 1, Outcome: nil},
		{RequestID: id(3) + "-missing", Attempt: 9, Outcome: &store.InferenceRouteOutcome{FinalStatus: "success"}},
	}
	if err := s.UpdateInferenceRouteOutcomes(updates); err != nil {
		t.Fatalf("UpdateInferenceRouteOutcomes: %v", err)
	}

	byKey := map[string]store.InferenceRouteRecord{}
	for _, r := range s.InferenceRouteRecordsSince(time.Time{}) {
		if strings.HasPrefix(r.RequestID, prefix) {
			byKey[shared.InferenceRouteKey(r.RequestID, r.Attempt)] = r
		}
	}
	if len(byKey) != 4 {
		t.Fatalf("rows = %d, want 4 (nil skipped, duplicate merged): %v", len(byKey), byKey)
	}

	r1 := byKey[shared.InferenceRouteKey(id(1), 1)]
	if r1.ProviderID != "p1" || r1.Outcome != "selected" || r1.CandidateCount != 5 {
		t.Fatalf("re-recorded row must carry the LATER snapshot: %+v", r1)
	}
	if !r1.CreatedAt.Equal(firstCreated) {
		t.Fatalf("re-record must keep the first created_at: got %v want %v", r1.CreatedAt, firstCreated)
	}
	// Ordered merge: latency from update 1, error from update 2, final status
	// overridden by update 3 while error_code/class (zero in update 3) survive.
	if r1.FinalStatus != "partial_success" || r1.ErrorCode != 502 || r1.ErrorClass != "provider_error" || r1.ActualTTFTMs != 42 || !r1.UsedBackup {
		t.Fatalf("ordered outcome merge wrong: %+v", r1)
	}
	if r1.CompletionTokens != 0 {
		t.Fatalf("terminal error must persist completion_tokens 0: %+v", r1)
	}

	r2 := byKey[shared.InferenceRouteKey(id(2), 1)]
	if r2.FinalStatus != "success" || r2.PromptTokens != 10 || r2.CompletionTokens != 20 || r2.CostMicroUSD != 7 || r2.CandidateCount != 2 {
		t.Fatalf("row 2 outcome/snapshot wrong: %+v", r2)
	}
	r3 := byKey[shared.InferenceRouteKey(id(3), 1)]
	if r3.FinalStatus != "" || r3.ProviderRegion != "us-east" {
		t.Fatalf("row 3 must be untouched by the nil update: %+v", r3)
	}
	if r12 := byKey[shared.InferenceRouteKey(id(1), 2)]; r12.ProviderID != "p1b" {
		t.Fatalf("attempt 2 must be its own row: %+v", r12)
	}

	// A single-row write after a batch behaves identically (same code path).
	if err := s.RecordInferenceRoute(&store.InferenceRouteRecord{RequestID: id(3), Attempt: 1, ProviderID: "p3-refresh", Outcome: "selected", Model: "m"}); err != nil {
		t.Fatalf("RecordInferenceRoute: %v", err)
	}
	if err := s.UpdateInferenceRouteOutcome(id(3), 1, &store.InferenceRouteOutcome{FinalStatus: "cancelled", CompletionTokensSet: true}); err != nil {
		t.Fatalf("UpdateInferenceRouteOutcome: %v", err)
	}
	for _, r := range s.InferenceRouteRecordsSince(time.Time{}) {
		if r.RequestID == id(3) && r.Attempt == 1 {
			if r.ProviderID != "p3-refresh" || r.FinalStatus != "cancelled" || r.ProviderRegion != "" {
				t.Fatalf("single-row refresh + update after batch wrong: %+v", r)
			}
		}
	}
}
