package api

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestAdminKeyCanAccessModelCatalog(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetAdminKey("admin-secret")

	req := httptest.NewRequest(http.MethodGet, "/v1/admin/models", nil)
	req.Header.Set("Authorization", "Bearer admin-secret")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d: %s", w.Code, http.StatusOK, w.Body.String())
	}
}

func TestAdminModelCatalogRejectsNonAdminAPIKey(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetAdminKey("admin-secret")

	req := httptest.NewRequest(http.MethodGet, "/v1/admin/models", nil)
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want %d: %s", w.Code, http.StatusForbidden, w.Body.String())
	}
}

func TestAdminKeyCanSetPlatformPricing(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetAdminKey("admin-secret")

	body := `{"model":"mlx-community/Test-Model","input_price":1000,"output_price":2000}`
	req := httptest.NewRequest(http.MethodPut, "/v1/admin/pricing", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer admin-secret")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d: %s", w.Code, http.StatusOK, w.Body.String())
	}
}

func TestAdminRoutesRequireAuth(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetAdminKey("admin-secret")

	for _, path := range []string{"/v1/admin/releases", "/v1/admin/metrics"} {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		w := httptest.NewRecorder()
		srv.Handler().ServeHTTP(w, req)

		if w.Code != http.StatusUnauthorized {
			t.Fatalf("%s status = %d, want %d: %s", path, w.Code, http.StatusUnauthorized, w.Body.String())
		}

		req = httptest.NewRequest(http.MethodGet, path, nil)
		req.Header.Set("Authorization", "Bearer test-key")
		w = httptest.NewRecorder()
		srv.Handler().ServeHTTP(w, req)

		if w.Code != http.StatusForbidden {
			t.Fatalf("%s non-admin API key status = %d, want %d: %s", path, w.Code, http.StatusForbidden, w.Body.String())
		}
	}
}
