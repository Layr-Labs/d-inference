package access_test

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	api "github.com/eigeninference/d-inference/coordinator/api"
	testkit "github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
)

func TestEdge_AuthEmptyBearer(t *testing.T) {
	srv := testkit.New(t, api.ServerConfig{}).Server

	body := `{"model":"test","messages":[{"role":"user","content":"hi"}]}`
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer ")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Errorf("empty bearer: status = %d, want 401", w.Code)
	}
}

func TestEdge_AuthMalformedHeader(t *testing.T) {
	srv := testkit.New(t, api.ServerConfig{}).Server

	cases := []struct {
		name   string
		header string
	}{
		{"no_bearer_prefix", "test-key"},
		{"basic_auth", "Basic dGVzdDp0ZXN0"},
		{"double_bearer", "Bearer Bearer test-key"},
		{"just_bearer", "Bearer"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			body := `{"model":"test","messages":[{"role":"user","content":"hi"}]}`
			req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
			req.Header.Set("Authorization", tc.header)
			w := httptest.NewRecorder()
			srv.Handler().ServeHTTP(w, req)

			if w.Code != http.StatusUnauthorized {
				t.Errorf("%s: status = %d, want 401", tc.name, w.Code)
			}
		})
	}
}
