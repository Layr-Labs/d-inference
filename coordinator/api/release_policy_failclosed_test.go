package api

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
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

func grantReleaseEvidenceForTest(t *testing.T, provider *registry.Provider, generation uint64, version, binaryHash string) {
	t.Helper()
	provider.Mu().Lock()
	provider.Version = version
	provider.APNsDeviceToken = "apns-token"
	provider.MetallibVerified = true
	provider.AttestationResult = &attestation.VerificationResult{
		Valid: true, PublicKey: "se-release", SerialNumber: "SER-RELEASE",
	}
	provider.Mu().Unlock()
	if !provider.GrantApplicationEvidenceIfNotUntrusted(registry.ApplicationEvidence{
		SEPublicKey: "se-release", Serial: "SER-RELEASE",
		ProcessPublicKey: provider.PublicKey, APNsToken: "apns-token",
		BinaryHash: binaryHash, Version: version, Platform: defaultReleasePlatform,
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
	grantReleaseEvidenceForTest(t, provider, snapshot.Generation, "2.0.0", trHashA)
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
	reg.SetReleasePolicyEnforcement(true)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	if err := srv.SyncBinaryHashes(); err != nil {
		t.Fatalf("initial SyncBinaryHashes: %v", err)
	}
	snapshot := srv.releaseTrustPolicy.Load()

	const model = "release-storm-model"
	provider := makeRoutableProvider(t, reg, "storm-provider", model)
	grantReleaseEvidenceForTest(t, provider, snapshot.Generation, "2.0.0", trHashA)
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

// TestReleaseDeactivationReadFailureConvergesPolicyFromCommittedDeactivation
// is the emergency-pull convergence regression: a force=true delete of a
// compromised release commits, but the post-mutation inventory read fails.
// Retaining the pre-deactivation snapshot and returning 503 would keep the
// compromised release authorized indefinitely — there is no background resync,
// so its providers would keep routing until an admin happened to retry. The
// handler must converge from the committed deactivation itself: the pulled
// release is unauthorized immediately, the connected provider running it is
// invalidated AND kicked for an immediate re-challenge, other releases and
// their still-approved evidence are carried forward, the response surfaces a
// warning, and recovery rebuilds the same set from the exact inventory.
func TestReleaseDeactivationReadFailureConvergesPolicyFromCommittedDeactivation(t *testing.T) {
	st := &releaseInventoryFailureStore{
		MemoryStore:     store.NewMemory(store.Config{}),
		failAfterDelete: true,
	}
	if err := st.SetRelease(testRelease("2.0.0", trHashA)); err != nil {
		t.Fatalf("SetRelease 2.0.0: %v", err)
	}
	if err := st.SetRelease(testRelease("2.1.0", trHashB)); err != nil {
		t.Fatalf("SetRelease 2.1.0: %v", err)
	}
	logger := quietLogger()
	reg := registry.New(logger)
	reg.SetReleasePolicyEnforcement(true)
	srv := NewServer(reg, st, ServerConfig{AdminKey: "admin-key"}, logger)
	if err := srv.SyncBinaryHashes(); err != nil {
		t.Fatalf("initial SyncBinaryHashes: %v", err)
	}
	before := srv.releaseTrustPolicy.Load()

	const compromisedModel = "pulled-release-model"
	const survivorModel = "survivor-release-model"
	compromised := makeRoutableProvider(t, reg, "compromised-provider", compromisedModel)
	grantReleaseEvidenceForTest(t, compromised, before.Generation, "2.0.0", trHashA)
	survivor := makeRoutableProvider(t, reg, "survivor-provider", survivorModel)
	grantReleaseEvidenceForTest(t, survivor, before.Generation, "2.1.0", trHashB)
	for _, p := range []*registry.Provider{compromised, survivor} {
		p.Mu().Lock()
		p.TemplateHashes = map[string]string{"mlx_metallib": trHashC}
		p.Mu().Unlock()
	}
	if routed := findRoutableProvider(reg, compromisedModel); routed == nil || routed.ID != compromised.ID {
		t.Fatalf("compromised-release provider was not routable before the pull: %#v", routed)
	}
	if routed := findRoutableProvider(reg, survivorModel); routed == nil || routed.ID != survivor.ID {
		t.Fatalf("survivor provider was not routable before the pull: %#v", routed)
	}

	// force=true emergency pull; every post-mutation inventory re-read fails.
	response := doReq(srv, http.MethodDelete, "/v1/admin/releases", "Bearer admin-key",
		`{"version":"2.0.0","platform":"macos-arm64","force":true}`)
	if response.Code != http.StatusOK {
		t.Fatalf("deactivation must stay atomic once committed: status=%d body=%s",
			response.Code, response.Body.String())
	}
	var decoded map[string]any
	if err := json.Unmarshal(response.Body.Bytes(), &decoded); err != nil {
		t.Fatalf("decode deactivation response: %v", err)
	}
	if warning, _ := decoded["warning"].(string); warning == "" {
		t.Fatalf("post-mutation sync failure must surface a warning: %v", decoded)
	}
	releases := st.MemoryStore.ListReleases()
	if len(releases) != 2 {
		t.Fatalf("unexpected release inventory after pull: %+v", releases)
	}
	for _, release := range releases {
		if release.Version == "2.0.0" && release.Active {
			t.Fatalf("release deactivation did not commit before read failure: %+v", releases)
		}
	}

	converged := srv.releaseTrustPolicy.Load()
	if converged == nil || !converged.Required || converged.Generation <= before.Generation {
		t.Fatalf("policy did not advance with the committed deactivation: before=%+v after=%+v", before, converged)
	}
	// THE invariant: the compromised release is unauthorized immediately, no
	// admin retry required.
	if len(converged.ByBinaryHash[trHashA]) != 0 {
		t.Fatalf("retained snapshot still authorizes the deactivated release: %+v", converged.ByBinaryHash)
	}
	if len(converged.ByBinaryHash[trHashB]) != 1 {
		t.Fatalf("convergence dropped a release the pull did not touch: %+v", converged.ByBinaryHash)
	}

	// The affected provider is invalidated and kicked immediately.
	if _, ok := compromised.ApplicationEvidenceSnapshot(); ok {
		t.Fatal("pulling the release must clear the affected provider's evidence")
	}
	if routed := findRoutableProvider(reg, compromisedModel); routed != nil {
		t.Fatalf("provider running the pulled release remained routable: %s", routed.ID)
	}
	select {
	case <-compromised.ImmediateChallengeChan():
	default:
		t.Fatal("invalidated provider must be re-challenged immediately, not on the next tick")
	}

	// The untouched fleet is carried forward, not derouted or re-challenged.
	if evidence, ok := survivor.ApplicationEvidenceSnapshot(); !ok || evidence.PolicyGeneration != converged.Generation {
		t.Fatalf("still-approved evidence was not carried forward: %+v ok=%v", evidence, ok)
	}
	if routed := findRoutableProvider(reg, survivorModel); routed == nil || routed.ID != survivor.ID {
		t.Fatal("emergency pull during an inventory outage derouted a healthy, still-approved provider")
	}
	select {
	case <-survivor.ImmediateChallengeChan():
		t.Fatal("still-approved provider must not be re-challenged out of band")
	default:
	}

	// The runtime manifest converged from the retained snapshot: the shared
	// metallib survives via the remaining 2.1.0 release.
	if srv.knownRuntimeManifest == nil || !srv.knownRuntimeManifest.TemplateHashes["mlx_metallib"][trHashC] {
		t.Fatalf("runtime manifest did not converge with the committed deactivation: %+v", srv.knownRuntimeManifest)
	}

	// Recovery rebuilds the identical authorized set from the exact inventory.
	st.setFailReads(false)
	if err := srv.SyncBinaryHashes(); err != nil {
		t.Fatalf("recovery SyncBinaryHashes: %v", err)
	}
	if err := srv.SyncRuntimeManifest(); err != nil {
		t.Fatalf("recovery SyncRuntimeManifest: %v", err)
	}
	recovered := srv.releaseTrustPolicy.Load()
	if recovered == nil || len(recovered.ByBinaryHash[trHashA]) != 0 || len(recovered.ByBinaryHash[trHashB]) != 1 {
		t.Fatalf("recovery did not converge onto the exact inventory: %+v", recovered)
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

// TestRegisterReleaseInventoryFailureConvergesPolicyWithCommittedRelease is the
// register-path convergence regression: SetRelease commits and GET
// /v1/releases/latest immediately distributes the saved release, so a transient
// post-mutation inventory-read failure must NOT strand the trust policy on the
// pre-registration snapshot (providers installing the new release could never
// earn evidence and — with no background resync — would stay unroutable
// indefinitely). The handler must converge the policy from the committed
// mutation itself: registration succeeds atomically, the new release is
// authorized, the previous release set and still-approved connected evidence
// are carried forward, and recovery rebuilds the same set from the exact
// inventory.
func TestRegisterReleaseInventoryFailureConvergesPolicyWithCommittedRelease(t *testing.T) {
	st := &releaseInventoryFailureStore{MemoryStore: store.NewMemory(store.Config{})}
	if err := st.SetRelease(testRelease("2.0.0", trHashA)); err != nil {
		t.Fatalf("SetRelease: %v", err)
	}
	logger := quietLogger()
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.SetReleaseKey("release-key")
	if err := srv.SyncBinaryHashes(); err != nil {
		t.Fatalf("initial SyncBinaryHashes: %v", err)
	}
	before := srv.releaseTrustPolicy.Load()

	const model = "register-converge-model"
	provider := makeRoutableProvider(t, reg, "register-converge-provider", model)
	grantReleaseEvidenceForTest(t, provider, before.Generation, "2.0.0", trHashA)
	provider.Mu().Lock()
	provider.TemplateHashes = map[string]string{"mlx_metallib": trHashC}
	provider.Mu().Unlock()
	if routed := findRoutableProvider(reg, model); routed == nil || routed.ID != provider.ID {
		t.Fatalf("provider was not routable before registration: %#v", routed)
	}

	bundle, binaryHash, bundleHash := buildReleaseBundleForTest(t, []byte("provider-2.1.0"))
	const artifactPath = "/releases/v2.1.0/darkbloom-bundle-macos-arm64.tar.gz"
	cdn := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != artifactPath {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write(bundle)
	}))
	defer cdn.Close()
	srv.SetR2CDNURL(cdn.URL)

	// Inventory reads fail for the whole request: the release write and the
	// artifact download still succeed, but every post-mutation re-read fails.
	st.setFailReads(true)
	body := fmt.Sprintf(
		`{"version":"2.1.0","platform":"macos-arm64","backend":"mlx-swift","binary_hash":%q,"bundle_hash":%q,"metallib_hash":%q,"url":%q,"changelog":"converge"}`,
		binaryHash, bundleHash, trHashC, cdn.URL+artifactPath)
	response := doReq(srv, http.MethodPost, "/v1/releases", "Bearer release-key", body)
	if response.Code != http.StatusOK {
		t.Fatalf("registration must remain atomic once the release committed: status=%d body=%s",
			response.Code, response.Body.String())
	}

	converged := srv.releaseTrustPolicy.Load()
	if converged == nil || !converged.Required || converged.Generation <= before.Generation {
		t.Fatalf("policy did not advance with the committed registration: before=%+v after=%+v", before, converged)
	}
	if entries := converged.ByBinaryHash[binaryHash]; len(entries) != 1 || entries[0].Version != "2.1.0" {
		t.Fatalf("policy does not authorize the committed release: %+v", converged.ByBinaryHash)
	}
	if len(converged.ByBinaryHash[trHashA]) != 1 {
		t.Fatalf("convergence dropped the previous release set: %+v", converged.ByBinaryHash)
	}

	// THE invariant: whatever /v1/releases/latest distributes must be
	// authorized by the live policy snapshot.
	latest := doReq(srv, http.MethodGet, "/v1/releases/latest?platform=macos-arm64", "", "")
	if latest.Code != http.StatusOK {
		t.Fatalf("latest release status = %d body=%s", latest.Code, latest.Body.String())
	}
	var latestRelease store.Release
	if err := json.Unmarshal(latest.Body.Bytes(), &latestRelease); err != nil {
		t.Fatalf("decode latest release: %v", err)
	}
	if latestRelease.Version != "2.1.0" {
		t.Fatalf("latest release = %q, want the committed 2.1.0", latestRelease.Version)
	}
	if len(converged.ByBinaryHash[latestRelease.BinaryHash]) == 0 {
		t.Fatalf("latest serves a release the policy cannot authorize: hash=%s policy=%+v",
			latestRelease.BinaryHash, converged.ByBinaryHash)
	}

	// The runtime manifest converged with the committed release too.
	if srv.knownRuntimeManifest == nil || !srv.knownRuntimeManifest.TemplateHashes["mlx_metallib"][trHashC] {
		t.Fatalf("runtime manifest did not converge with the committed release: %+v", srv.knownRuntimeManifest)
	}

	// Routine registration during the outage must not deroute the approved fleet.
	if evidence, ok := provider.ApplicationEvidenceSnapshot(); !ok || evidence.PolicyGeneration != converged.Generation {
		t.Fatalf("still-approved evidence was not carried forward: %+v ok=%v", evidence, ok)
	}
	if routed := findRoutableProvider(reg, model); routed == nil || routed.ID != provider.ID {
		t.Fatal("routine registration during an inventory outage derouted a healthy, still-approved provider")
	}

	// Recovery rebuilds the identical authorized set from the exact inventory.
	st.setFailReads(false)
	if err := srv.SyncBinaryHashes(); err != nil {
		t.Fatalf("recovery SyncBinaryHashes: %v", err)
	}
	recovered := srv.releaseTrustPolicy.Load()
	if len(recovered.ByBinaryHash[trHashA]) != 1 || len(recovered.ByBinaryHash[binaryHash]) != 1 {
		t.Fatalf("recovery did not converge onto the full inventory: %+v", recovered.ByBinaryHash)
	}
}

// TestAdminDeleteReleaseInUseProtectionHoldsUnderEvidenceGating: the
// application-evidence routing gate requires active releases regardless of the
// legacy binaryHashEnforce flag (default false). A force=false delete of a
// release still backing connected providers must therefore be refused — under
// the old flag-gated precheck it would deactivate the release and the follow-up
// sync would clear the providers' evidence and deroute them. force=true keeps
// its explicit override semantics.
func TestAdminDeleteReleaseInUseProtectionHoldsUnderEvidenceGating(t *testing.T) {
	st := store.NewMemory(store.Config{})
	if err := st.SetRelease(testRelease("2.0.0", trHashA)); err != nil {
		t.Fatalf("SetRelease: %v", err)
	}
	logger := quietLogger()
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{AdminKey: "admin-key"}, logger)
	// Legacy self-reported enforcement stays at its default (false); the
	// evidence gate goes live through the published release policy.
	if err := srv.SyncBinaryHashes(); err != nil {
		t.Fatalf("SyncBinaryHashes: %v", err)
	}
	if snapshot := srv.releaseTrustPolicy.Load(); snapshot == nil || !snapshot.Required {
		t.Fatalf("release policy must be live: %+v", snapshot)
	}

	provider := makeRoutableProvider(t, reg, "delete-inuse-provider", "delete-inuse-model")
	provider.SetAttestationResult(&attestation.VerificationResult{Valid: true, BinaryHash: trHashA})

	response := doReq(srv, http.MethodDelete, "/v1/admin/releases", "Bearer admin-key",
		`{"version":"2.0.0","platform":"macos-arm64"}`)
	if response.Code != http.StatusConflict {
		t.Fatalf("in-use force=false delete = %d, want %d; body=%s",
			response.Code, http.StatusConflict, response.Body.String())
	}
	if releases := st.ListReleases(); len(releases) != 1 || !releases[0].Active {
		t.Fatalf("refused delete must not deactivate the release: %+v", releases)
	}

	forced := doReq(srv, http.MethodDelete, "/v1/admin/releases", "Bearer admin-key",
		`{"version":"2.0.0","platform":"macos-arm64","force":true}`)
	if forced.Code != http.StatusOK {
		t.Fatalf("force=true delete = %d, want %d; body=%s", forced.Code, http.StatusOK, forced.Body.String())
	}
	if latest := st.GetLatestRelease(defaultReleasePlatform); latest != nil {
		t.Fatalf("force=true delete did not deactivate the release: %+v", latest)
	}
}
