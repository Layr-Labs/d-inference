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
		MetallibHash: trHashC,
		URL:          "https://releases.example/" + version + ".tar.gz",
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
		BinaryHash: binaryHash, Version: "2.0.0", Platform: defaultReleasePlatform,
		Backend: registry.BackendMLXSwift, MetallibHash: trHashC,
		PolicyGeneration: generation,
	}) {
		t.Fatal("failed to grant release evidence test precondition")
	}
}

// TestSyncBinaryHashesInventoryFailureRetainsLastKnownGoodPolicy is the
// incident-class regression (review finding 1): a failed/timed-out store
// ListReleases is a routine OPERATIONAL event and must NOT be re-interpreted
// as a change in the approved release set. With a previously published policy,
// SyncBinaryHashes keeps the last-known-good snapshot untouched (mirroring
// SyncRuntimeManifest's handling), surfaces the error to the caller, and a
// healthy connected provider stays routable throughout the outage.
func TestSyncBinaryHashesInventoryFailureRetainsLastKnownGoodPolicy(t *testing.T) {
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
		t.Fatal("inventory failure must still be surfaced to the caller")
	}
	retained := srv.releaseTrustPolicy.Load()
	if retained == nil || !retained.Required ||
		retained.Generation != snapshot.Generation ||
		len(retained.ByBinaryHash[trHashA]) != 1 {
		t.Fatalf("read failure did not retain the last-known-good policy: %+v", retained)
	}
	if _, ok := provider.ApplicationEvidenceSnapshot(); !ok {
		t.Fatal("operational inventory failure cleared connected application evidence")
	}
	if routed := findRoutableProvider(reg, model); routed == nil || routed.ID != provider.ID {
		t.Fatal("healthy provider was derouted by a release inventory read failure")
	}

	// Recovery converges back onto the exact active inventory and — because the
	// provider's evidence is still approved under it — carries the evidence
	// forward at the new generation with no re-challenge round-trip.
	st.setFailReads(false)
	if err := srv.SyncBinaryHashes(); err != nil {
		t.Fatalf("recovery SyncBinaryHashes: %v", err)
	}
	recovered := srv.releaseTrustPolicy.Load()
	if recovered == nil || !recovered.Required || len(recovered.ByBinaryHash) != 1 || len(recovered.ByBinaryHash[trHashA]) != 1 {
		t.Fatalf("recovered release policy did not restore exact active inventory: %+v", recovered)
	}
	if evidence, ok := provider.ApplicationEvidenceSnapshot(); !ok || evidence.PolicyGeneration != recovered.Generation {
		t.Fatalf("recovery did not carry still-approved evidence forward: %+v ok=%v", evidence, ok)
	}
	if routed := findRoutableProvider(reg, model); routed == nil || routed.ID != provider.ID {
		t.Fatalf("provider did not stay routable across the recovery sync: %#v", routed)
	}
}

// TestSyncBinaryHashesReleaseRegistrationKeepsApprovedFleetRoutable is the
// upgrade-storm regression (review finding 3): registering an ADDITIONAL
// release advances the policy generation, but a connected provider whose
// evidence is still approved under the new snapshot must stay routable (its
// evidence is re-stamped, not cleared, and no re-challenge is requested).
// Deactivating the provider's release then genuinely invalidates it — its
// evidence is cleared synchronously AND an immediate out-of-band re-challenge
// is requested instead of waiting for the periodic ticker.
func TestSyncBinaryHashesReleaseRegistrationKeepsApprovedFleetRoutable(t *testing.T) {
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

	const model = "release-storm-model"
	provider := makeRoutableProvider(t, reg, "storm-provider", model)
	grantReleaseEvidenceForTest(t, provider, snapshot.Generation, trHashA)
	if routed := findRoutableProvider(reg, model); routed == nil || routed.ID != provider.ID {
		t.Fatalf("provider was not routable before release registration: %#v", routed)
	}

	if err := st.SetRelease(testRelease("2.1.0", trHashB)); err != nil {
		t.Fatalf("SetRelease 2.1.0: %v", err)
	}
	if err := srv.SyncBinaryHashes(); err != nil {
		t.Fatalf("SyncBinaryHashes after registration: %v", err)
	}
	next := srv.releaseTrustPolicy.Load()
	if next.Generation <= snapshot.Generation {
		t.Fatalf("registration did not advance the generation: %d -> %d", snapshot.Generation, next.Generation)
	}
	evidence, ok := provider.ApplicationEvidenceSnapshot()
	if !ok || evidence.PolicyGeneration != next.Generation {
		t.Fatalf("still-approved evidence was not carried forward: %+v ok=%v", evidence, ok)
	}
	if routed := findRoutableProvider(reg, model); routed == nil || routed.ID != provider.ID {
		t.Fatal("routine release registration derouted a healthy, still-approved provider")
	}
	select {
	case <-provider.ImmediateChallengeChan():
		t.Fatal("still-approved provider must not be re-challenged out of band")
	default:
	}

	// Deactivate the provider's release: NOW its evidence is genuinely stale.
	if err := st.MemoryStore.DeleteRelease("2.0.0", defaultReleasePlatform); err != nil {
		t.Fatalf("DeleteRelease: %v", err)
	}
	if err := srv.SyncBinaryHashes(); err != nil {
		t.Fatalf("SyncBinaryHashes after deactivation: %v", err)
	}
	if _, ok := provider.ApplicationEvidenceSnapshot(); ok {
		t.Fatal("deactivating the provider's release must clear its evidence")
	}
	if routed := findRoutableProvider(reg, model); routed != nil {
		t.Fatalf("provider with deactivated release remained routable: %s", routed.ID)
	}
	select {
	case <-provider.ImmediateChallengeChan():
	default:
		t.Fatal("invalidated provider must be re-challenged immediately, not on the next tick")
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

// TestReleaseDeactivationReadFailureRetainsPolicyAndSurfacesError: the
// deactivation commits, but the follow-up inventory read fails. The handler
// surfaces 503 (so the admin retries), and the policy stays at the
// last-known-good snapshot — still containing the just-deactivated hash until
// a successful sync converges — rather than swinging the whole fleet through a
// deny-all generation on a transient store hiccup.
func TestReleaseDeactivationReadFailureRetainsPolicyAndSurfacesError(t *testing.T) {
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
	committed := srv.releaseTrustPolicy.Load()

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
	if failed == nil || !failed.Required ||
		failed.Generation != committed.Generation ||
		len(failed.ByBinaryHash[trHashA]) != 1 {
		t.Fatalf("deactivation read failure did not retain last-known-good policy: %+v", failed)
	}

	st.setFailReads(false)
	if err := srv.SyncBinaryHashes(); err != nil {
		t.Fatalf("recovery SyncBinaryHashes: %v", err)
	}
	recovered := srv.releaseTrustPolicy.Load()
	if recovered == nil || !recovered.Required || len(recovered.ByBinaryHash) != 0 {
		t.Fatalf("recovery did not converge onto exact inactive inventory: %+v", recovered)
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
