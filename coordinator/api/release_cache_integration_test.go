package api

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

type releaseArtifactSet struct {
	mu      sync.RWMutex
	bundles map[string][]byte
}

func (s *releaseArtifactSet) handler(w http.ResponseWriter, r *http.Request) {
	s.mu.RLock()
	bundle := append([]byte(nil), s.bundles[r.URL.Path]...)
	s.mu.RUnlock()
	if len(bundle) == 0 {
		http.NotFound(w, r)
		return
	}
	_, _ = w.Write(bundle)
}

func TestReleaseMutationsInvalidateImmediateReadsByPlatform(t *testing.T) {
	srv, st := testServer(t)
	srv.SetReleaseKey("release-key")
	srv.adminKey = "admin-key"

	artifacts := &releaseArtifactSet{bundles: make(map[string][]byte)}
	cdn := httptest.NewServer(http.HandlerFunc(artifacts.handler))
	defer cdn.Close()
	srv.SetR2CDNURL(cdn.URL)
	apiServer := httptest.NewServer(srv.Handler())
	defer apiServer.Close()

	setReleaseForCacheTest(t, st, "1.0.0", defaultReleasePlatform, "old")
	setReleaseForCacheTest(t, st, "0.9.0", "linux-amd64", "linux")
	assertReleaseVersion(t, apiServer.URL+"/v1/releases/latest?platform=macos-arm64", "1.0.0")
	linuxBefore := getReleaseBody(t, apiServer.URL+"/v1/releases/latest?platform=linux-amd64", http.StatusOK)
	assertVersionEndpoint(t, apiServer.URL, "1.0.0")
	_ = getReleaseBody(t, apiServer.URL+"/v1/runtime/manifest", http.StatusOK)

	registerReleaseForCacheTest(t, apiServer.URL, cdn.URL, artifacts, "1.1.0", "first")
	assertReleaseVersion(t, apiServer.URL+"/v1/releases/latest?platform=macos-arm64", "1.1.0")
	assertVersionEndpoint(t, apiServer.URL, "1.1.0")
	assertRuntimeManifestContains(t, apiServer.URL, strings.Repeat("f", 64))
	linuxAfter := getReleaseBody(t, apiServer.URL+"/v1/releases/latest?platform=linux-amd64", http.StatusOK)
	if !bytes.Equal(linuxBefore, linuxAfter) {
		t.Fatalf("macOS mutation changed isolated Linux latest response\nbefore=%s\nafter=%s", linuxBefore, linuxAfter)
	}

	registerReleaseForCacheTest(t, apiServer.URL, cdn.URL, artifacts, "1.1.0", "replacement")
	latest := getReleaseBody(t, apiServer.URL+"/v1/releases/latest?platform=macos-arm64", http.StatusOK)
	if !bytes.Contains(latest, []byte(`"changelog":"replacement"`)) {
		t.Fatalf("replacement was hidden by latest-release cache: %s", latest)
	}

	deactivateReleaseForCacheTest(t, apiServer.URL, "1.1.0", defaultReleasePlatform)
	assertReleaseVersion(t, apiServer.URL+"/v1/releases/latest?platform=macos-arm64", "1.0.0")
	assertVersionEndpoint(t, apiServer.URL, "1.0.0")

	registerReleaseForCacheTest(t, apiServer.URL, cdn.URL, artifacts, "1.1.0", "reactivated")
	assertReleaseVersion(t, apiServer.URL+"/v1/releases/latest?platform=macos-arm64", "1.1.0")

	deactivateReleaseForCacheTest(t, apiServer.URL, "1.1.0", defaultReleasePlatform)
	deactivateReleaseForCacheTest(t, apiServer.URL, "1.0.0", defaultReleasePlatform)
	_ = getReleaseBody(t, apiServer.URL+"/v1/releases/latest?platform=macos-arm64", http.StatusNotFound)
}

func setReleaseForCacheTest(t *testing.T, st store.Store, version, platform, changelog string) {
	t.Helper()
	if err := st.SetRelease(&store.Release{
		Version: version, Platform: platform, Backend: "mlx-swift",
		BinaryHash: strings.Repeat("a", 64), BundleHash: strings.Repeat("b", 64),
		MetallibHash: strings.Repeat("c", 64),
		URL:          "https://example.invalid/" + version,
		Changelog:    changelog,
	}); err != nil {
		t.Fatalf("seed release %s/%s: %v", version, platform, err)
	}
}

func registerReleaseForCacheTest(
	t *testing.T,
	baseURL, cdnURL string,
	artifacts *releaseArtifactSet,
	version, changelog string,
) {
	t.Helper()
	bundle, binaryHash, bundleHash := buildReleaseBundleForTest(t, []byte("provider-"+changelog))
	path := "/releases/v" + version + "/darkbloom-bundle-macos-arm64.tar.gz"
	artifacts.mu.Lock()
	artifacts.bundles[path] = bundle
	artifacts.mu.Unlock()
	payload := map[string]string{
		"version": version, "platform": defaultReleasePlatform, "backend": "mlx-swift",
		"binary_hash": binaryHash, "bundle_hash": bundleHash,
		"metallib_hash": strings.Repeat("f", 64), "url": cdnURL + path,
		"changelog": changelog,
	}
	body, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	req, err := http.NewRequest(http.MethodPost, baseURL+"/v1/releases", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer release-key")
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	responseBody, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("register %s: status=%d body=%s", version, resp.StatusCode, responseBody)
	}
}

func deactivateReleaseForCacheTest(t *testing.T, baseURL, version, platform string) {
	t.Helper()
	body := fmt.Sprintf(`{"version":%q,"platform":%q,"force":true}`, version, platform)
	req, err := http.NewRequest(http.MethodDelete, baseURL+"/v1/admin/releases", strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer admin-key")
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	responseBody, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("deactivate %s/%s: status=%d body=%s", version, platform, resp.StatusCode, responseBody)
	}
}

func assertReleaseVersion(t *testing.T, endpoint, want string) {
	t.Helper()
	body := getReleaseBody(t, endpoint, http.StatusOK)
	var release store.Release
	if err := json.Unmarshal(body, &release); err != nil {
		t.Fatal(err)
	}
	if release.Version != want {
		t.Fatalf("%s version=%q, want %q; body=%s", endpoint, release.Version, want, body)
	}
}

func assertVersionEndpoint(t *testing.T, baseURL, want string) {
	t.Helper()
	body := getReleaseBody(t, baseURL+"/api/version", http.StatusOK)
	var version struct {
		Version string `json:"version"`
	}
	if err := json.Unmarshal(body, &version); err != nil {
		t.Fatal(err)
	}
	if version.Version != want {
		t.Fatalf("/api/version=%q, want %q; body=%s", version.Version, want, body)
	}
}

func assertRuntimeManifestContains(t *testing.T, baseURL, want string) {
	t.Helper()
	body := getReleaseBody(t, baseURL+"/v1/runtime/manifest", http.StatusOK)
	if !bytes.Contains(body, []byte(want)) {
		t.Fatalf("runtime manifest did not refresh to %q: %s", want, body)
	}
}

func getReleaseBody(t *testing.T, endpoint string, wantStatus int) []byte {
	t.Helper()
	resp, err := http.Get(endpoint)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != wantStatus {
		t.Fatalf("GET %s: status=%d want=%d body=%s", endpoint, resp.StatusCode, wantStatus, body)
	}
	return body
}
