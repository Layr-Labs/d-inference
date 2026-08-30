package api

import (
	"errors"
	"net/http"
	"strings"
	"sync"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type releaseInventoryFailureStore struct {
	*store.MemoryStore
	mu              sync.Mutex
	failReads       bool
	emptyReads      bool
	failAfterDelete bool
	deleteCalls     int
}

func (s *releaseInventoryFailureStore) ListReleasesWithError() ([]store.Release, error) {
	s.mu.Lock()
	fail := s.failReads
	empty := s.emptyReads
	s.mu.Unlock()
	if fail {
		return nil, errors.New("simulated release inventory read failure")
	}
	if empty {
		return []store.Release{}, nil
	}
	return s.MemoryStore.ListReleasesWithError()
}

func (s *releaseInventoryFailureStore) DeleteRelease(version, platform string) error {
	if err := s.MemoryStore.DeleteRelease(version, platform); err != nil {
		return err
	}
	s.mu.Lock()
	s.deleteCalls++
	if s.failAfterDelete {
		s.failReads = true
	}
	s.mu.Unlock()
	return nil
}

func (s *releaseInventoryFailureStore) setFailReads(fail bool) {
	s.mu.Lock()
	s.failReads = fail
	s.mu.Unlock()
}

func testRelease(version, hash string) *store.Release {
	return &store.Release{
		Version: version, Platform: defaultReleasePlatform, Backend: registry.BackendMLXSwift,
		BinaryHash: hash, BundleHash: strings.Repeat("f", 64),
		URL: "https://releases.example/" + version + ".tar.gz",
	}
}

func grantReleaseEvidenceForTest(t *testing.T, provider *registry.Provider, generation uint64, binaryHash string) {
	t.Helper()
	provider.Mu().Lock()
	provider.Version = "2.0.0"
	provider.APNsDeviceToken = "apns-token"
	provider.MetallibVerified = true
	provider.AttestationResult = &attestation.VerificationResult{
		Valid: true, PublicKey: "se-release", SerialNumber: "SER-RELEASE",
	}
	provider.Mu().Unlock()
	if !provider.GrantApplicationEvidenceIfNotUntrusted(registry.ApplicationEvidence{
		SEPublicKey: "se-release", Serial: "SER-RELEASE",
		ProcessPublicKey: provider.PublicKey, APNsToken: "apns-token",
		BinaryHash: binaryHash, Version: "2.0.0", Backend: registry.BackendMLXSwift,
		PolicyGeneration: generation,
	}) {
		t.Fatal("failed to grant release evidence test precondition")
	}
}

func TestSyncBinaryHashesInventoryFailurePublishesDenyAllAndDeroutesConnectedProvider(t *testing.T) {
	st := &releaseInventoryFailureStore{MemoryStore: store.NewMemory(store.Config{})}
	if err := st.SetRelease(testRelease("2.0.0", trHashA)); err != nil {
		t.Fatalf("SetRelease: %v", err)
	}
	logger := quietLogger()
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	if err := srv.SyncBinaryHashes(); err != nil {
		t.Fatalf("initial SyncBinaryHashes: %v", err)
	}
	snapshot := srv.releaseTrustPolicy.Load()
	if snapshot == nil || !snapshot.Required || len(snapshot.ByBinaryHash[trHashA]) != 1 {
		t.Fatalf("initial release policy = %+v", snapshot)
	}

	const model = "release-failclosed-model"
	provider := makeRoutableProvider(t, reg, "release-provider", model)
	grantReleaseEvidenceForTest(t, provider, snapshot.Generation, trHashA)
	if routed := findRoutableProvider(reg, model); routed == nil || routed.ID != provider.ID {
		t.Fatalf("provider was not routable before inventory failure: %#v", routed)
	}

	st.setFailReads(true)
	if err := srv.SyncBinaryHashes(); err == nil {
		t.Fatal("inventory failure must be returned to startup/handler caller")
	}
	failed := srv.releaseTrustPolicy.Load()
	if failed == nil || !failed.Required || len(failed.ByBinaryHash) != 0 || failed.Generation <= snapshot.Generation {
		t.Fatalf("failed-read policy is not a fresh deny-all generation: %+v", failed)
	}
	if _, ok := provider.ApplicationEvidenceSnapshot(); ok {
		t.Fatal("inventory failure did not clear connected application evidence")
	}
	if routed := findRoutableProvider(reg, model); routed != nil {
		t.Fatalf("provider remained routable after release inventory failure: %s", routed.ID)
	}

	st.setFailReads(false)
	if err := srv.SyncBinaryHashes(); err != nil {
		t.Fatalf("recovery SyncBinaryHashes: %v", err)
	}
	recovered := srv.releaseTrustPolicy.Load()
	if recovered == nil || !recovered.Required || len(recovered.ByBinaryHash) != 1 || len(recovered.ByBinaryHash[trHashA]) != 1 {
		t.Fatalf("recovered release policy did not restore exact active inventory: %+v", recovered)
	}
	grantReleaseEvidenceForTest(t, provider, recovered.Generation, trHashA)
	if routed := findRoutableProvider(reg, model); routed == nil || routed.ID != provider.ID {
		t.Fatalf("provider did not recover after fresh evidence on recovered generation: %#v", routed)
	}
}

func TestSyncBinaryHashesSuccessfulEmptyInventoryIsOnlyNonRequiredCase(t *testing.T) {
	logger := quietLogger()
	st := &releaseInventoryFailureStore{MemoryStore: store.NewMemory(store.Config{})}
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)
	if err := srv.SyncBinaryHashes(); err != nil {
		t.Fatalf("SyncBinaryHashes: %v", err)
	}
	snapshot := srv.releaseTrustPolicy.Load()
	if snapshot == nil || snapshot.Required || len(snapshot.ByBinaryHash) != 0 {
		t.Fatalf("successful never-configured empty inventory policy = %+v, want non-required empty policy", snapshot)
	}

	if err := st.SetRelease(testRelease("2.0.0", trHashA)); err != nil {
		t.Fatalf("SetRelease: %v", err)
	}
	if err := srv.SyncBinaryHashes(); err != nil {
		t.Fatalf("configured SyncBinaryHashes: %v", err)
	}
	st.mu.Lock()
	st.emptyReads = true
	st.mu.Unlock()
	if err := srv.SyncBinaryHashes(); err != nil {
		t.Fatalf("post-configuration empty SyncBinaryHashes: %v", err)
	}
	if afterConfigured := srv.releaseTrustPolicy.Load(); afterConfigured == nil ||
		!afterConfigured.Required || len(afterConfigured.ByBinaryHash) != 0 {
		t.Fatalf("empty inventory disabled a previously configured policy: %+v", afterConfigured)
	}
}

