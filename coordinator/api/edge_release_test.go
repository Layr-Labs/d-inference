package api

// Edge case tests for the coordinator API.
//
// These tests verify that the coordinator handles malformed, missing, and
// boundary-condition inputs gracefully. All tests use mock providers
// (no real backends needed) and run in CI.

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
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

func TestEdge_ReleaseLatestSeparatesStableAndBetaChannels(t *testing.T) {
	srv, st := testServer(t)
	for _, release := range []*store.Release{
		{Version: "1.0.0", Platform: "macos-arm64", Channel: store.ReleaseChannelStable, CreatedAt: time.Now()},
		{Version: "1.1.0-beta.1", Platform: "macos-arm64", Channel: store.ReleaseChannelBeta, CreatedAt: time.Now().Add(time.Second)},
	} {
		if err := st.SetRelease(release); err != nil {
			t.Fatalf("SetRelease(%s): %v", release.Version, err)
		}
	}

	for _, tc := range []struct {
		path string
		want string
	}{
		{path: "/v1/releases/latest?platform=macos-arm64", want: "1.0.0"},
		{path: "/v1/releases/latest?platform=macos-arm64&channel=stable", want: "1.0.0"},
		{path: "/v1/releases/latest?platform=macos-arm64&channel=beta", want: "1.1.0-beta.1"},
	} {
		req := httptest.NewRequest(http.MethodGet, tc.path, nil)
		w := httptest.NewRecorder()
		srv.Handler().ServeHTTP(w, req)
		if w.Code != http.StatusOK {
			t.Fatalf("GET %s: status = %d, body = %s", tc.path, w.Code, w.Body.String())
		}
		var got store.Release
		if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
			t.Fatalf("decode %s: %v", tc.path, err)
		}
		if got.Version != tc.want {
			t.Errorf("GET %s: version = %q, want %q", tc.path, got.Version, tc.want)
		}
	}

	req := httptest.NewRequest(http.MethodGet, "/v1/releases/latest?channel=canary", nil)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("unknown channel status = %d, want 400", w.Code)
	}
}

