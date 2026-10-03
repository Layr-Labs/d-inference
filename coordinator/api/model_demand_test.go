package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

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
	s.reporting.HandleModelDemand(w, httptest.NewRequest("GET", "/?window=all", nil))
	if w.Code != 400 {
		t.Fatalf("unbounded window: %d", w.Code)
	}
}