func TestStartupReleaseSyncContractReturnsInventoryReadFailure(t *testing.T) {
	st := &releaseInventoryFailureStore{MemoryStore: store.NewMemory(store.Config{}), failReads: true}
	logger := quietLogger()
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)
	if err := srv.SyncBinaryHashes(); err == nil {
		t.Fatal("startup release sync must receive an error for an unreadable inventory")
	}
	if snapshot := srv.releaseTrustPolicy.Load(); snapshot == nil || !snapshot.Required || len(snapshot.ByBinaryHash) != 0 {
		t.Fatalf("startup failure did not leave deny-all policy: %+v", snapshot)
	}
}

func TestReleaseDeactivationReadFailureReturnsFailureAfterCommitWithoutPermissivePolicy(t *testing.T) {
	st := &releaseInventoryFailureStore{
		MemoryStore:     store.NewMemory(store.Config{}),
		failAfterDelete: true,
	}
	if err := st.SetRelease(testRelease("2.0.0", trHashA)); err != nil {
		t.Fatalf("SetRelease: %v", err)
	}
	logger := quietLogger()
	srv := NewServer(registry.New(logger), st, ServerConfig{AdminKey: "admin-key"}, logger)
	if err := srv.SyncBinaryHashes(); err != nil {
		t.Fatalf("initial SyncBinaryHashes: %v", err)
	}

	response := doReq(srv, http.MethodDelete, "/v1/admin/releases", "Bearer admin-key",
		`{"version":"2.0.0","platform":"macos-arm64"}`)
	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("deactivation response = %d, want 503; body=%s", response.Code, response.Body.String())
	}
	releases := st.MemoryStore.ListReleases()
	if len(releases) != 1 || releases[0].Active {
		t.Fatalf("release deactivation did not commit before read failure: %+v", releases)
	}
	failed := srv.releaseTrustPolicy.Load()
	if failed == nil || !failed.Required || len(failed.ByBinaryHash) != 0 {
		t.Fatalf("deactivation read failure published permissive policy: %+v", failed)
	}

	st.setFailReads(false)
	if err := srv.SyncBinaryHashes(); err != nil {
		t.Fatalf("recovery SyncBinaryHashes: %v", err)
	}
	recovered := srv.releaseTrustPolicy.Load()
	if recovered == nil || !recovered.Required || len(recovered.ByBinaryHash) != 0 {
		t.Fatalf("recovery did not restore exact inactive inventory semantics: %+v", recovered)
	}
}

func TestReleaseDeactivationAdminPrecheckFailsClosedOnInventoryError(t *testing.T) {
	st := &releaseInventoryFailureStore{MemoryStore: store.NewMemory(store.Config{}), failReads: true}
	if err := st.SetRelease(testRelease("2.0.0", trHashA)); err != nil {
		t.Fatalf("SetRelease: %v", err)
	}
	logger := quietLogger()
	srv := NewServer(registry.New(logger), st, ServerConfig{AdminKey: "admin-key"}, logger)
	srv.SetBinaryHashEnforcement(true)

	response := doReq(srv, http.MethodDelete, "/v1/admin/releases", "Bearer admin-key",
		`{"version":"2.0.0","platform":"macos-arm64"}`)
	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("precheck response = %d, want 503; body=%s", response.Code, response.Body.String())
	}
	st.mu.Lock()
	deleteCalls := st.deleteCalls
	st.mu.Unlock()
	if deleteCalls != 0 {
		t.Fatalf("precheck failure performed %d deactivations", deleteCalls)
	}
	if releases := st.MemoryStore.ListReleases(); len(releases) != 1 || !releases[0].Active {
		t.Fatalf("precheck failure changed release inventory: %+v", releases)
	}
}
