package api

import (
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// productionShapeRelease mirrors the EXACT active production release rows
// observed in the incident DB (2026-08-31): binary_hash and metallib_hash
// present, python_hash and runtime_hash EMPTY, and template_hashes carrying
// CI-fabricated per-model-family entries (qwen3.5/trinity/gemma4/minimax)
// that no provider build has ever reported.
func productionShapeRelease(version, binaryHash string) *store.Release {
	rel := testRelease(version, binaryHash)
	rel.PythonHash = ""
	rel.RuntimeHash = ""
	rel.TemplateHashes = "qwen3.5=" + strings.Repeat("4", 64) +
		",trinity=" + strings.Repeat("5", 64) +
		",gemma4=" + strings.Repeat("6", 64) +
		",minimax=" + strings.Repeat("7", 64)
	return rel
}

// productionShapeChallenge mirrors the exact v0.8.15 provider attestation
// response wire shape: binary hash present, SIP/Secure Boot true, NO
// python_hash, NO runtime_hash, and template_hashes containing ONLY
// mlx_metallib (the provider's entire template vocabulary).
func productionShapeChallenge(binaryHash string) *protocol.AttestationResponseMessage {
	return &protocol.AttestationResponseMessage{
		BinaryHash: binaryHash,
		SIPEnabled: trBoolPtr(true), SecureBootEnabled: trBoolPtr(true),
		TemplateHashes: map[string]string{"mlx_metallib": trHashC},
	}
}

// TestFamilyTemplateReleaseRowsNeverGateEvidence is THE incident regression
// (2026-08-31 zero-capacity deploys): a release row carrying per-model-family
// template hashes and empty python/runtime hashes, challenged by a provider
// that is hashless at registration and reports only mlx_metallib, MUST derive
// application evidence, survive a policy re-sync, and stay routable under
// ENFORCE. Both failed candidate coordinators died exactly here: every
// provider was rejected for not echoing release-row family template hashes it
// never possessed, application proofs stayed at zero fleet-wide, and every
// request received 429.
func TestFamilyTemplateReleaseRowsNeverGateEvidence(t *testing.T) {
	st := &releaseInventoryFailureStore{MemoryStore: store.NewMemory(store.Config{})}
	if err := st.SetRelease(productionShapeRelease("0.8.15", trHashA)); err != nil {
		t.Fatalf("SetRelease: %v", err)
	}
	logger := quietLogger()
	reg := registry.New(logger)
	reg.SetReleasePolicyEnforcement(true)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	if err := srv.SyncBinaryHashes(); err != nil {
		t.Fatalf("SyncBinaryHashes: %v", err)
	}

	const model = "production-shape-model"
	provider := makeRoutableProvider(t, reg, "production-shape-provider", model)
	// Hashless registration: the fleet's registration attestation carries no
	// binary hash; it arrives only in the signed periodic challenge.
	armReleaseChallengeProvider(t, provider, "0.8.15", "", "se-prod-shape", "SER-PROD-SHAPE")

	resp := productionShapeChallenge(trHashA)
	fact, evidence, ok := srv.deriveApprovedReleaseTransition(provider, resp, true)
	if !ok || !fact.Approved {
		t.Fatal("production-shape provider must derive application evidence despite release-row family template hashes it cannot echo")
	}
	if evidence.BinaryHash != trHashA || evidence.MetallibHash != trHashC {
		t.Fatalf("evidence must bind the challenge binary and metallib hashes, got %+v", evidence)
	}
	if !provider.GrantApplicationEvidenceIfNotUntrusted(evidence) {
		t.Fatal("evidence grant was refused")
	}
	if routed := findRoutableProvider(reg, model); routed == nil || routed.ID != provider.ID {
		t.Fatal("production-shape provider must be routable under enforcement once evidence is held")
	}
	if holding, connected := reg.CountProvidersWithCurrentApplicationEvidence(); holding != 1 || connected != 1 {
		t.Fatalf("evidence coverage = (%d, %d), want (1, 1)", holding, connected)
	}

	// A policy re-sync must carry the evidence forward: the re-proof compares
	// only facts the evidence holds (binary→release binding + metallib), never
	// release-row family templates.
	if err := srv.SyncBinaryHashes(); err != nil {
		t.Fatalf("re-sync: %v", err)
	}
	carried, ok := provider.ApplicationEvidenceSnapshot()
	if !ok || carried.PolicyGeneration != srv.releaseTrustPolicy.Load().Generation {
		t.Fatalf("production-shape evidence must survive the policy sweep, got %+v ok=%v", carried, ok)
	}
	if routed := findRoutableProvider(reg, model); routed == nil || routed.ID != provider.ID {
		t.Fatal("production-shape provider must remain routable across the policy sweep")
	}

	// The gate still fails closed on the facts that ARE provable: a wrong
	// metallib deroutes, and an unregistered binary earns nothing.
	badMetallib := productionShapeChallenge(trHashA)
	badMetallib.TemplateHashes["mlx_metallib"] = strings.Repeat("9", 64)
	if _, _, ok := srv.deriveApprovedReleaseTransition(provider, badMetallib, true); ok {
		t.Fatal("mismatched metallib hash must fail closed")
	}
	if _, _, ok := srv.deriveApprovedReleaseTransition(provider, productionShapeChallenge(trHashB), true); ok {
		t.Fatal("binary hash without an active release row must fail closed")
	}
}

// TestShadowModeRoutesFleetWithoutEvidence pins the deployment-safety contract:
// a freshly booted coordinator (default SHADOW mode) whose connected providers
// hold no application evidence yet — the guaranteed state right after any
// coordinator swap, and permanently the state if a future gate regression
// makes evidence underivable — keeps the fleet routable while the coverage
// counter exposes the gap instead of zeroing capacity.
func TestShadowModeRoutesFleetWithoutEvidence(t *testing.T) {
	st := &releaseInventoryFailureStore{MemoryStore: store.NewMemory(store.Config{})}
	if err := st.SetRelease(productionShapeRelease("0.8.15", trHashA)); err != nil {
		t.Fatalf("SetRelease: %v", err)
	}
	logger := quietLogger()
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	if err := srv.SyncBinaryHashes(); err != nil {
		t.Fatalf("SyncBinaryHashes: %v", err)
	}

	const model = "shadow-mode-model"
	provider := makeRoutableProvider(t, reg, "shadow-mode-provider", model)
	armReleaseChallengeProvider(t, provider, "0.8.15", "", "se-shadow", "SER-SHADOW")

	// No challenge has completed: zero evidence anywhere.
	if holding, connected := reg.CountProvidersWithCurrentApplicationEvidence(); holding != 0 || connected != 1 {
		t.Fatalf("evidence coverage = (%d, %d), want (0, 1)", holding, connected)
	}
	if routed := findRoutableProvider(reg, model); routed == nil || routed.ID != provider.ID {
		t.Fatal("shadow mode must keep an evidence-less provider routable")
	}

	// Flipping enforcement without coverage is exactly the incident: the same
	// provider immediately stops routing.
	reg.SetReleasePolicyEnforcement(true)
	if routed := findRoutableProvider(reg, model); routed != nil {
		t.Fatalf("enforce mode routed an evidence-less provider: %s", routed.ID)
	}
	reg.SetReleasePolicyEnforcement(false)
	if routed := findRoutableProvider(reg, model); routed == nil || routed.ID != provider.ID {
		t.Fatal("returning to shadow mode must restore routing")
	}
}