func TestInvalidateLatestReleaseCacheClearsBothChannels(t *testing.T) {
	srv, _ := testServer(t)
	platform := "macos-arm64"
	for _, channel := range []string{store.ReleaseChannelStable, store.ReleaseChannelBeta} {
		srv.readCache.Set(latestReleaseCacheKey(platform, channel), []byte(`{}`), time.Minute)
	}
	srv.invalidateLatestReleaseCache(platform)
	for _, channel := range []string{store.ReleaseChannelStable, store.ReleaseChannelBeta} {
		if _, ok := srv.readCache.Get(latestReleaseCacheKey(platform, channel)); ok {
			t.Fatalf("cache entry for %s channel survived invalidation", channel)
		}
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
		{"invalid_channel", fmt.Sprintf(`{"version":"1.0.0","platform":"macos-arm64","channel":"canary","binary_hash":%q,"bundle_hash":%q,"url":"http://example.com/b.tar.gz"}`, strings.Repeat("a", 64), strings.Repeat("b", 64))},
		{"beta_version_on_stable", fmt.Sprintf(`{"version":"1.1.0-beta.1","platform":"macos-arm64","channel":"stable","binary_hash":%q,"bundle_hash":%q,"url":"http://example.com/b.tar.gz"}`, strings.Repeat("a", 64), strings.Repeat("b", 64))},
		{"stable_version_on_beta", fmt.Sprintf(`{"version":"1.1.0","platform":"macos-arm64","channel":"beta","binary_hash":%q,"bundle_hash":%q,"url":"http://example.com/b.tar.gz"}`, strings.Repeat("a", 64), strings.Repeat("b", 64))},
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

	bundle, binaryHash, metallibHash, bundleHash := buildSwiftReleaseBundleForTest(
		t, []byte("provider-binary"), []byte("metal-library"),
	)
	cdn := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/releases/v1.0.0/darkbloom-bundle-macos-arm64.tar.gz" &&
			r.URL.Path != "/releases/v1.1.0-beta.1/darkbloom-bundle-macos-arm64.tar.gz" {
			http.NotFound(w, r)
			return
		}
		w.Write(bundle)
	}))
	defer cdn.Close()
	srv.SetR2CDNURL(cdn.URL + "/")

	body := fmt.Sprintf(`{"version":"1.0.0","platform":"macos-arm64","backend":"mlx-swift","binary_hash":%q,"bundle_hash":%q,"metallib_hash":%q,"url":%q,"changelog":"First release"}`, binaryHash, bundleHash, metallibHash, cdn.URL+"/releases/v1.0.0/darkbloom-bundle-macos-arm64.tar.gz")
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

	// Register a beta after stable latest is cached. Registration must clear
	// both channel keys without exposing the beta through stable discovery.
	betaBody := fmt.Sprintf(`{"version":"1.1.0-beta.1","platform":"macos-arm64","channel":"beta","backend":"mlx-swift","binary_hash":%q,"bundle_hash":%q,"metallib_hash":%q,"url":%q}`,
		binaryHash, bundleHash, metallibHash, cdn.URL+"/releases/v1.1.0-beta.1/darkbloom-bundle-macos-arm64.tar.gz")
	req = httptest.NewRequest(http.MethodPost, "/v1/releases", strings.NewReader(betaBody))
	req.Header.Set("Authorization", "Bearer release-key")
	w = httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("register beta release: status = %d, body = %s", w.Code, w.Body.String())
	}

	for _, tc := range []struct {
		channel string
		want    string
	}{{"stable", "1.0.0"}, {"beta", "1.1.0-beta.1"}} {
		req = httptest.NewRequest(http.MethodGet, "/v1/releases/latest?platform=macos-arm64&channel="+tc.channel, nil)
		w = httptest.NewRecorder()
		srv.Handler().ServeHTTP(w, req)
		if w.Code != http.StatusOK {
			t.Fatalf("get %s latest: status = %d, body = %s", tc.channel, w.Code, w.Body.String())
		}
		var got store.Release
		if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil || got.Version != tc.want {
			t.Fatalf("get %s latest = %+v (err %v), want %s", tc.channel, got, err, tc.want)
		}
	}

	// Verify binary hashes were synced
	releases := st.ListReleases()
	if len(releases) != 2 {
		t.Errorf("expected two releases in store, got %d", len(releases))
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

func TestEdge_ReleaseRegisterVerifiesBundleArtifact(t *testing.T) {
	srv, st := testServer(t)
	srv.SetReleaseKey("release-key")

	bundle, binaryHash, bundleHash := buildReleaseBundleForTest(t, []byte("provider-binary"))
	cdn := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/releases/v1.0.0/darkbloom-bundle-macos-arm64.tar.gz" {
			http.NotFound(w, r)
			return
		}
		w.Write(bundle)
	}))
	defer cdn.Close()
	srv.SetR2CDNURL(cdn.URL)

	body := fmt.Sprintf(`{"version":"1.0.0","platform":"macos-arm64","binary_hash":%q,"bundle_hash":%q,"url":%q}`, binaryHash, bundleHash, cdn.URL+"/releases/v1.0.0/darkbloom-bundle-macos-arm64.tar.gz")
	req := httptest.NewRequest(http.MethodPost, "/v1/releases", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer release-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("release register with verified artifact: status = %d, want 200, body = %s", w.Code, w.Body.String())
	}
	releases := st.ListReleases()
	if len(releases) != 1 || releases[0].BinaryHash != binaryHash {
		t.Fatalf("release was not stored with verified binary hash: %+v", releases)
	}
}

func TestEdge_ReleaseRegisterAcceptsLegacyRegularBundleEntry(t *testing.T) {
	srv, st := testServer(t)
	srv.SetReleaseKey("release-key")

	bundle, binaryHash, bundleHash := buildReleaseBundleWithEntryForTest(t, "bin/darkbloom", tar.TypeRegA, []byte("provider-binary"), "")
	cdn := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/releases/v1.0.0/darkbloom-bundle-macos-arm64.tar.gz" {
			http.NotFound(w, r)
			return
		}
		w.Write(bundle)
	}))
	defer cdn.Close()
	srv.SetR2CDNURL(cdn.URL)

	body := fmt.Sprintf(`{"version":"1.0.0","platform":"macos-arm64","binary_hash":%q,"bundle_hash":%q,"url":%q}`, binaryHash, bundleHash, cdn.URL+"/releases/v1.0.0/darkbloom-bundle-macos-arm64.tar.gz")
	req := httptest.NewRequest(http.MethodPost, "/v1/releases", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer release-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("release register with legacy regular bundle entry: status = %d, want 200, body = %s", w.Code, w.Body.String())
	}
	releases := st.ListReleases()
	if len(releases) != 1 || releases[0].BinaryHash != binaryHash {
		t.Fatalf("release was not stored with legacy regular bundle entry: %+v", releases)
	}
}

