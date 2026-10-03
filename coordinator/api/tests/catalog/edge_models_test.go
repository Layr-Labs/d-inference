package catalog_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	api "github.com/eigeninference/d-inference/coordinator/api"
	testkit "github.com/eigeninference/d-inference/coordinator/api/tests/internal/testkit"
)

func TestEdge_ModelsEndpointNoProviders(t *testing.T) {
	srv := testkit.New(t, api.ServerConfig{}).Server

	req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("models endpoint: status = %d, want 200", w.Code)
	}

	var resp struct {
		Object string `json:"object"`
		Data   []any  `json:"data"`
	}
	json.Unmarshal(w.Body.Bytes(), &resp)

	// With no providers connected, the models list is empty (the endpoint shows
	// available models from live providers), but the OpenAI list envelope must
	// still be well-formed. This also verifies the endpoint doesn't crash with
	// no providers or registry rows.
	if resp.Object != "list" {
		t.Errorf("object = %q, want list", resp.Object)
	}
}
