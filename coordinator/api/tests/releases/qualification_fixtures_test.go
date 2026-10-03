package releases_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/api/tests/internal/testkit"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func qualificationReleaseFixture(t *testing.T) (*api.Server, *memory.MemoryStore, store.AppAttestBuildIdentity) {
	t.Helper()
	f := testkit.New(t, api.ServerConfig{AppAttestShadow: api.AppAttestShadowConfig{ServingEnabled: true, Environment: "production"}})
	s := f.Server
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
	return s, f.Store, build
}

func qualificationCall(t *testing.T, s *api.Server, method, path, key string, body any) *httptest.ResponseRecorder {
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

func seedUser(t *testing.T, st *memory.MemoryStore, accountID, email string) *store.User {
	t.Helper()
	u := &store.User{AccountID: accountID, PrivyUserID: "did:privy:" + accountID, Email: email}
	if err := st.CreateUser(u); err != nil {
		t.Fatal(err)
	}
	return u
}
