package inference_test

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
)

func TestModelTooLargeAdmissionCountsPublicSupplyShortfall(t *testing.T) {
	fixture := testkit.New(t, api.ServerConfig{})
	srv, st := fixture.Server, fixture.Store
	const model = "model-demand-too-large"
	fixture.Registry.SetModelCatalog([]registry.CatalogEntry{{ID: model, SizeGB: 128}})
	p := testkit.RegisterBuildsProvider(fixture.Registry, "undersized-provider", model)
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
