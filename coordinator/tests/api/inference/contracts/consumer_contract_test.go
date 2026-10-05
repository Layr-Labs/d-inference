package inference_test

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestChatCompletionsNoProvider(t *testing.T) {
	fixture := testkit.New(t, api.ServerConfig{})
	srv := fixture.Server

	// Set a catalog so the unknown model returns 404 immediately instead of
	// blocking for the full 120s queue timeout.
	fixture.Registry.SetModelCatalog([]registry.CatalogEntry{{ID: "known-model"}})

	body := `{"model":"nonexistent-model","messages":[{"role":"user","content":"hi"}]}`
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusNotFound {
		t.Errorf("status = %d, want %d", w.Code, http.StatusNotFound)
	}
}
