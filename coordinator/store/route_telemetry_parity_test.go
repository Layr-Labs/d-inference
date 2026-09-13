package store

import (
	"testing"
	"time"
)

// TestInferenceRouteErrorReasonSurvivesReasonlessWrites pins backend parity
// for error_reason: a reason written with the route record must survive both
// a reason-less refresh (the postgres upsert keeps the existing column when
// EXCLUDED.error_reason is empty) and a reason-less outcome update (the UPDATE
// keeps the existing column when the bound reason is empty), through the
// single-row and batch paths alike, and a later explicit reason replaces it.
func TestInferenceRouteErrorReasonSurvivesReasonlessWrites(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			id := uniqueID("reason")
			read := func() InferenceRouteRecord {
				t.Helper()
				for _, r := range s.InferenceRouteRecordsSince(time.Time{}) {
					if r.RequestID == id && r.Attempt == 1 {
						return r
					}
				}
				t.Fatal("row not found")
				return InferenceRouteRecord{}
			}

			if err := s.RecordInferenceRoute(&InferenceRouteRecord{RequestID: id, Attempt: 1, Outcome: "selected", ProviderID: "p1", ErrorReason: "jinja_template"}); err != nil {
				t.Fatalf("RecordInferenceRoute: %v", err)
			}
			if err := s.RecordInferenceRoute(&InferenceRouteRecord{RequestID: id, Attempt: 1, Outcome: "selected", ProviderID: "p2"}); err != nil {
				t.Fatalf("refresh: %v", err)
			}
			if r := read(); r.ErrorReason != "jinja_template" || r.ProviderID != "p2" {
				t.Fatalf("reason-less single refresh must keep the reason and take the snapshot: %+v", r)
			}

			if err := s.UpdateInferenceRouteOutcome(id, 1, &InferenceRouteOutcome{FinalStatus: "error", ErrorClass: "client_error", ErrorCode: 500, CompletionTokensSet: true}); err != nil {
				t.Fatalf("reason-less update: %v", err)
			}
			if r := read(); r.ErrorReason != "jinja_template" || r.FinalStatus != "error" || r.ErrorClass != "client_error" {
				t.Fatalf("reason-less update must keep the reason and apply the rest: %+v", r)
			}

			if err := s.UpdateInferenceRouteOutcomes([]InferenceRouteOutcomeUpdate{{RequestID: id, Attempt: 1, Outcome: &InferenceRouteOutcome{ErrorReason: "provider_error"}}}); err != nil {
				t.Fatalf("explicit reason update: %v", err)
			}
			if r := read(); r.ErrorReason != "provider_error" {
				t.Fatalf("explicit reason must replace: %+v", r)
			}

			if err := s.RecordInferenceRoutes([]*InferenceRouteRecord{{RequestID: id, Attempt: 1, Outcome: "selected", ProviderID: "p3"}}); err != nil {
				t.Fatalf("batch refresh: %v", err)
			}
			if r := read(); r.ErrorReason != "provider_error" || r.ProviderID != "p3" || r.FinalStatus != "error" {
				t.Fatalf("reason-less batch refresh must keep reason and outcome: %+v", r)
			}
		})
	}
}

// TestInferenceRouteBatchStampsEachRecord checks that zero timestamps in a
// batch are defaulted per record from the write clock (never left zero, never
// earlier than the call, and non-decreasing in slice order), on both backends.
func TestInferenceRouteBatchStampsEachRecord(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			prefix := uniqueID("stamp")
			before := time.Now().Add(-time.Millisecond)
			records := []*InferenceRouteRecord{
				{RequestID: prefix + "-a", Attempt: 1, Outcome: "selected"},
				{RequestID: prefix + "-b", Attempt: 1, Outcome: "selected"},
				{RequestID: prefix + "-c", Attempt: 1, Outcome: "selected", CreatedAt: before.Add(-time.Hour), UpdatedAt: before.Add(-time.Hour)},
			}
			if err := s.RecordInferenceRoutes(records); err != nil {
				t.Fatalf("RecordInferenceRoutes: %v", err)
			}
			after := time.Now().Add(time.Millisecond)
			got := map[string]InferenceRouteRecord{}
			for _, r := range s.InferenceRouteRecordsSince(time.Time{}) {
				if r.RequestID == prefix+"-a" || r.RequestID == prefix+"-b" || r.RequestID == prefix+"-c" {
					got[r.RequestID] = r
				}
			}
			a, b, c := got[prefix+"-a"], got[prefix+"-b"], got[prefix+"-c"]
			for _, r := range []InferenceRouteRecord{a, b} {
				if r.CreatedAt.Before(before) || r.CreatedAt.After(after) || r.UpdatedAt.Before(before) || r.UpdatedAt.After(after) {
					t.Fatalf("defaulted timestamps outside the write window: %+v (window %v..%v)", r, before, after)
				}
			}
			if b.CreatedAt.Before(a.CreatedAt) {
				t.Fatalf("per-record stamps must be non-decreasing in slice order: a=%v b=%v", a.CreatedAt, b.CreatedAt)
			}
			if !c.CreatedAt.Equal(before.Add(-time.Hour).UTC().Truncate(time.Microsecond)) && !c.CreatedAt.Equal(before.Add(-time.Hour)) {
				t.Fatalf("explicit CreatedAt must be kept: %v", c.CreatedAt)
			}
		})
	}
}
