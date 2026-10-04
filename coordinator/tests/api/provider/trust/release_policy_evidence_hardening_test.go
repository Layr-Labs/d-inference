package trust_test

import (
	"strings"
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/api/provider/trust"
	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
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

func TestFirstTokenHeartbeatRotatesTokenlessEvidence(t *testing.T) {
	st := memory.NewMemory(store.Config{})
	if err := st.SetRelease(&store.Release{
		Version: "2.0.0", Platform: "macos-arm64", Backend: registry.BackendMLXSwift,
		BinaryHash: trHashA, BundleHash: strings.Repeat("f", 64), MetallibHash: trHashC,
		URL: "https://releases.example/2.0.0.tar.gz",
	}); err != nil {
		t.Fatalf("SetRelease: %v", err)
	}
	logger := quietLogger()
	reg := registry.New(logger)
	reg.SetReleasePolicyEnforcement(true)
	srv := newTrustFixture(t, production.Dependencies{Registry: reg, Store: st, Logger: logger}, production.Config{})
	fastBudgets(srv)
	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, _, _ string) error { return nil }})
	if err := srv.releases.SyncBinaryHashes(); err != nil {
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
	_, evidence, ok := srv.releases.DeriveApprovedReleaseTransition(provider, resp, true)
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
	srv.MaybeRearmCodeAttest(t.Context(), "late-token-provider", provider, &protocol.HeartbeatMessage{
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
	_, refreshed, ok := srv.releases.DeriveApprovedReleaseTransition(provider, resp, true)
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
	srv.MaybeRearmCodeAttest(t.Context(), "late-token-provider", provider, &protocol.HeartbeatMessage{
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
