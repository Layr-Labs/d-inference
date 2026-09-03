package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestVersionEndpointReturnsLocalFallback(t *testing.T) {
	srv, _ := testServer(t)
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/version", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	var response map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if response["version"] == nil || response["download_url"] == nil {
		t.Fatalf("fallback response is missing version or download_url: %s", rec.Body.String())
	}
}

func TestVersionEndpointReturnsSharedReleaseMetadata(t *testing.T) {
	srv, st := testServer(t)
	payload := releaseRegistrationFixture(t)
	encoded, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	var release store.Release
	if err := json.Unmarshal(encoded, &release); err != nil {
		t.Fatal(err)
	}
	if err := st.SetRelease(&release); err != nil {
		t.Fatal(err)
	}

	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/version", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	var response map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	for _, field := range []string{"version", "backend", "binary_hash", "bundle_hash", "metallib_hash", "download_url"} {
		wantField := field
		if field == "download_url" {
			wantField = "url"
		}
		if got, want := response[field], payload[wantField]; got != want {
			t.Fatalf("%s = %q, want %q", field, got, want)
		}
	}
}
