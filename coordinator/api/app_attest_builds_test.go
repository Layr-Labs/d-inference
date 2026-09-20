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
)

func qualificationReleaseFixture(t *testing.T) (*Server, *store.MemoryStore, store.AppAttestBuildIdentity) {
	t.Helper()
	s, st := testServer(t)
	t.Cleanup(s.Close)
	s.SetReleaseKey("release-key")
	s.SetAdminKey("admin-key")
	s.appAttestShadow.ServingEnabled, s.appAttestShadow.Environment = true, "production"
	bundle, binary, digest := buildReleaseBundleForTest(t, []byte("provider-binary"))
	cdn := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write(bundle) }))
	t.Cleanup(cdn.Close)
	s.SetR2CDNURL(cdn.URL)
	url, err := expectedReleaseArtifactURL(cdn.URL, "1.0.0", "macos-arm64", digest)
	if err != nil {
		t.Fatal(err)
	}
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

func registrationBody(b store.AppAttestBuildIdentity) registerReleaseRequest {
	return registerReleaseRequest{Version: b.Release.Version, Platform: b.Release.Platform, Backend: b.Release.Backend,
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
		if w := qualificationCall(t, s, "POST", "/v1/admin/app-attest/builds", token, qualificationBody(b)); w.Code != 403 {
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

type unavailableBuildStore struct{ *store.MemoryStore }

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
	unavailable := NewServer(s.registry, &unavailableBuildStore{st}, ServerConfig{}, s.logger)
	t.Cleanup(unavailable.Close)
	unavailable.SetReleaseKey("release-key")
	unavailable.SetR2CDNURL(s.r2CDNURL)
	unavailable.appAttestShadow = s.appAttestShadow
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
	if err := s.refreshAppAttestReleaseCatalog(); err != nil {
		t.Fatal(err)
	}
	first := s.releaseTrustPolicy.Load()
	if len(first.ByBinaryHash[b.Release.BinaryHash]) != 1 {
		t.Fatal("remote publication not loaded")
	}
	for range 3 {
		if err := s.refreshAppAttestReleaseCatalog(); err != nil {
			t.Fatal(err)
		}
	}
	if s.releaseTrustPolicy.Load() != first {
		t.Fatal("unchanged catalog invalidated live leases")
	}
	if err := st.DeleteRelease(b.Release.Version, b.Release.Platform); err != nil {
		t.Fatal(err)
	}
	if err := s.refreshAppAttestReleaseCatalog(); err != nil {
		t.Fatal(err)
	}
	if len(s.releaseTrustPolicy.Load().ByBinaryHash) != 0 {
		t.Fatal("remote release withdrawal did not fence")
	}
}
