package api

// Edge case tests for the coordinator API.
//
// These tests verify that the coordinator handles malformed, missing, and
// boundary-condition inputs gracefully. All tests use mock providers
// (no real backends needed) and run in CI.

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestEdge_ReleaseLatestNoReleases(t *testing.T) {
	srv, _ := testServer(t)

	req := httptest.NewRequest(http.MethodGet, "/v1/releases/latest?platform=macos-arm64", nil)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusNotFound {
		t.Errorf("latest with no releases: status = %d, want 404", w.Code)
	}
}

func TestEdge_ReleaseRegisterNoAuth(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetReleaseKey("secret-release-key")

	body := fmt.Sprintf(`{"version":"1.0.0","platform":"macos-arm64","binary_hash":%q,"bundle_hash":%q,"url":"http://example.com/bundle.tar.gz"}`,
		strings.Repeat("a", 64), strings.Repeat("b", 64))
	req := httptest.NewRequest(http.MethodPost, "/v1/releases", strings.NewReader(body))
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Errorf("release register without auth: status = %d, want 401", w.Code)
	}
}

func TestEdge_ReleaseRegisterWrongKey(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetReleaseKey("correct-key")

	body := fmt.Sprintf(`{"version":"1.0.0","platform":"macos-arm64","binary_hash":%q,"bundle_hash":%q,"url":"http://example.com/bundle.tar.gz"}`,
		strings.Repeat("a", 64), strings.Repeat("b", 64))
	req := httptest.NewRequest(http.MethodPost, "/v1/releases", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer wrong-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Errorf("release register wrong key: status = %d, want 401", w.Code)
	}
}

func TestEdge_ReleaseRegisterMissingFields(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetReleaseKey("release-key")

	cases := []struct {
		name string
		body string
	}{
		{"missing_version", fmt.Sprintf(`{"platform":"macos-arm64","binary_hash":%q,"bundle_hash":%q,"url":"http://example.com/b.tar.gz"}`, strings.Repeat("a", 64), strings.Repeat("b", 64))},
		// platform defaults to "macos-arm64" when omitted, so omit a truly required field instead
		{"empty_version", fmt.Sprintf(`{"version":"","platform":"macos-arm64","binary_hash":%q,"bundle_hash":%q,"url":"http://example.com/b.tar.gz"}`, strings.Repeat("a", 64), strings.Repeat("b", 64))},
		{"missing_hash", `{"version":"1.0.0","platform":"macos-arm64","url":"http://example.com/b.tar.gz"}`},
		{"missing_url", fmt.Sprintf(`{"version":"1.0.0","platform":"macos-arm64","binary_hash":%q,"bundle_hash":%q}`, strings.Repeat("a", 64), strings.Repeat("b", 64))},
		{"invalid_hash", `{"version":"1.0.0","platform":"macos-arm64","binary_hash":"abc","bundle_hash":"def","url":"http://example.com/b.tar.gz"}`},
		{"missing_swift_metallib", fmt.Sprintf(`{"version":"1.0.0","platform":"macos-arm64","backend":"mlx-swift","binary_hash":%q,"bundle_hash":%q,"url":"http://example.com/b.tar.gz"}`, strings.Repeat("a", 64), strings.Repeat("b", 64))},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/v1/releases", strings.NewReader(tc.body))
			req.Header.Set("Authorization", "Bearer release-key")
			w := httptest.NewRecorder()
			srv.Handler().ServeHTTP(w, req)

			if w.Code != http.StatusBadRequest {
				t.Errorf("%s: status = %d, want 400, body = %s", tc.name, w.Code, w.Body.String())
			}
		})
	}
}

func TestEdge_ReleaseRegisterAndRetrieve(t *testing.T) {
	srv, st := testServer(t)
	srv.SetReleaseKey("release-key")

	artifact := buildReleaseBundleForTest(t, []byte("provider-binary"))
	cdn := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/releases/v1.0.0/darkbloom-bundle-macos-arm64.tar.gz" {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write(artifact.bytes)
	}))
	defer cdn.Close()
	srv.SetR2CDNURL(cdn.URL + "/")

	body := fmt.Sprintf(`{"version":"1.0.0","platform":"macos-arm64","backend":"mlx-swift","binary_hash":%q,"bundle_hash":%q,"metallib_hash":%q,"url":%q,"changelog":"First release"}`, artifact.binaryHash, artifact.bundleHash, artifact.metallibHash, cdn.URL+"/releases/v1.0.0/darkbloom-bundle-macos-arm64.tar.gz")
	req := httptest.NewRequest(http.MethodPost, "/v1/releases", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer release-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK && w.Code != http.StatusCreated {
		t.Fatalf("register release: status = %d, body = %s", w.Code, w.Body.String())
	}

	// Retrieve latest
	req = httptest.NewRequest(http.MethodGet, "/v1/releases/latest?platform=macos-arm64", nil)
	w = httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("get latest: status = %d, body = %s", w.Code, w.Body.String())
	}

	var latest map[string]any
	json.Unmarshal(w.Body.Bytes(), &latest)
	if latest["version"] != "1.0.0" {
		t.Errorf("latest version = %v, want 1.0.0", latest["version"])
	}
	if latest["has_app"] != true ||
		latest["has_fan_helper"] != false ||
		latest["has_paged_kernel"] != false {
		t.Errorf("latest release capability flags were not derived: %+v", latest)
	}

	// Verify binary hashes were synced
	releases := st.ListReleases()
	if len(releases) == 0 {
		t.Error("expected at least one release in store")
	}
}

