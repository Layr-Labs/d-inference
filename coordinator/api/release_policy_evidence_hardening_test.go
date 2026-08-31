package api

import (
	"context"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// armReleaseChallengeProvider makes a routable provider satisfy every
// deriveApprovedReleaseTransition input for an active release row: version,
// verified runtime state, and a valid SE attestation binding the given binary
// hash. It deliberately does NOT set an APNs device token.
func armReleaseChallengeProvider(
	t *testing.T, provider *registry.Provider, version, binaryHash, seKey, serial string,
) {
	t.Helper()
	provider.Mu().Lock()
	provider.Version = version
	provider.MetallibVerified = true
	provider.AttestationResult = &attestation.VerificationResult{
		Valid: true, PublicKey: seKey, SerialNumber: serial,
		BinaryHash: binaryHash,
	}
	token := provider.APNsDeviceToken
	provider.Mu().Unlock()
	if token != "" {
		t.Fatalf("precondition: provider unexpectedly holds APNs token %q", token)
	}
}

// TestTokenlessProviderEarnsEvidenceAndStaysRoutable is the review-finding
// regression for the APNs-token floor: application evidence proves the live
// binary/runtime is an active approved release, and must NOT require an APNs
// device token — token possession is enforced exclusively by the separate APNs
// code-identity gate with its existing grace semantics. A tokenless
// (legacy/headless) provider with an active release inventory and a valid
// signed challenge derives evidence, the grant installs it, and the provider
// stays routable pre-enforcement.
func TestTokenlessProviderEarnsEvidenceAndStaysRoutable(t *testing.T) {
	st := &releaseInventoryFailureStore{MemoryStore: store.NewMemory(store.Config{})}
	if err := st.SetRelease(testRelease("2.0.0", trHashA)); err != nil {
		t.Fatalf("SetRelease: %v", err)
	}
	logger := quietLogger()
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	if err := srv.SyncBinaryHashes(); err != nil {
		t.Fatalf("SyncBinaryHashes: %v", err)
	}
	snapshot := srv.releaseTrustPolicy.Load()

	const model = "tokenless-release-model"
	provider := makeRoutableProvider(t, reg, "tokenless-provider", model)
	armReleaseChallengeProvider(t, provider, "2.0.0", trHashA, "se-tokenless", "SER-TOKENLESS")

	resp := &protocol.AttestationResponseMessage{
		BinaryHash: trHashA,
		SIPEnabled: trBoolPtr(true), SecureBootEnabled: trBoolPtr(true),
		TemplateHashes: map[string]string{"mlx_metallib": trHashC},
	}
	fact, evidence, ok := srv.deriveApprovedReleaseTransition(provider, resp, true)
	if !ok || !fact.Approved {
		t.Fatal("tokenless provider with a valid signed challenge against an active release must derive application evidence")
	}
	if evidence.APNsToken != "" {
		t.Fatalf("derived evidence invented an APNs token: %q", evidence.APNsToken)
	}
	if evidence.PolicyGeneration != snapshot.Generation {
		t.Fatalf("evidence generation = %d, want %d", evidence.PolicyGeneration, snapshot.Generation)
	}
	if !provider.GrantApplicationEvidenceIfNotUntrusted(evidence) {
		t.Fatal("tokenless application evidence grant was refused")
	}
	if routed := findRoutableProvider(reg, model); routed == nil || routed.ID != provider.ID {
		t.Fatal("tokenless provider with valid application evidence must stay routable pre-enforcement")
	}
}

// TestHashlessRegistrationEarnsEvidenceFromFreshChallenge is the production
// rollout regression: shipped providers omit binary_hash from their registration
// attestation and report it only in the signed periodic challenge. Application
// evidence must use that fresh approved-release fact while retaining the
// registration cross-check whenever the optional field is present.
func TestHashlessRegistrationEarnsEvidenceFromFreshChallenge(t *testing.T) {
	st := &releaseInventoryFailureStore{MemoryStore: store.NewMemory(store.Config{})}
	if err := st.SetRelease(testRelease("2.0.0", trHashA)); err != nil {
		t.Fatalf("SetRelease: %v", err)
	}
	logger := quietLogger()
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	if err := srv.SyncBinaryHashes(); err != nil {
		t.Fatalf("SyncBinaryHashes: %v", err)
	}

	provider := makeRoutableProvider(t, reg, "hashless-provider", "hashless-release-model")
	armReleaseChallengeProvider(t, provider, "2.0.0", "", "se-hashless", "SER-HASHLESS")
	resp := &protocol.AttestationResponseMessage{
		BinaryHash: trHashA,
		SIPEnabled: trBoolPtr(true), SecureBootEnabled: trBoolPtr(true),
		TemplateHashes: map[string]string{"mlx_metallib": trHashC},
	}
	fact, evidence, ok := srv.deriveApprovedReleaseTransition(provider, resp, true)
	if !ok || !fact.Approved {
		t.Fatal("hashless registration did not derive evidence from the fresh signed challenge")
	}
	if evidence.BinaryHash != trHashA || evidence.SEPublicKey != "se-hashless" {
		t.Fatalf("derived evidence lost challenge/SE binding: %+v", evidence)
	}
	if !provider.GrantApplicationEvidenceIfNotUntrusted(evidence) {
		t.Fatal("hashless provider application evidence grant was refused")
	}
	if routed := findRoutableProvider(reg, "hashless-release-model"); routed == nil || routed.ID != provider.ID {
		t.Fatal("hashless provider remained unroutable after fresh approved challenge")
	}
	provider.Mu().Lock()
	provider.AttestationResult.BinaryHash = trHashB
	provider.Mu().Unlock()
	if _, _, ok := srv.deriveApprovedReleaseTransition(provider, resp, true); ok {
		t.Fatal("present registration/challenge binary hash mismatch did not fail closed")
	}
}

// TestMetallibRotationInvalidatesCarriedEvidenceAtSweep is the carry-forward
// recheck regression: a policy refresh must re-prove the release-specific
// facts application evidence actually holds — the binary→active-release
// binding and the metallib hash. Overwriting one release row's metallib hash
// (binary, backend, and version unchanged) must invalidate that provider's
// carried evidence at the sweep with an immediate re-challenge kick — even
// while ANOTHER active release keeps the old metallib hash allowlisted
// globally. Per-model-family template hashes are deliberately NOT part of
// this contract (TestFamilyTemplateReleaseRowsNeverGateEvidence).
func TestMetallibRotationInvalidatesCarriedEvidenceAtSweep(t *testing.T) {
	metallibOld := trHashC
	metallibNew := strings.Repeat("2", 64)

	relA := testRelease("2.0.0", trHashA)
	// Release B (different version/binary) keeps the OLD metallib hash active,
	// so any global-allowlist shortcut would wrongly vouch for the evidence.
	relB := testRelease("2.1.0", trHashB)

	st := &releaseInventoryFailureStore{MemoryStore: store.NewMemory(store.Config{})}
	for _, rel := range []*store.Release{relA, relB} {
		if err := st.SetRelease(rel); err != nil {
			t.Fatalf("SetRelease %s: %v", rel.Version, err)
		}
	}
	logger := quietLogger()
	reg := registry.New(logger)
	reg.SetReleasePolicyEnforcement(true)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	if err := srv.SyncBinaryHashes(); err != nil {
		t.Fatalf("SyncBinaryHashes: %v", err)
	}

	const model = "metallib-rotation-model"
	provider := makeRoutableProvider(t, reg, "metallib-provider", model)
	armReleaseChallengeProvider(t, provider, "2.0.0", trHashA, "se-metallib", "SER-METALLIB")
	// A token is set so this test isolates the carry-forward recheck
	// independent of the tokenless-evidence fix.
	provider.Mu().Lock()
	provider.APNsDeviceToken = "metallib-apns-token"
	provider.Mu().Unlock()

	resp := &protocol.AttestationResponseMessage{
		BinaryHash: trHashA,
		SIPEnabled: trBoolPtr(true), SecureBootEnabled: trBoolPtr(true),
		TemplateHashes: map[string]string{"mlx_metallib": metallibOld},
	}
	_, evidence, ok := srv.deriveApprovedReleaseTransition(provider, resp, true)
	if !ok {
		t.Fatal("active release with matching metallib must derive evidence")
	}
	if evidence.MetallibHash != metallibOld {
		t.Fatalf("evidence must retain the proven metallib hash, got %+v", evidence)
	}
	if !provider.GrantApplicationEvidenceIfNotUntrusted(evidence) {
		t.Fatal("evidence grant was refused")
	}
	if routed := findRoutableProvider(reg, model); routed == nil || routed.ID != provider.ID {
		t.Fatal("provider was not routable after the initial grant")
	}

	// Control: a no-op re-sync carries the evidence forward (every retained
	// fact still matches its release row) with no re-challenge.
	if err := srv.SyncBinaryHashes(); err != nil {
		t.Fatalf("no-op SyncBinaryHashes: %v", err)
	}
	carried, ok := provider.ApplicationEvidenceSnapshot()
	if !ok || carried.PolicyGeneration != srv.releaseTrustPolicy.Load().Generation {
		t.Fatalf("unchanged inventory must carry evidence forward, got %+v ok=%v", carried, ok)
	}
	select {
	case <-provider.ImmediateChallengeChan():
		t.Fatal("no-op re-sync must not re-challenge a still-approved provider")
	default:
	}

	// Rotate ONLY release A's metallib hash; binary, backend, and version all
	// stay equal, and release B still allowlists the old metallib globally.
	relA.MetallibHash = metallibNew
	if err := st.SetRelease(relA); err != nil {
		t.Fatalf("SetRelease rotated: %v", err)
	}
	if err := srv.SyncBinaryHashes(); err != nil {
		t.Fatalf("SyncBinaryHashes after rotation: %v", err)
	}
	if stale, ok := provider.ApplicationEvidenceSnapshot(); ok {
		t.Fatalf("metallib rotation must invalidate carried evidence, still holds %+v", stale)
	}
	select {
	case <-provider.ImmediateChallengeChan():
	default:
		t.Fatal("invalidated provider must be re-challenged immediately, not on the next tick")
	}
	if routed := findRoutableProvider(reg, model); routed != nil {
		t.Fatalf("provider with rotated metallib hash remained routable under enforcement: %s", routed.ID)
	}

	// The re-challenge measuring the NEW metallib hash re-earns evidence.
	resp.TemplateHashes["mlx_metallib"] = metallibNew
	_, refreshed, ok := srv.deriveApprovedReleaseTransition(provider, resp, true)
	if !ok {
		t.Fatal("re-challenge against the rotated row must derive fresh evidence")
	}
	if !provider.GrantApplicationEvidenceIfNotUntrusted(refreshed) {
		t.Fatal("fresh evidence grant was refused")
	}
	if routed := findRoutableProvider(reg, model); routed == nil || routed.ID != provider.ID {
		t.Fatal("provider did not recover after re-proving the rotated metallib hash")
	}
}

// TestFirstTokenHeartbeatRotatesTokenlessEvidence is the Codex 07:12Z P1
// regression for the empty→non-empty APNs token transition: a provider that
// registered token-less earns application evidence with an empty APNsToken;
// when the first real token arrives in a heartbeat, that evidence is stale
// (routing gate: evidence.APNsToken != APNsDeviceToken) yet the old rearm path
// treated a first token as changed==false — evidence retained, no immediate
// challenge — leaving the provider unroutable until the 5-minute ticker while
// queued requests expire at 120s. The first token must be a rotation for the
// EVIDENCE lifecycle: clear the stale evidence and kick the ordinary challenge
// loop so regenerated, token-bound evidence restores routability immediately.
func TestFirstTokenHeartbeatRotatesTokenlessEvidence(t *testing.T) {
	st := &releaseInventoryFailureStore{MemoryStore: store.NewMemory(store.Config{})}
	if err := st.SetRelease(testRelease("2.0.0", trHashA)); err != nil {
		t.Fatalf("SetRelease: %v", err)
	}
	logger := quietLogger()
	reg := registry.New(logger)
	reg.SetReleasePolicyEnforcement(true)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	fastBudgets(srv)
	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, _, _ string) error { return nil }})
	if err := srv.SyncBinaryHashes(); err != nil {
		t.Fatalf("SyncBinaryHashes: %v", err)
	}

	const model = "late-token-release-model"
	provider := makeRoutableProvider(t, reg, "late-token-provider", model)
	armReleaseChallengeProvider(t, provider, "2.0.0", trHashA, "se-late-token", "SER-LATE")

	resp := &protocol.AttestationResponseMessage{
		BinaryHash: trHashA,
		SIPEnabled: trBoolPtr(true), SecureBootEnabled: trBoolPtr(true),
		TemplateHashes: map[string]string{"mlx_metallib": trHashC},
	}
	_, evidence, ok := srv.deriveApprovedReleaseTransition(provider, resp, true)
	if !ok || evidence.APNsToken != "" {
		t.Fatalf("precondition: tokenless evidence derivation failed (ok=%v token=%q)", ok, evidence.APNsToken)
	}
	if !provider.GrantApplicationEvidenceIfNotUntrusted(evidence) {
		t.Fatal("precondition: tokenless evidence grant was refused")
	}
	if routed := findRoutableProvider(reg, model); routed == nil || routed.ID != provider.ID {
		t.Fatal("precondition: tokenless provider with evidence must be routable")
	}

	// First non-empty token heartbeat: the empty-token evidence is stranded the
	// instant the token is installed — it must be cleared and the ordinary
	// challenge loop kicked NOW, not on the next periodic tick.
	srv.maybeRearmCodeAttest(context.Background(), "late-token-provider", provider, &protocol.HeartbeatMessage{
		Type: protocol.TypeHeartbeat, Status: "idle",
		APNsDeviceToken: "late-apns-token",
	})
	if got := func() string {
		provider.Mu().Lock()
		defer provider.Mu().Unlock()
		return provider.APNsDeviceToken
	}(); got != "late-apns-token" {
		t.Fatalf("heartbeat token not recorded: %q", got)
	}
	if stale, ok := provider.ApplicationEvidenceSnapshot(); ok {
		t.Fatalf("first token must clear token-less evidence, still holds %+v", stale)
	}
	select {
	case <-provider.ImmediateChallengeChan():
	default:
		t.Fatal("first token stranding token-less evidence must kick an immediate ordinary challenge")
	}
	if routed := findRoutableProvider(reg, model); routed != nil {
		t.Fatalf("provider must be unroutable until evidence is re-proven, routed %s", routed.ID)
	}

	// The kicked challenge re-measures the same release; the regenerated
	// evidence binds the installed token, restoring routability with no ticker.
	_, refreshed, ok := srv.deriveApprovedReleaseTransition(provider, resp, true)
	if !ok {
		t.Fatal("re-challenge after the first token must derive fresh evidence")
	}
	if refreshed.APNsToken != "late-apns-token" {
		t.Fatalf("regenerated evidence must carry the installed token, got %q", refreshed.APNsToken)
	}
	if !provider.GrantApplicationEvidenceIfNotUntrusted(refreshed) {
		t.Fatal("regenerated evidence grant was refused")
	}
	if routed := findRoutableProvider(reg, model); routed == nil || routed.ID != provider.ID {
		t.Fatal("provider did not recover after re-proving token-bound evidence")
	}

	// Steady state: an unchanged-token heartbeat is still a no-op — evidence
	// retained, no kick, still routable.
	srv.maybeRearmCodeAttest(context.Background(), "late-token-provider", provider, &protocol.HeartbeatMessage{
		Type: protocol.TypeHeartbeat, Status: "idle",
		APNsDeviceToken: "late-apns-token",
	})
	if _, ok := provider.ApplicationEvidenceSnapshot(); !ok {
		t.Fatal("unchanged token must not clear evidence")
	}
	select {
	case <-provider.ImmediateChallengeChan():
		t.Fatal("unchanged token must not kick the ordinary challenge loop")
	default:
	}
	if routed := findRoutableProvider(reg, model); routed == nil || routed.ID != provider.ID {
		t.Fatal("unchanged-token heartbeat must leave the provider routable")
	}
}
