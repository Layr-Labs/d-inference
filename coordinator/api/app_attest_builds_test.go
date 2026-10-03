package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func qualificationReleaseFixture(t *testing.T) (*Server, *memory.MemoryStore, store.AppAttestBuildIdentity) {
	t.Helper()
	s, st := testServerWithConfig(t, ServerConfig{AppAttestShadow: AppAttestShadowConfig{ServingEnabled: true, Environment: "production"}})
	t.Cleanup(s.Close)
	s.SetReleaseKey("release-key")
	s.SetAdminKey("admin-key")
	bundle, binary, digest := buildReleaseBundleForTest(t, []byte("provider-binary"))
	cdn := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write(bundle) }))
	t.Cleanup(cdn.Close)
	s.SetR2CDNURL(cdn.URL)
	url := cdn.URL + "/releases/v1.0.0/artifacts/" + digest + "/darkbloom-bundle-macos-arm64.tar.gz"
	build := store.AppAttestBuildIdentity{Release: store.Release{Version: "1.0.0", Platform: "macos-arm64", Backend: "mlx-swift",
		BinaryHash: binary, BundleHash: digest, MetallibHash: strings.Repeat("c", 64), URL: url},
		CodeDirectoryHash: strings.Repeat("d", 64), SourceCommit: strings.Repeat("e", 40), CIRunID: "123"}
	return s, st, build
}

func qualificationCall(t *testing.T, s *Server, method, path, key string, body any) *httptest.ResponseRecorder {
	t.Helper()
	raw, err := json.Marshal(body)
	if err != nil {
		t.Fatal(err)
	}
	r := httptest.NewRequest(method, path, bytes.NewReader(raw))
	r.Header.Set("Authorization", "Bearer "+key)
	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, r)
	return w
}

func qualificationBody(b store.AppAttestBuildIdentity) map[string]any {
	return map[string]any{"release": b.Release, "code_directory_hash": b.CodeDirectoryHash,
		"source_commit": b.SourceCommit, "ci_run_id": b.CIRunID, "evidence": "physical transition test evidence, run 123"}
}

func registrationBody(b store.AppAttestBuildIdentity) releaseRegistrationFixture {
	return releaseRegistrationFixture{Version: b.Release.Version, Platform: b.Release.Platform, Backend: b.Release.Backend,
		BinaryHash: b.Release.BinaryHash, BundleHash: b.Release.BundleHash, MetallibHash: b.Release.MetallibHash,
		URL: b.Release.URL, CodeDirectoryHash: b.CodeDirectoryHash, SourceCommit: b.SourceCommit, CIRunID: b.CIRunID}
}

func TestQualifiedPublicationRequiresSeparateOperatorApproval(t *testing.T) {
	s, st, b := qualificationReleaseFixture(t)
	old := b.Release
	old.Version, old.BinaryHash = "0.9.0", strings.Repeat("f", 64)
	if err := st.SetRelease(&old); err != nil {
		t.Fatal(err)
	}
	if w := qualificationCall(t, s, "POST", "/v1/releases", "release-key", registrationBody(b)); w.Code != 409 {
		t.Fatalf("unapproved publish: %d %s", w.Code, w.Body)
	}
	if st.GetLatestRelease("macos-arm64").Version != old.Version {
		t.Fatal("failure advanced latest")
	}
	for _, token := range []string{"", "release-key"} {
		if w := qualificationCall(t, s, "POST", "/v1/admin/app-attest/builds", token, qualificationBody(b)); w.Code != 401 {
			t.Fatalf("CI granted its own approval: %d", w.Code)
		}
	}
	for _, field := range []string{"approved_by", "approved_at", "revoked_at"} {
		body := qualificationBody(b)
		body[field] = "forged"
		if w := qualificationCall(t, s, "POST", "/v1/admin/app-attest/builds", "admin-key", body); w.Code != 400 {
			t.Fatalf("forged audit accepted: %d", w.Code)
		}
	}
	if w := qualificationCall(t, s, "POST", "/v1/admin/app-attest/builds", "admin-key", qualificationBody(b)); w.Code != 200 {
		t.Fatalf("approve: %d %s", w.Code, w.Body)
	}
	if st.GetLatestRelease("macos-arm64").Version != old.Version {
		t.Fatal("approval itself published release")
	}
	for range 2 {
		if w := qualificationCall(t, s, "POST", "/v1/releases", "release-key", registrationBody(b)); w.Code != 200 {
			t.Fatalf("publish/retry: %d %s", w.Code, w.Body)
		}
	}
	if w := qualificationCall(t, s, "GET", "/v1/releases/latest", "", nil); w.Code != 200 || !strings.Contains(w.Body.String(), b.Release.BundleHash) {
		t.Fatalf("latest %d %s", w.Code, w.Body)
	}
	if w := qualificationCall(t, s, "GET", "/api/version", "", nil); w.Code != 200 {
		t.Fatalf("version before withdrawal: %d %s", w.Code, w.Body)
	}
	if w := qualificationCall(t, s, "POST", "/v1/admin/app-attest/builds/revoke", "admin-key", map[string]string{"binary_hash": b.Release.BinaryHash, "reason": "withdraw qualification"}); w.Code != 200 {
		t.Fatalf("revoke: %d %s", w.Code, w.Body)
	}
	if w := qualificationCall(t, s, "GET", "/v1/releases/latest", "", nil); w.Code != 503 {
		t.Fatalf("cached download survived revocation: %d", w.Code)
	}
	if w := qualificationCall(t, s, "GET", "/api/version", "", nil); w.Code != 503 {
		t.Fatalf("cached version download survived revocation: %d", w.Code)
	}
	if w := qualificationCall(t, s, "POST", "/v1/releases", "release-key", registrationBody(b)); w.Code != 409 {
		t.Fatalf("revoked release republished: %d", w.Code)
	}
}

