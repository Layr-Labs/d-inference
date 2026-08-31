package api

import (
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

// TestTemplateHashRotationInvalidatesCarriedEvidenceAtSweep is the
// review-finding regression for the carry-forward recheck: a policy refresh
// must re-prove EVERY release-specific runtime field the original challenge
// proved, not just binary/version/backend/metallib. Overwriting one release
// row's template hash (binary and backend unchanged) must invalidate that
// provider's carried evidence at the sweep with an immediate re-challenge kick
// — even while ANOTHER active release keeps the old template hash allowlisted
// globally.
func TestTemplateHashRotationInvalidatesCarriedEvidenceAtSweep(t *testing.T) {
	tmplOld := strings.Repeat("1", 64)
	tmplNew := strings.Repeat("2", 64)
	pythonHash := strings.Repeat("3", 64)

	relA := testRelease("2.0.0", trHashA)
	relA.TemplateHashes = "chat_template=" + tmplOld
	relA.PythonHash = pythonHash
	// Release B (different version/binary) keeps the OLD template hash active,
	// so any global-allowlist shortcut would wrongly vouch for the evidence.
	relB := testRelease("2.1.0", trHashB)
	relB.TemplateHashes = "chat_template=" + tmplOld

	st := &releaseInventoryFailureStore{MemoryStore: store.NewMemory(store.Config{})}
	for _, rel := range []*store.Release{relA, relB} {
		if err := st.SetRelease(rel); err != nil {
			t.Fatalf("SetRelease %s: %v", rel.Version, err)
		}
	}
	logger := quietLogger()
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	if err := srv.SyncBinaryHashes(); err != nil {
		t.Fatalf("SyncBinaryHashes: %v", err)
	}

	const model = "template-rotation-model"
	provider := makeRoutableProvider(t, reg, "template-provider", model)
	armReleaseChallengeProvider(t, provider, "2.0.0", trHashA, "se-template", "SER-TEMPLATE")
	// A token is set so this test isolates the carry-forward recheck: it must
	// fail on any code that skips re-proving release-specific runtime fields,
	// independent of the tokenless-evidence fix.
	provider.Mu().Lock()
	provider.APNsDeviceToken = "template-apns-token"
	provider.Mu().Unlock()

	resp := &protocol.AttestationResponseMessage{
		BinaryHash: trHashA,
		SIPEnabled: trBoolPtr(true), SecureBootEnabled: trBoolPtr(true),
		PythonHash: pythonHash,
		TemplateHashes: map[string]string{
			"mlx_metallib":  trHashC,
			"chat_template": tmplOld,
		},
	}
	_, evidence, ok := srv.deriveApprovedReleaseTransition(provider, resp, true)
	if !ok {
		t.Fatal("active release with matching template hashes must derive evidence")
	}
	if evidence.PythonHash != pythonHash || evidence.TemplateHashes["chat_template"] != tmplOld {
		t.Fatalf("evidence must retain the proven runtime facts, got %+v", evidence)
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

	// Rotate ONLY release A's template hash; binary, backend, version,
	// metallib, and python hash all stay equal, and release B still allowlists
	// the old template hash globally.
	relA.TemplateHashes = "chat_template=" + tmplNew
	if err := st.SetRelease(relA); err != nil {
		t.Fatalf("SetRelease rotated: %v", err)
	}
	if err := srv.SyncBinaryHashes(); err != nil {
		t.Fatalf("SyncBinaryHashes after rotation: %v", err)
	}
	if stale, ok := provider.ApplicationEvidenceSnapshot(); ok {
		t.Fatalf("template-hash rotation must invalidate carried evidence, still holds %+v", stale)
	}
	select {
	case <-provider.ImmediateChallengeChan():
	default:
		t.Fatal("invalidated provider must be re-challenged immediately, not on the next tick")
	}
	if routed := findRoutableProvider(reg, model); routed != nil {
		t.Fatalf("provider with rotated template hash remained routable: %s", routed.ID)
	}

	// The re-challenge measuring the NEW template hash re-earns evidence.
	resp.TemplateHashes["chat_template"] = tmplNew
	_, refreshed, ok := srv.deriveApprovedReleaseTransition(provider, resp, true)
	if !ok {
		t.Fatal("re-challenge against the rotated row must derive fresh evidence")
	}
	if !provider.GrantApplicationEvidenceIfNotUntrusted(refreshed) {
		t.Fatal("fresh evidence grant was refused")
	}
	if routed := findRoutableProvider(reg, model); routed == nil || routed.ID != provider.ID {
		t.Fatal("provider did not recover after re-proving the rotated template hash")
	}
}