func TestEdge_ReleaseRegisterRejectsBundledBinaryHashMismatch(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetReleaseKey("release-key")

	bundle, _, bundleHash := buildReleaseBundleForTest(t, []byte("provider-binary"))
	cdn := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/releases/v1.0.0/darkbloom-bundle-macos-arm64.tar.gz" {
			http.NotFound(w, r)
			return
		}
		w.Write(bundle)
	}))
	defer cdn.Close()
	srv.SetR2CDNURL(cdn.URL)

	wrongBinaryHash := strings.Repeat("c", 64)
	body := fmt.Sprintf(`{"version":"1.0.0","platform":"macos-arm64","binary_hash":%q,"bundle_hash":%q,"url":%q}`, wrongBinaryHash, bundleHash, cdn.URL+"/releases/v1.0.0/darkbloom-bundle-macos-arm64.tar.gz")
	req := httptest.NewRequest(http.MethodPost, "/v1/releases", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer release-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("release register with mismatched binary hash: status = %d, want 400, body = %s", w.Code, w.Body.String())
	}
}

func TestEdge_ReleaseRegisterRejectsBundledMetallibHashMismatch(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetReleaseKey("release-key")

	bundle, binaryHash, _, bundleHash := buildSwiftReleaseBundleForTest(
		t, []byte("provider-binary"), []byte("metal-library"),
	)
	cdn := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write(bundle)
	}))
	defer cdn.Close()
	srv.SetR2CDNURL(cdn.URL)

	body := fmt.Sprintf(`{"version":"1.0.0","platform":"macos-arm64","backend":"mlx-swift","binary_hash":%q,"bundle_hash":%q,"metallib_hash":%q,"url":%q}`,
		binaryHash, bundleHash, strings.Repeat("f", 64), cdn.URL+"/releases/v1.0.0/darkbloom-bundle-macos-arm64.tar.gz")
	req := httptest.NewRequest(http.MethodPost, "/v1/releases", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer release-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest || !strings.Contains(w.Body.String(), "metallib_hash") {
		t.Fatalf("metallib mismatch: status = %d, body = %s", w.Code, w.Body.String())
	}
}

func TestEdge_ReleaseRegisterRejectsOversizedBundledBinary(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetReleaseKey("release-key")

	bundle, bundleHash := buildOversizedBinaryReleaseBundleForTest(t)
	cdn := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/releases/v1.0.0/darkbloom-bundle-macos-arm64.tar.gz" {
			http.NotFound(w, r)
			return
		}
		w.Write(bundle)
	}))
	defer cdn.Close()
	srv.SetR2CDNURL(cdn.URL)

	binaryHash := strings.Repeat("d", 64)
	body := fmt.Sprintf(`{"version":"1.0.0","platform":"macos-arm64","binary_hash":%q,"bundle_hash":%q,"url":%q}`, binaryHash, bundleHash, cdn.URL+"/releases/v1.0.0/darkbloom-bundle-macos-arm64.tar.gz")
	req := httptest.NewRequest(http.MethodPost, "/v1/releases", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer release-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("release register with oversized bundled binary: status = %d, want 400, body = %s", w.Code, w.Body.String())
	}
}

func TestEdge_ReleaseRegisterRejectsRedirectedBundleDownload(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetReleaseKey("release-key")

	bundle, binaryHash, bundleHash := buildReleaseBundleForTest(t, []byte("provider-binary"))
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write(bundle)
	}))
	defer target.Close()

	cdn := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, target.URL+"/bundle.tar.gz", http.StatusFound)
	}))
	defer cdn.Close()
	srv.SetR2CDNURL(cdn.URL)

	body := fmt.Sprintf(`{"version":"1.0.0","platform":"macos-arm64","binary_hash":%q,"bundle_hash":%q,"url":%q}`, binaryHash, bundleHash, cdn.URL+"/releases/v1.0.0/darkbloom-bundle-macos-arm64.tar.gz")
	req := httptest.NewRequest(http.MethodPost, "/v1/releases", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer release-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("release register with redirected bundle: status = %d, want 400, body = %s", w.Code, w.Body.String())
	}
}

