package api

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestLatestReleaseNotFound(t *testing.T) {
	srv, _ := testServer(t)
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/v1/releases/latest?platform=macos-arm64", nil))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("latest release status = %d, want 404; body=%s", rec.Code, rec.Body.String())
	}
}

func TestRegisterReleaseAuthentication(t *testing.T) {
	for _, test := range []struct {
		name  string
		token string
	}{
		{name: "missing token"},
		{name: "wrong token", token: "wrong-key"},
	} {
		t.Run(test.name, func(t *testing.T) {
			srv, st := testServer(t)
			srv.SetReleaseKey("release-key")
			release := releaseRegistrationFixture(t)
			rec := postReleaseRegistration(t, srv, release, test.token)
			if rec.Code != http.StatusUnauthorized {
				t.Fatalf("status = %d, want 401; body=%s", rec.Code, rec.Body.String())
			}
			if releases := st.ListReleases(); len(releases) != 0 {
				t.Fatalf("unauthorized registration persisted releases: %+v", releases)
			}
		})
	}
}

func TestRegisterReleaseValidation(t *testing.T) {
	valid := releaseRegistrationFixture(t)
	for _, test := range []struct {
		name   string
		mutate func(map[string]any)
	}{
		{name: "missing version", mutate: func(v map[string]any) { delete(v, "version") }},
		{name: "empty version", mutate: func(v map[string]any) { v["version"] = "" }},
		{name: "missing hashes", mutate: func(v map[string]any) { delete(v, "binary_hash"); delete(v, "bundle_hash") }},
		{name: "missing URL", mutate: func(v map[string]any) { delete(v, "url") }},
		{name: "invalid hashes", mutate: func(v map[string]any) { v["binary_hash"] = "abc"; v["bundle_hash"] = "def" }},
		{name: "missing mlx metallib", mutate: func(v map[string]any) { delete(v, "metallib_hash") }},
		{name: "store-only active", mutate: func(v map[string]any) { v["active"] = true }},
		{name: "store-only created_at", mutate: func(v map[string]any) { v["created_at"] = "2099-01-01T00:00:00Z" }},
	} {
		t.Run(test.name, func(t *testing.T) {
			srv, st := testServer(t)
			srv.SetReleaseKey("release-key")
			payload := cloneReleasePayload(valid)
			test.mutate(payload)
			rec := postReleaseRegistration(t, srv, payload, "release-key")
			if rec.Code != http.StatusBadRequest {
				t.Fatalf("status = %d, want 400; body=%s", rec.Code, rec.Body.String())
			}
			if releases := st.ListReleases(); len(releases) != 0 {
				t.Fatalf("invalid registration persisted releases: %+v", releases)
			}
		})
	}
}

func TestRegisterReleaseArtifactOriginPolicy(t *testing.T) {
	for _, test := range []struct {
		name   string
		origin string
		url    string
	}{
		{
			name:   "off origin",
			origin: "https://r2.example.com",
			url:    "https://evil.example.com/releases/v9.1.0/darkbloom-bundle-macos-arm64.tar.gz",
		},
		{
			name:   "HTTP origin",
			origin: "http://r2.example.com",
			url:    "http://r2.example.com/releases/v9.1.0/darkbloom-bundle-macos-arm64.tar.gz",
		},
		{
			name:   "credentialed URL",
			origin: "https://r2.example.com",
			url:    "https://user:pass@r2.example.com/releases/v9.1.0/darkbloom-bundle-macos-arm64.tar.gz",
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			srv, st := testServer(t)
			srv.SetReleaseKey("release-key")
			srv.SetR2CDNURL(test.origin)
			payload := releaseRegistrationFixture(t)
			payload["url"] = test.url
			rec := postReleaseRegistration(t, srv, payload, "release-key")
			if rec.Code != http.StatusBadRequest {
				t.Fatalf("status = %d, want 400; body=%s", rec.Code, rec.Body.String())
			}
			if releases := st.ListReleases(); len(releases) != 0 {
				t.Fatalf("rejected origin persisted releases: %+v", releases)
			}
		})
	}
}