func TestEdge_ReleaseRegisterRejectsInvalidHashMetadata(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetReleaseKey("release-key")

	body := `{"version":"1.0.0","platform":"macos-arm64","binary_hash":"abc123","bundle_hash":"def456","url":"http://example.com/bundle.tar.gz"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/releases", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer release-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("release register with invalid hashes: status = %d, want 400, body = %s", w.Code, w.Body.String())
	}
}

func TestEdge_ReleaseRegisterRejectsStoreOnlyFields(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetReleaseKey("release-key")

	binaryHash := strings.Repeat("a", 64)
	bundleHash := strings.Repeat("b", 64)
	body := fmt.Sprintf(`{"version":"1.0.0","platform":"macos-arm64","binary_hash":%q,"bundle_hash":%q,"url":"https://r2.example.com/releases/v1.0.0/darkbloom-bundle-macos-arm64.tar.gz","active":true,"created_at":"2099-01-01T00:00:00Z"}`, binaryHash, bundleHash)
	req := httptest.NewRequest(http.MethodPost, "/v1/releases", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer release-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("release register with store-only fields: status = %d, want 400, body = %s", w.Code, w.Body.String())
	}
}

func TestEdge_ReleaseRegisterRejectsOffOriginURLWhenR2Configured(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetReleaseKey("release-key")
	srv.SetR2CDNURL("https://r2.example.com")

	binaryHash := strings.Repeat("a", 64)
	bundleHash := strings.Repeat("b", 64)
	body := fmt.Sprintf(`{"version":"1.0.0","platform":"macos-arm64","binary_hash":%q,"bundle_hash":%q,"url":"https://evil.example.com/releases/v1.0.0/darkbloom-bundle-macos-arm64.tar.gz"}`, binaryHash, bundleHash)
	req := httptest.NewRequest(http.MethodPost, "/v1/releases", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer release-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("release register with off-origin URL: status = %d, want 400, body = %s", w.Code, w.Body.String())
	}
}

func TestEdge_ReleaseRegisterRejectsHTTPArtifactOrigin(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetReleaseKey("release-key")
	srv.SetR2CDNURL("http://r2.example.com")

	binaryHash := strings.Repeat("a", 64)
	bundleHash := strings.Repeat("b", 64)
	body := fmt.Sprintf(`{"version":"1.0.0","platform":"macos-arm64","binary_hash":%q,"bundle_hash":%q,"url":"http://r2.example.com/releases/v1.0.0/darkbloom-bundle-macos-arm64.tar.gz"}`, binaryHash, bundleHash)
	req := httptest.NewRequest(http.MethodPost, "/v1/releases", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer release-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("release register with http artifact origin: status = %d, want 400, body = %s", w.Code, w.Body.String())
	}
}

func TestEdge_ReleaseRegisterRejectsCredentialedArtifactURL(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetReleaseKey("release-key")
	srv.SetR2CDNURL("https://r2.example.com")

	binaryHash := strings.Repeat("a", 64)
	bundleHash := strings.Repeat("b", 64)
	body := fmt.Sprintf(`{"version":"1.0.0","platform":"macos-arm64","binary_hash":%q,"bundle_hash":%q,"url":"https://user:pass@r2.example.com/releases/v1.0.0/darkbloom-bundle-macos-arm64.tar.gz"}`, binaryHash, bundleHash)
	req := httptest.NewRequest(http.MethodPost, "/v1/releases", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer release-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("release register with credentialed artifact URL: status = %d, want 400, body = %s", w.Code, w.Body.String())
	}
}

func TestEdge_ReleaseRegisterRejectsRedirectedBundleDownload(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetReleaseKey("release-key")

	artifact := buildReleaseBundleForTest(t, []byte("provider-binary"))
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write(artifact.bytes)
	}))
	defer target.Close()

	cdn := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, target.URL+"/bundle.tar.gz", http.StatusFound)
	}))
	defer cdn.Close()
	srv.SetR2CDNURL(cdn.URL)

	body := fmt.Sprintf(`{"version":"1.0.0","platform":"macos-arm64","backend":"mlx-swift","binary_hash":%q,"bundle_hash":%q,"metallib_hash":%q,"url":%q}`, artifact.binaryHash, artifact.bundleHash, artifact.metallibHash, cdn.URL+"/releases/v1.0.0/darkbloom-bundle-macos-arm64.tar.gz")
	req := httptest.NewRequest(http.MethodPost, "/v1/releases", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer release-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("release register with redirected bundle: status = %d, want 400, body = %s", w.Code, w.Body.String())
	}
}
