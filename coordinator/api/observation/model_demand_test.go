package observation

import (
	"context"

	"net/http/httptest"

	"testing"

	"github.com/eigeninference/d-inference/coordinator/api/access"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestPublicDemandOutcome(t *testing.T) {
	for _, tc := range []struct {
		name, termination, stage, reason string
		status                           int
		conflict                         bool
		coordinatorExhausted             bool
		want                             string
	}{
		{"completion", "completed", "", "", 200, false, false, "completed"},
		{"started stream", "unknown", "", "", 200, false, false, "unknown"},
		{"failed stream", "interrupted_response", "", "", 200, false, false, "failed"},
		{"busy", "rejected", "preflight_capacity", "machine_busy", 429, false, false, "capacity_rejected"},
		{"no eligible provider", "rejected", "preflight_capacity", "no_provider", 429, false, false, "capacity_rejected"},
		{"coordinator capacity", "rejected", "preflight_capacity", "routing_saturated", 429, false, false, "capacity_rejected"},
		{"queue full", "rejected", "queue", "queue_full", 429, false, false, "capacity_rejected"},
		{"provider token budget exhausted", "rejected", "dispatch", "unservable_token_budget", 429, false, false, "capacity_rejected"},
		{"preflight token budget insufficient", "rejected", "preflight_capacity", "prompt_too_long", 429, false, false, "capacity_rejected"},
		{"context window exceeded", "rejected", "preflight_capacity", "context_exceeded", 429, false, false, "excluded"},
		{"context rejection wrong stage", "rejected", "dispatch", "context_exceeded", 429, false, false, "unknown"},
		{"model cannot fit fleet", "rejected", "preflight_capacity", "model_too_large", 503, false, false, "capacity_rejected"},
		{"model cannot fit invalid status", "rejected", "preflight_capacity", "model_too_large", 500, false, false, "failed"},
		{"dispatch exhausted at capacity", "rejected", "dispatch", "dispatch_exhausted", 429, false, true, "capacity_rejected"},
		{"dispatch exhausted without capacity evidence", "rejected", "dispatch", "dispatch_exhausted", 429, false, false, "unknown"},
		{"dispatch exhausted no provider", "rejected", "dispatch", "dispatch_exhausted", 503, false, true, "failed"},
		{"dispatch exhausted provider fault", "rejected", "dispatch", "dispatch_exhausted", 502, false, false, "failed"},
		{"invalid prompt length", "rejected", "validation", "prompt_too_long", 400, false, false, "excluded"},
		{"queued first-content deadline", "rejected", "dispatch", "queue_deadline", 429, false, false, "timed_out"},
		{"first content timeout", "rejected", "dispatch", "first_chunk_timeout", 429, false, false, "timed_out"},
		{"predicted latency", "rejected", "routing_ttft", "ttft_too_slow", 429, false, false, "latency_rejected"},
		{"deadline refusal", "rejected", "dispatch", "deadline_unreachable", 429, false, false, "latency_rejected"},
		{"unknown 429", "rejected", "dispatch", "", 429, false, false, "unknown"},
		{"validation", "rejected", "validation", "bad_body", 400, false, false, "excluded"},
		{"balance", "rejected", "balance", "insufficient_quota", 402, false, false, "excluded"},
		{"cancelled", "client_departure", "", "", 200, false, false, "cancelled"},
		{"conflicting success", "completed", "", "", 200, true, false, "unknown"},
		{"provider failure", "rejected", "dispatch", "engine_crashed", 502, false, false, "failed"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := store.RequestOutcomeRecord{Termination: tc.termination, RawStage: tc.stage, RawReason: tc.reason, HTTPStatus: tc.status, EvidenceConflict: tc.conflict, CoordinatorExhausted: tc.coordinatorExhausted}
			if got := publicDemandOutcome(r); got != tc.want {
				t.Fatalf("got %s want %s", got, tc.want)
			}
		})
	}
}

func TestPublicModelDemandScope(t *testing.T) {
	for _, mode := range []string{"public", "self", "prefer", "restricted", "anonymous", "admin"} {
		t.Run(mode, func(t *testing.T) {
			o := &requestOutcome{record: store.RequestOutcomeRecord{Termination: "in_progress"}}
			ctx := context.WithValue(context.Background(), requestOutcomeKey{}, o)
			if mode != "anonymous" {
				consumer := "account-secret"
				if mode == "admin" {
					consumer = "admin"
				}
				ctx = access.WithConsumer(ctx, consumer)
			}
			r := httptest.NewRequest("POST", "/v1/messages", nil).WithContext(ctx)
			var serials []string
			if mode == "restricted" {
				serials = []string{"machine"}
			}
			MarkPublicModelDemand(r, mode == "self", mode == "prefer", serials, "public-alias", "resolved-build")
			if mode == "public" {
				if d := o.record.PublicDemand; d == nil || d.Model != "public-alias" || d.ConsumerHash != store.HashKey("account-secret") {
					t.Fatalf("scope %+v", d)
				}
			} else if o.record.PublicDemand != nil {
				t.Fatal("private request included")
			}
		})
	}
}