type unavailableBuildStore struct{ *memory.MemoryStore }

func (*unavailableBuildStore) ListAppAttestBuildQualifications(context.Context) ([]store.AppAttestBuildQualification, error) {
	return nil, errors.New("qualification database unavailable")
}

func TestQualifiedPublicationMissingFieldsAndStoreOutageFailClosed(t *testing.T) {
	s, st, b := qualificationReleaseFixture(t)
	req := registrationBody(b)
	req.CodeDirectoryHash = ""
	if w := qualificationCall(t, s, "POST", "/v1/releases", "release-key", req); w.Code != 409 {
		t.Fatalf("old publisher bypass: %d", w.Code)
	}
	unavailable := NewServer(s.registry, &unavailableBuildStore{st}, ServerConfig{AppAttestShadow: AppAttestShadowConfig{ServingEnabled: true, Environment: "production"}}, s.logger)
	t.Cleanup(unavailable.Close)
	unavailable.SetReleaseKey("release-key")
	unavailable.SetR2CDNURL(strings.Split(b.Release.URL, "/releases/")[0])
	s = unavailable
	if w := qualificationCall(t, s, "POST", "/v1/releases", "release-key", registrationBody(b)); w.Code != 503 {
		t.Fatalf("storage error: %d %s", w.Code, w.Body)
	}
	if st.GetLatestRelease("macos-arm64") != nil {
		t.Fatal("store outage advanced latest")
	}
}

func TestRemoteReleaseRefreshConvergesWithoutGenerationChurn(t *testing.T) {
	s, st, b := qualificationReleaseFixture(t)
	if err := st.SetRelease(&b.Release); err != nil {
		t.Fatal(err)
	}
	if err := s.releases.RefreshAppAttestReleaseCatalog(); err != nil {
		t.Fatal(err)
	}
	first := s.releases.Policy()
	if !first.ContainsQualifiedRelease(b.Release) {
		t.Fatal("remote publication not loaded")
	}
	for range 3 {
		if err := s.releases.RefreshAppAttestReleaseCatalog(); err != nil {
			t.Fatal(err)
		}
	}
	if s.releases.Policy().Generation != first.Generation {
		t.Fatal("unchanged catalog invalidated live leases")
	}
	if err := st.DeleteRelease(b.Release.Version, b.Release.Platform); err != nil {
		t.Fatal(err)
	}
	if err := s.releases.RefreshAppAttestReleaseCatalog(); err != nil {
		t.Fatal(err)
	}
	if s.releases.Policy().Known() {
		t.Fatal("remote release withdrawal did not fence")
	}
}

type releaseRegistrationFixture struct {
	RequireAppAttestQualification bool   `json:"require_app_attest_qualification,omitempty"`
	CodeDirectoryHash             string `json:"code_directory_hash,omitempty"`
	SourceCommit                  string `json:"source_commit,omitempty"`
	CIRunID                       string `json:"ci_run_id,omitempty"`
	Version                       string `json:"version"`
	Platform                      string `json:"platform"`
	Backend                       string `json:"backend,omitempty"`
	BinaryHash                    string `json:"binary_hash"`
	BundleHash                    string `json:"bundle_hash"`
	MetallibHash                  string `json:"metallib_hash,omitempty"`
	TemplateHashes                string `json:"template_hashes,omitempty"`
	URL                           string `json:"url"`
	Changelog                     string `json:"changelog"`
}