func TestRegisterReleaseVerifiesAndServesSharedFixtureMetadata(t *testing.T) {
	srv, st := testServer(t)
	srv.SetReleaseKey("release-key")
	bundle, binaryHash, bundleHash := buildReleaseBundleForTest(t, []byte("provider-binary"))
	path := "/releases/v9.1.0/darkbloom-bundle-macos-arm64.tar.gz"
	cdn := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != path {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write(bundle)
	}))
	defer cdn.Close()
	srv.SetR2CDNURL(cdn.URL)

	payload := releaseRegistrationFixture(t)
	payload["binary_hash"] = binaryHash
	payload["bundle_hash"] = bundleHash
	payload["url"] = cdn.URL + path
	rec := postReleaseRegistration(t, srv, payload, "release-key")
	if rec.Code != http.StatusOK {
		t.Fatalf("register status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}

	rec = httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/v1/releases/latest?platform=macos-arm64", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("latest status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	var latest store.Release
	if err := json.Unmarshal(rec.Body.Bytes(), &latest); err != nil {
		t.Fatal(err)
	}
	if latest.Version != payload["version"] || latest.Backend != payload["backend"] || latest.MetallibHash != payload["metallib_hash"] || latest.Changelog != payload["changelog"] {
		t.Fatalf("latest release lost shared fixture metadata: %+v", latest)
	}
	if latest.BinaryHash != binaryHash || latest.BundleHash != bundleHash || latest.URL != cdn.URL+path {
		t.Fatalf("latest release artifact metadata mismatch: %+v", latest)
	}
	if releases := st.ListReleases(); len(releases) != 1 || releases[0].BinaryHash != binaryHash {
		t.Fatalf("verified release was not persisted exactly once: %+v", releases)
	}
}

func TestRegisterReleaseBundleSafety(t *testing.T) {
	for _, test := range []struct {
		name       string
		bundle     func(*testing.T) ([]byte, string, string)
		redirect   bool
		wantStatus int
	}{
		{
			name: "legacy regular entry",
			bundle: func(t *testing.T) ([]byte, string, string) {
				return buildReleaseBundleWithEntryForTest(t, "bin/darkbloom", tar.TypeRegA, []byte("provider-binary"), "")
			},
			wantStatus: http.StatusOK,
		},
		{
			name: "bundled binary hash mismatch",
			bundle: func(t *testing.T) ([]byte, string, string) {
				bundle, _, bundleHash := buildReleaseBundleForTest(t, []byte("provider-binary"))
				return bundle, strings.Repeat("d", 64), bundleHash
			},
			wantStatus: http.StatusBadRequest,
		},
		{
			name: "oversized bundled binary",
			bundle: func(t *testing.T) ([]byte, string, string) {
				bundle, bundleHash := buildOversizedBinaryReleaseBundleForTest(t)
				return bundle, strings.Repeat("d", 64), bundleHash
			},
			wantStatus: http.StatusBadRequest,
		},
		{
			name: "redirected bundle download",
			bundle: func(t *testing.T) ([]byte, string, string) {
				return buildReleaseBundleForTest(t, []byte("provider-binary"))
			},
			redirect:   true,
			wantStatus: http.StatusBadRequest,
		},
		{
			name: "unsafe bundle path",
			bundle: func(t *testing.T) ([]byte, string, string) {
				return buildReleaseBundleWithEntryForTest(t, "../bin/darkbloom", tar.TypeReg, []byte("provider-binary"), "")
			},
			wantStatus: http.StatusBadRequest,
		},
		{
			name: "non-regular provider binary",
			bundle: func(t *testing.T) ([]byte, string, string) {
				bundle, _, bundleHash := buildReleaseBundleWithEntryForTest(t, "bin/darkbloom", tar.TypeSymlink, nil, "darkbloom.real")
				return bundle, strings.Repeat("e", 64), bundleHash
			},
			wantStatus: http.StatusBadRequest,
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			srv, st := testServer(t)
			srv.SetReleaseKey("release-key")
			bundle, binaryHash, bundleHash := test.bundle(t)
			path := "/releases/v9.1.0/darkbloom-bundle-macos-arm64.tar.gz"
			var target *httptest.Server
			if test.redirect {
				target = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write(bundle) }))
				defer target.Close()
			}
			cdn := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if test.redirect {
					http.Redirect(w, r, target.URL+"/bundle.tar.gz", http.StatusFound)
					return
				}
				_, _ = w.Write(bundle)
			}))
			defer cdn.Close()
			srv.SetR2CDNURL(cdn.URL)

			payload := releaseRegistrationFixture(t)
			payload["binary_hash"] = binaryHash
			payload["bundle_hash"] = bundleHash
			payload["url"] = cdn.URL + path
			rec := postReleaseRegistration(t, srv, payload, "release-key")
			if rec.Code != test.wantStatus {
				t.Fatalf("status = %d, want %d; body=%s", rec.Code, test.wantStatus, rec.Body.String())
			}
			wantStored := 0
			if test.wantStatus == http.StatusOK {
				wantStored = 1
			}
			if releases := st.ListReleases(); len(releases) != wantStored {
				t.Fatalf("stored releases = %d, want %d: %+v", len(releases), wantStored, releases)
			}
		})
	}
}

func releaseRegistrationFixture(t *testing.T) map[string]any {
	t.Helper()
	for _, fixture := range loadReleaseFixtureCorpus(t).Cases {
		if fixture.Name != "current_mlx_swift_signed_bundle" {
			continue
		}
		var payload map[string]any
		if err := json.Unmarshal(fixture.Response, &payload); err != nil {
			t.Fatal(err)
		}
		delete(payload, "active")
		delete(payload, "created_at")
		return payload
	}
	t.Fatal("shared release fixture is missing current_mlx_swift_signed_bundle")
	return nil
}

func cloneReleasePayload(payload map[string]any) map[string]any {
	clone := make(map[string]any, len(payload))
	for key, value := range payload {
		clone[key] = value
	}
	return clone
}

func postReleaseRegistration(t *testing.T, srv *Server, payload map[string]any, token string) *httptest.ResponseRecorder {
	t.Helper()
	body, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodPost, "/v1/releases", bytes.NewReader(body))
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	return rec
}

func buildReleaseBundleForTest(t *testing.T, binary []byte) ([]byte, string, string) {
	t.Helper()
	return buildReleaseBundleWithEntryForTest(t, "bin/darkbloom", tar.TypeReg, binary, "")
}

func buildReleaseBundleWithEntryForTest(t *testing.T, name string, typeflag byte, binary []byte, linkname string) ([]byte, string, string) {
	t.Helper()
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	header := &tar.Header{Name: name, Mode: 0o755, Typeflag: typeflag, Linkname: linkname}
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
	if err := tw.WriteHeader(&tar.Header{Name: "bin/darkbloom", Mode: 0o755, Size: maxReleaseProviderBinBytes + 1}); err != nil {
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