func TestEdge_ReleaseRegisterRejectsUnsafeBundlePath(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetReleaseKey("release-key")

	bundle, binaryHash, bundleHash := buildReleaseBundleWithEntryForTest(t, "../bin/darkbloom", tar.TypeReg, []byte("provider-binary"), "")
	cdn := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/releases/v1.0.0/darkbloom-bundle-macos-arm64.tar.gz" {
			http.NotFound(w, r)
			return
		}
		w.Write(bundle)
	}))
	defer cdn.Close()
	srv.SetR2CDNURL(cdn.URL)

	body := fmt.Sprintf(`{"version":"1.0.0","platform":"macos-arm64","binary_hash":%q,"bundle_hash":%q,"url":%q}`, binaryHash, bundleHash, cdn.URL+"/releases/v1.0.0/darkbloom-bundle-macos-arm64.tar.gz")
	req := httptest.NewRequest(http.MethodPost, "/v1/releases", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer release-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("release register with unsafe bundle path: status = %d, want 400, body = %s", w.Code, w.Body.String())
	}
}

func TestEdge_ReleaseRegisterRejectsNonRegularProviderBinary(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetReleaseKey("release-key")

	bundle, _, bundleHash := buildReleaseBundleWithEntryForTest(t, "bin/darkbloom", tar.TypeSymlink, nil, "darkbloom.real")
	cdn := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/releases/v1.0.0/darkbloom-bundle-macos-arm64.tar.gz" {
			http.NotFound(w, r)
			return
		}
		w.Write(bundle)
	}))
	defer cdn.Close()
	srv.SetR2CDNURL(cdn.URL)

	binaryHash := strings.Repeat("e", 64)
	body := fmt.Sprintf(`{"version":"1.0.0","platform":"macos-arm64","binary_hash":%q,"bundle_hash":%q,"url":%q}`, binaryHash, bundleHash, cdn.URL+"/releases/v1.0.0/darkbloom-bundle-macos-arm64.tar.gz")
	req := httptest.NewRequest(http.MethodPost, "/v1/releases", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer release-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("release register with non-regular provider binary: status = %d, want 400, body = %s", w.Code, w.Body.String())
	}
}

func buildReleaseBundleForTest(t *testing.T, binary []byte) ([]byte, string, string) {
	t.Helper()

	return buildReleaseBundleWithEntryForTest(t, "bin/darkbloom", tar.TypeReg, binary, "")
}

func buildSwiftReleaseBundleForTest(t *testing.T, binary, metallib []byte) ([]byte, string, string, string) {
	t.Helper()

	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	for name, content := range map[string][]byte{
		"bin/darkbloom":    binary,
		"bin/mlx.metallib": metallib,
	} {
		if err := tw.WriteHeader(&tar.Header{Name: name, Mode: 0o755, Size: int64(len(content)), Typeflag: tar.TypeReg}); err != nil {
			t.Fatalf("write %s tar header: %v", name, err)
		}
		if _, err := tw.Write(content); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatalf("close tar: %v", err)
	}
	if err := gz.Close(); err != nil {
		t.Fatalf("close gzip: %v", err)
	}

	return buf.Bytes(), sha256HexBytesForReleaseTest(binary), sha256HexBytesForReleaseTest(metallib), sha256HexBytesForReleaseTest(buf.Bytes())
}

func buildReleaseBundleWithEntryForTest(t *testing.T, name string, typeflag byte, binary []byte, linkname string) ([]byte, string, string) {
	t.Helper()

	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)

	header := &tar.Header{
		Name:     name,
		Mode:     0o755,
		Typeflag: typeflag,
		Linkname: linkname,
	}
	if typeflag == tar.TypeReg || typeflag == tar.TypeRegA {
		header.Size = int64(len(binary))
	}
	if err := tw.WriteHeader(header); err != nil {
		t.Fatalf("write tar header: %v", err)
	}
	if len(binary) > 0 {
		if _, err := tw.Write(binary); err != nil {
			t.Fatalf("write binary: %v", err)
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatalf("close tar: %v", err)
	}
	if err := gz.Close(); err != nil {
		t.Fatalf("close gzip: %v", err)
	}

	return buf.Bytes(), sha256HexBytesForReleaseTest(binary), sha256HexBytesForReleaseTest(buf.Bytes())
}

func buildOversizedBinaryReleaseBundleForTest(t *testing.T) ([]byte, string) {
	t.Helper()

	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	if err := tw.WriteHeader(&tar.Header{
		Name: "bin/darkbloom",
		Mode: 0o755,
		Size: maxReleaseProviderBinBytes + 1,
	}); err != nil {
		t.Fatalf("write oversized tar header: %v", err)
	}
	if err := gz.Close(); err != nil {
		t.Fatalf("close gzip: %v", err)
	}

	return buf.Bytes(), sha256HexBytesForReleaseTest(buf.Bytes())
}

func sha256HexBytesForReleaseTest(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}
