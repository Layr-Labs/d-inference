package access_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	api "github.com/eigeninference/d-inference/coordinator/api"
	testkit "github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
)

func TestOpenAI_AuthRequired(t *testing.T) {
	srv := testkit.New(
		t,
		api.ServerConfig{}).Server

	t.Run("no_auth_header", func(t *testing.T) {
		body := `{"model":"test","messages":[{"role":"user","content":"hi"}]}`
		req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
		w := httptest.NewRecorder()
		srv.Handler().ServeHTTP(w, req)

		if w.Code != http.StatusUnauthorized {
			t.Errorf("status = %d, want %d", w.Code, http.StatusUnauthorized)
		}

		// Verify error format.
		var result map[string]any
		if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
			t.Fatalf("decode: %v", err)
		}
		errObj, ok := result["error"].(map[string]any)
		if !ok {
			t.Fatalf("missing 'error' object in 401 response: %v", result)
		}
		if _, ok := errObj["message"].(string); !ok {
			t.Error("error.message missing in 401 response")
		}
		if _, ok := errObj["type"].(string); !ok {
			t.Error("error.type missing in 401 response")
		}
	})

	t.Run("invalid_key", func(t *testing.T) {
		body := `{"model":"test","messages":[{"role":"user","content":"hi"}]}`
		req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer wrong-key-12345")
		w := httptest.NewRecorder()
		srv.Handler().ServeHTTP(w, req)

		if w.Code != http.StatusUnauthorized {
			t.Errorf("status = %d, want %d", w.Code, http.StatusUnauthorized)
		}

		var result map[string]any
		if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
			t.Fatalf("decode: %v", err)
		}
		errObj, ok := result["error"].(map[string]any)
		if !ok {
			t.Fatalf("missing 'error' object in 401 response: %v", result)
		}
		if _, ok := errObj["message"].(string); !ok {
			t.Error("error.message missing in 401 response")
		}
		if _, ok := errObj["type"].(string); !ok {
			t.Error("error.type missing in 401 response")
		}
	})

	t.Run("list_models_no_auth", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
		w := httptest.NewRecorder()
		srv.Handler().ServeHTTP(w, req)

		if w.Code != http.StatusUnauthorized {
			t.Errorf("status = %d, want %d", w.Code, http.StatusUnauthorized)
		}
	})
}
