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

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestPublicDemandOutcome(t *testing.T) {
	for _, tc := range []struct {
		name, termination, stage, reason string
		status                           int
		conflict                         bool
		want                             string
	}{
		{"completion", "completed", "", "", 200, false, "completed"},
		{"started stream", "unknown", "", "", 200, false, "unknown"},
		{"failed stream", "interrupted_response", "", "", 200, false, "failed"},
		{"busy", "rejected", "preflight_capacity", "machine_busy", 429, false, "capacity_rejected"},
		{"no eligible provider", "rejected", "preflight_capacity", "no_provider", 429, false, "capacity_rejected"},
		{"coordinator capacity", "rejected", "preflight_capacity", "routing_saturated", 429, false, "capacity_rejected"},
		{"first content timeout", "rejected", "dispatch", "first_chunk_timeout", 429, false, "timed_out"},
		{"predicted latency", "rejected", "routing_ttft", "ttft_too_slow", 429, false, "latency_rejected"},
		{"deadline refusal", "rejected", "dispatch", "deadline_unreachable", 429, false, "latency_rejected"},
		{"unknown 429", "rejected", "dispatch", "", 429, false, "unknown"},
		{"validation", "rejected", "validation", "bad_body", 400, false, "excluded"},
		{"balance", "rejected", "balance", "insufficient_quota", 402, false, "excluded"},
		{"cancelled", "client_departure", "", "", 200, false, "cancelled"},
		{"conflicting success", "completed", "", "", 200, true, "unknown"},
		{"provider failure", "rejected", "dispatch", "engine_crashed", 502, false, "failed"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := store.RequestOutcomeRecord{Termination: tc.termination, RawStage: tc.stage, RawReason: tc.reason, HTTPStatus: tc.status, EvidenceConflict: tc.conflict}
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
