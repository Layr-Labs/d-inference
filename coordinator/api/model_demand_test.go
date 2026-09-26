package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
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

func TestModelTooLargeAdmissionCountsPublicSupplyShortfall(t *testing.T) {
	srv, st := testServer(t)
	t.Cleanup(srv.Close)
	const model = "model-demand-too-large"
	srv.registry.SetModelCatalog([]registry.CatalogEntry{{ID: model, SizeGB: 128}})
	p := registerBuildsProvider(srv, "undersized-provider", model)
	p.Mu().Lock()
	p.BackendCapacity.Slots[0].State = "idle_shutdown"
	p.Mu().Unlock()

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions",
		strings.NewReader(`{"model":"model-demand-too-large","messages":[{"role":"user","content":"hello"}],"max_tokens":16}`))
	req.Header.Set("Authorization", "Bearer test-key")
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)
	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503; body=%s", w.Code, w.Body.String())
	}
	outcome := awaitRequestOutcomes(t, st, 1)[0]
	if outcome.RawStage != "preflight_capacity" || outcome.RawReason != "model_too_large" ||
		outcome.PublicDemand == nil || outcome.PublicDemand.Outcome != "capacity_rejected" || outcome.AttemptsTotal != 0 {
		t.Fatalf("model-too-large supply evidence: %+v", outcome)
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
				ctx = context.WithValue(ctx, ctxKeyConsumer, consumer)
			}
			r := httptest.NewRequest("POST", "/v1/messages", nil).WithContext(ctx)
			p := inferenceAdmissionParams{model: "resolved-build", publicModel: "public-alias"}
			if mode == "self" {
				p.policy.enabled = true
			}
			if mode == "prefer" {
				p.policy.prefer = true
			}
			if mode == "restricted" {
				p.allowedProviderSerials = []string{"machine"}
			}
			markPublicModelDemand(r, p)
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

func TestModelDemandPublicEndpoint(t *testing.T) {
	_, _, s, _ := setupTTFTFailoverServer(t)
	t.Cleanup(s.Close)
	for _, window := range []string{"24h", "7d", "30d", ""} {
		w := httptest.NewRecorder()
		s.mux.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/v1/network/model-demand?window="+window, nil))
		if w.Code != 200 {
			t.Fatalf("%s: %d %s", window, w.Code, w.Body.String())
		}
		var v struct {
			Coverage       string `json:"coverage"`
			StartAt, EndAt time.Time
			Models         []store.ModelDemandCounts
		}
		var raw map[string]json.RawMessage
		if err := json.Unmarshal(w.Body.Bytes(), &raw); err != nil {
			t.Fatal(err)
		}
		_ = json.Unmarshal(raw["end_at"], &v.EndAt)
		_ = json.Unmarshal(raw["start_at"], &v.StartAt)
		if !v.StartAt.Before(v.EndAt) || time.Since(v.EndAt) < time.Hour || v.EndAt.Minute() != 0 {
			t.Fatalf("invalid boundary %+v", v)
		}
		if strings.Contains(w.Body.String(), "consumer_hash") || strings.Contains(w.Body.String(), "raw_reason") {
			t.Fatal("private evidence exposed")
		}
	}
	w := httptest.NewRecorder()
	s.handleModelDemand(w, httptest.NewRequest("GET", "/?window=all", nil))
	if w.Code != 400 {
		t.Fatalf("unbounded window: %d", w.Code)
	}
}

// A failed aggregate must never become a cached successful empty list.
type unavailableDemandStore struct {
	store.Store
	fail bool
}

func (s *unavailableDemandStore) ModelDemand(ctx context.Context, a, b time.Time) (store.ModelDemandSnapshot, error) {
	if s.fail {
		return store.ModelDemandSnapshot{}, errors.New("unavailable")
	}
	return s.Store.(store.ModelDemandStore).ModelDemand(ctx, a, b)
}
func (s *unavailableDemandStore) PruneModelDemand(ctx context.Context, a time.Time, b int) (int, error) {
	return 0, nil
}
func TestModelDemandFailureIsNotCached(t *testing.T) {
	_, _, s, _ := setupTTFTFailoverServer(t)
	t.Cleanup(s.Close)
	original := s.store
	failing := &unavailableDemandStore{Store: original, fail: true}
	s.store = failing
	t.Cleanup(func() { s.store = original })
	request := func() int {
		w := httptest.NewRecorder()
		s.handleModelDemand(w, httptest.NewRequest("GET", "/?window=24h", nil))
		return w.Code
	}
	if got := request(); got != 503 {
		t.Fatalf("failure status %d", got)
	}
	failing.fail = false
	if got := request(); got != 200 {
		t.Fatalf("recovered status %d", got)
	}
}
