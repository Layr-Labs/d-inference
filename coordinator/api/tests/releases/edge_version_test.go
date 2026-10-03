package releases_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	api "github.com/eigeninference/d-inference/coordinator/api"
	testkit "github.com/eigeninference/d-inference/coordinator/api/tests/internal/testkit"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestEdge_VersionEndpoint(t *testing.T) {
	srv := testkit.New(t, api.ServerConfig{}).Server

	req := httptest.NewRequest(http.MethodGet, "/api/version", nil)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("version: status = %d, want 200", w.Code)
	}

	var resp map[string]any
	json.Unmarshal(w.Body.Bytes(), &resp)
	if resp["version"] == nil {
		t.Error("version response missing 'version' field")
	}
	if resp["download_url"] == nil {
		t.Error("version response missing 'download_url' field")
	}
}

func TestEdge_VersionEndpointIncludesSwiftReleaseMetadata(t *testing.T) {
	fixture := testkit.New(t, api.ServerConfig{})
	srv, st := fixture.Server, fixture.Store
	binaryHash := strings.Repeat("a", 64)
	bundleHash := strings.Repeat("b", 64)
	metallibHash := strings.Repeat("c", 64)
	if err := st.SetRelease(&store.Release{
		Version:      "1.2.3",
		Platform:     "macos-arm64",
		Backend:      "mlx-swift",
		BinaryHash:   binaryHash,
		BundleHash:   bundleHash,
		MetallibHash: metallibHash,
		URL:          "https://example.com/darkbloom.tar.gz",
		Changelog:    "Swift bridge",
	}); err != nil {
		t.Fatalf("SetRelease: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/api/version", nil)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("version: status = %d, want 200", w.Code)
	}

	var resp map[string]string
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if resp["backend"] != "mlx-swift" {
		t.Fatalf("backend = %q, want mlx-swift", resp["backend"])
	}
	if resp["binary_hash"] != binaryHash {
		t.Fatalf("binary_hash = %q, want %q", resp["binary_hash"], binaryHash)
	}
	if resp["bundle_hash"] != bundleHash {
		t.Fatalf("bundle_hash = %q, want %q", resp["bundle_hash"], bundleHash)
	}
	if resp["metallib_hash"] != metallibHash {
		t.Fatalf("metallib_hash = %q, want %q", resp["metallib_hash"], metallibHash)
	}
}
