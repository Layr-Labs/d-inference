package releases_test

import (
	"context"
	"errors"
	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"log/slog"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

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
	logger := slog.New(slog.DiscardHandler)
	unavailable := api.NewServer(registry.New(logger), &unavailableBuildStore{st}, api.ServerConfig{AppAttestShadow: api.AppAttestShadowConfig{ServingEnabled: true, Environment: "production"}}, logger)
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
