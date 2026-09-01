package api

import (
	"log/slog"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func runtimeManifestTestServer(t *testing.T) (*Server, *store.MemoryStore) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	return srv, st
}

func TestSyncRuntimeManifestIncludesSwiftMetallibHash(t *testing.T) {
	srv, st := runtimeManifestTestServer(t)
	metallibHash := strings.Repeat("a", 64)

	if err := st.SetRelease(&store.Release{
		Version:      "0.5.0",
		Platform:     "macos-arm64",
		Backend:      "mlx-swift",
		BinaryHash:   strings.Repeat("b", 64),
		BundleHash:   strings.Repeat("c", 64),
		MetallibHash: metallibHash,
		URL:          "https://example.com/swift.tar.gz",
		Active:       true,
	}); err != nil {
		t.Fatalf("SetRelease(swift): %v", err)
	}

	srv.SyncRuntimeManifest()

	if srv.knownRuntimeManifest == nil {
		t.Fatal("knownRuntimeManifest = nil")
	}
	if got := srv.knownRuntimeManifest.TemplateHashes["mlx_metallib"]; got != metallibHash {
		t.Fatalf("mlx_metallib hash = %q, want %q", got, metallibHash)
	}
}

func TestVerifyRuntimeHashesForSwiftRequiresMetallibButNotLegacyRuntime(t *testing.T) {
	srv, _ := runtimeManifestTestServer(t)
	metallibHash := strings.Repeat("a", 64)
	srv.SetRuntimeManifest(&RuntimeManifest{
		PythonHashes:   map[string]bool{"legacy-python": true},
		RuntimeHashes:  map[string]bool{"legacy-runtime": true},
		TemplateHashes: map[string]string{"qwen3.5": "legacy-template", "mlx_metallib": metallibHash},
	})

	ok, mismatches := srv.verifyRuntimeHashesForBackend("mlx-swift", "", "", map[string]string{
		"mlx_metallib": metallibHash,
	})
	if !ok {
		t.Fatalf("swift runtime verification failed with matching metallib: %#v", mismatches)
	}

	ok, mismatches = srv.verifyRuntimeHashesForBackend("mlx-swift", "", "", map[string]string{
		"mlx_metallib": strings.Repeat("b", 64),
	})
	if ok {
		t.Fatal("swift runtime verification should fail on metallib mismatch")
	}
	if len(mismatches) != 1 || mismatches[0].Component != "template:mlx_metallib" {
		t.Fatalf("mismatches = %#v, want one mlx_metallib mismatch", mismatches)
	}
}

func TestRuntimeManifestApprovalRequiresExplicitMetallibEntry(t *testing.T) {
	hash := strings.Repeat("a", 64)
	if runtimeManifestApprovesMetallib(
		&RuntimeManifest{TemplateHashes: map[string]string{}},
		map[string]string{"mlx_metallib": hash},
	) {
		t.Fatal("missing approved mlx_metallib entry was accepted")
	}
	if !runtimeManifestApprovesMetallib(
		&RuntimeManifest{TemplateHashes: map[string]string{"mlx_metallib": hash}},
		map[string]string{"mlx_metallib": hash},
	) {
		t.Fatal("explicit matching mlx_metallib entry was rejected")
	}
}

func TestVerifyRuntimeHashesForLegacyBackendRejected(t *testing.T) {
	srv, _ := runtimeManifestTestServer(t)
	srv.SetRuntimeManifest(&RuntimeManifest{
		PythonHashes:   map[string]bool{"legacy-python": true},
		RuntimeHashes:  map[string]bool{"legacy-runtime": true},
		TemplateHashes: map[string]string{"qwen3.5": "legacy-template", "mlx_metallib": strings.Repeat("a", 64)},
	})

	ok, mismatches := srv.verifyRuntimeHashesForBackend("vllm-mlx", "legacy-python", "legacy-runtime", map[string]string{
		"qwen3.5": "legacy-template",
	})
	if ok {
		t.Fatal("legacy (vllm-mlx) backend should be rejected — only mlx-swift is supported")
	}
	if len(mismatches) != 1 || mismatches[0].Component != "backend" {
		t.Fatalf("mismatches = %#v, want one backend mismatch", mismatches)
	}
}

func TestSyncRuntimeManifestUsesLatestReleaseOnly(t *testing.T) {
	srv, st := runtimeManifestTestServer(t)

	if err := st.SetRelease(&store.Release{
		Version:        "0.3.8",
		Platform:       "macos-arm64",
		BinaryHash:     "old-binary",
		BundleHash:     "old-bundle",
		PythonHash:     "old-python",
		RuntimeHash:    "old-runtime",
		TemplateHashes: "qwen3.5=old-template",
		URL:            "https://example.com/old.tar.gz",
		Active:         true,
	}); err != nil {
		t.Fatalf("SetRelease(old): %v", err)
	}

	if err := st.SetRelease(&store.Release{
		Version:        "0.3.9",
		Platform:       "macos-arm64",
		BinaryHash:     "new-binary",
		BundleHash:     "new-bundle",
		PythonHash:     "new-python",
		RuntimeHash:    "new-runtime",
		TemplateHashes: "qwen3.5=new-template,minimax=new-minimax-template",
		URL:            "https://example.com/new.tar.gz",
		Active:         true,
	}); err != nil {
		t.Fatalf("SetRelease(new): %v", err)
	}

	srv.SyncRuntimeManifest()

	if srv.minProviderVersion != "" {
		t.Fatalf("minProviderVersion should not be auto-set, got %q", srv.minProviderVersion)
	}
	if srv.knownRuntimeManifest == nil {
		t.Fatal("knownRuntimeManifest = nil")
	}

	manifest := srv.knownRuntimeManifest
	if !manifest.PythonHashes["new-python"] {
		t.Fatal("latest python hash missing from runtime manifest")
	}
	if !manifest.PythonHashes["old-python"] {
		t.Fatal("old python hash should remain accepted so older providers still pass")
	}
	if !manifest.RuntimeHashes["new-runtime"] {
		t.Fatal("latest runtime hash missing from runtime manifest")
	}
	if !manifest.RuntimeHashes["old-runtime"] {
		t.Fatal("old runtime hash should remain accepted so older providers still pass")
	}
	if got := manifest.TemplateHashes["qwen3.5"]; got != "new-template" {
		t.Fatalf("qwen3.5 template hash = %q, want %q", got, "new-template")
	}
	if got := manifest.TemplateHashes["minimax"]; got != "new-minimax-template" {
		t.Fatalf("minimax template hash = %q, want %q", got, "new-minimax-template")
	}
}

func TestSyncRuntimeManifestClearsStaleHashesWhenLatestReleaseHasNoRuntimeMetadata(t *testing.T) {
	srv, st := runtimeManifestTestServer(t)

	if err := st.SetRelease(&store.Release{
		Version:        "0.3.8",
		Platform:       "macos-arm64",
		BinaryHash:     "old-binary",
		BundleHash:     "old-bundle",
		PythonHash:     "old-python",
		RuntimeHash:    "old-runtime",
		TemplateHashes: "qwen3.5=old-template",
		URL:            "https://example.com/old.tar.gz",
		Active:         true,
	}); err != nil {
		t.Fatalf("SetRelease(old): %v", err)
	}

	srv.SyncRuntimeManifest()
	if srv.knownRuntimeManifest == nil {
		t.Fatal("expected initial runtime manifest")
	}

	if err := st.SetRelease(&store.Release{
		Version:    "0.3.9",
		Platform:   "macos-arm64",
		BinaryHash: "new-binary",
		BundleHash: "new-bundle",
		URL:        "https://example.com/new.tar.gz",
		Active:     true,
	}); err != nil {
		t.Fatalf("SetRelease(new): %v", err)
	}

	srv.SyncRuntimeManifest()

	if srv.minProviderVersion != "" {
		t.Fatalf("minProviderVersion should not be auto-set, got %q", srv.minProviderVersion)
	}
	// With multi-version manifest, old release hashes are retained so older
	// providers still pass — manifest is NOT cleared just because a new
	// release lacks metadata.
	if srv.knownRuntimeManifest == nil {
		t.Fatal("manifest should retain old release hashes")
	}
	if !srv.knownRuntimeManifest.PythonHashes["old-python"] {
		t.Fatal("old python hash should still be accepted")
	}
}

func TestSyncRuntimeManifestDeroutesLiveProvidersBelowMinVersion(t *testing.T) {
	srv, st := runtimeManifestTestServer(t)

	provider := srv.registry.Register("provider-1", nil, &protocol.RegisterMessage{
		Type: protocol.TypeRegister,
		Hardware: protocol.Hardware{
			ChipName: "Apple M3 Max",
			MemoryGB: 64,
		},
		Models:                  []protocol.ModelInfo{{ID: "live-version-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 "mlx-swift",
		PublicKey:               "bound-public-key",
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
	})
	provider.Mu().Lock()
	provider.TrustLevel = registry.TrustHardware
	provider.Version = "0.3.8"
	provider.RuntimeVerified = true
	provider.RuntimeManifestChecked = true
	provider.ChallengeVerifiedSIP = true
	provider.LastChallengeVerified = time.Now()
	provider.Mu().Unlock()

	if err := st.SetRelease(&store.Release{
		Version:      "0.3.9",
		Platform:     "macos-arm64",
		BinaryHash:   "new-binary",
		BundleHash:   "new-bundle",
		MetallibHash: strings.Repeat("a", 64),
		URL:          "https://example.com/new.tar.gz",
		Active:       true,
	}); err != nil {
		t.Fatalf("SetRelease(new): %v", err)
	}

	// Version gate: providers below this version are derouted regardless of
	// hash verification. The manifest must be non-nil for revalidation to run.
	srv.SetMinProviderVersion("0.3.9")
	srv.SyncRuntimeManifest()

	provider = srv.registry.GetProvider("provider-1")
	provider.Mu().Lock()
	if provider.RuntimeVerified {
		provider.Mu().Unlock()
		t.Fatal("live provider below the minimum version should be derouted immediately")
	}
	if provider.RuntimeManifestChecked {
		provider.Mu().Unlock()
		t.Fatal("live provider below the minimum version should lose private-text eligibility")
	}
	provider.Mu().Unlock()
	if models := srv.registry.ListModels(); len(models) != 0 {
		t.Fatalf("models = %d, want 0 after live version cutoff", len(models))
	}
}

func TestSyncRuntimeManifestDeroutesLiveProvidersWhenManifestClears(t *testing.T) {
	srv, st := runtimeManifestTestServer(t)

	provider := srv.registry.Register("provider-1", nil, &protocol.RegisterMessage{
		Type: protocol.TypeRegister,
		Hardware: protocol.Hardware{
			ChipName: "Apple M3 Max",
			MemoryGB: 64,
		},
		Models:                  []protocol.ModelInfo{{ID: "live-manifest-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 "mlx-swift",
		PublicKey:               "bound-public-key",
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
	})
	provider.Mu().Lock()
	provider.TrustLevel = registry.TrustHardware
	provider.Version = "0.3.9"
	provider.RuntimeVerified = true
	provider.RuntimeManifestChecked = true
	provider.ChallengeVerifiedSIP = true
	provider.LastChallengeVerified = time.Now()
	provider.Mu().Unlock()

	if err := st.SetRelease(&store.Release{
		Version:    "0.3.9",
		Platform:   "macos-arm64",
		BinaryHash: "new-binary",
		BundleHash: "new-bundle",
		URL:        "https://example.com/new.tar.gz",
		Active:     true,
	}); err != nil {
		t.Fatalf("SetRelease(new): %v", err)
	}

	srv.SyncRuntimeManifest()

	provider = srv.registry.GetProvider("provider-1")
	provider.Mu().Lock()
	if provider.RuntimeVerified {
		provider.Mu().Unlock()
		t.Fatal("live provider should be derouted when the runtime manifest is withdrawn")
	}
	if provider.RuntimeManifestChecked {
		provider.Mu().Unlock()
		t.Fatal("live provider should lose private-text eligibility when the runtime manifest is withdrawn")
	}
	provider.Mu().Unlock()
	if models := srv.registry.ListModels(); len(models) != 0 {
		t.Fatalf("models = %d, want 0 after manifest withdrawal", len(models))
	}
}

func TestSyncRuntimeManifestDeroutesLiveProvidersWhenHashesChangeWithoutVersionBump(t *testing.T) {
	srv, st := runtimeManifestTestServer(t)
	oldMetallib := strings.Repeat("a", 64)
	newMetallib := strings.Repeat("b", 64)

	provider := srv.registry.Register("provider-1", nil, &protocol.RegisterMessage{
		Type: protocol.TypeRegister,
		Hardware: protocol.Hardware{
			ChipName: "Apple M3 Max",
			MemoryGB: 64,
		},
		Models:                  []protocol.ModelInfo{{ID: "same-version-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 "mlx-swift",
		PublicKey:               "bound-public-key",
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
	})
	provider.Mu().Lock()
	provider.TrustLevel = registry.TrustHardware
	provider.Version = "0.3.9"
	provider.RuntimeVerified = true
	provider.RuntimeManifestChecked = true
	provider.ChallengeVerifiedSIP = true
	provider.LastChallengeVerified = time.Now()
	provider.TemplateHashes = map[string]string{"mlx_metallib": oldMetallib}
	provider.Mu().Unlock()

	if err := st.SetRelease(&store.Release{
		Version:      "0.3.9",
		Platform:     "macos-arm64",
		BinaryHash:   "new-binary",
		BundleHash:   "new-bundle",
		MetallibHash: newMetallib,
		URL:          "https://example.com/new.tar.gz",
		Active:       true,
	}); err != nil {
		t.Fatalf("SetRelease(new): %v", err)
	}

	srv.SyncRuntimeManifest()

	provider = srv.registry.GetProvider("provider-1")
	provider.Mu().Lock()
	if provider.RuntimeVerified {
		provider.Mu().Unlock()
		t.Fatal("live provider should be derouted when same-version metallib hash changes")
	}
	if provider.RuntimeManifestChecked {
		provider.Mu().Unlock()
		t.Fatal("live provider should lose private-text eligibility when same-version metallib hash changes")
	}
	provider.Mu().Unlock()
	if models := srv.registry.ListModels(); len(models) != 0 {
		t.Fatalf("models = %d, want 0 after same-version runtime hash revocation", len(models))
	}
}

// A manifest update changes coordinator policy, not the identity of an already
// connected process. Its process-bound code proof must survive demotion so a
// rollback can restore protected capabilities without forcing a reconnect.
func TestSyncRuntimeManifestPreservesFreshProcessProofAcrossMismatchAndRecovery(t *testing.T) {
	srv, st := runtimeManifestTestServer(t)
	oldMetallib := strings.Repeat("a", 64)
	newMetallib := strings.Repeat("b", 64)
	const providerVersion = "0.8.15"
	capabilities := []string{
		registry.ProviderCapabilityAppleM5,
		registry.ProviderCapabilityMLXNAX,
	}
	srv.registry.SetModelAliases(map[string]registry.AliasTarget{
		"protected": {Desired: registry.Qwen38NAXModelID},
	})

	provider := srv.registry.Register("provider-1", nil, &protocol.RegisterMessage{
		Type: protocol.TypeRegister,
		Hardware: protocol.Hardware{
			ChipFamily: "M5",
			ChipName:   "Apple M5 Max",
			MemoryGB:   64,
		},
		Models: []protocol.ModelInfo{{
			ID: registry.Qwen38NAXModelID, ModelType: "chat", Quantization: "4bit",
		}},
		Backend:                 registry.BackendMLXSwift,
		Version:                 providerVersion,
		PublicKey:               testPublicKeyB64(),
		RuntimeCapabilities:     capabilities,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
	})
	provider.SetAttestationResult(&attestation.VerificationResult{
		Valid:                  true,
		ChipFamily:             "M5",
		ChipName:               "Apple M5 Max",
		MetallibHash:           oldMetallib,
		RuntimeCapabilities:    capabilities,
		SecureEnclaveAvailable: true,
		SIPEnabled:             true,
		SecureBootEnabled:      true,
	})
	provider.Mu().Lock()
	provider.TrustLevel = registry.TrustHardware
	provider.Attested = true
	provider.CodeAttested = true
	provider.FreshCodeAttested = true
	provider.Version = providerVersion
	provider.TemplateHashes = map[string]string{"mlx_metallib": oldMetallib}
	provider.ChallengeVerifiedSIP = true
	provider.LastChallengeVerified = time.Now()
	provider.Mu().Unlock()

	setManifest := func(hash string) {
		t.Helper()
		if err := st.SetRelease(&store.Release{
			Version:      "0.8.17",
			Platform:     "macos-arm64",
			MetallibHash: hash,
		}); err != nil {
			t.Fatalf("SetRelease(%s): %v", hash, err)
		}
		srv.SyncRuntimeManifest()
	}
	withdrawManifest := func() {
		t.Helper()
		if err := st.SetRelease(&store.Release{
			Version:  "0.8.17",
			Platform: "macos-arm64",
		}); err != nil {
			t.Fatalf("SetRelease(withdrawal): %v", err)
		}
		srv.SyncRuntimeManifest()
	}
	assertState := func(wantApproved bool) {
		t.Helper()
		provider.Mu().Lock()
		fresh := provider.FreshCodeAttested
		runtimeVerified := provider.RuntimeVerified
		manifestChecked := provider.RuntimeManifestChecked
		metallibVerified := provider.MetallibVerified
		trustLevel := provider.TrustLevel
		effective := append([]string(nil), provider.RuntimeCapabilities...)
		provider.Mu().Unlock()

		if !fresh {
			t.Fatal("manifest policy revalidation cleared the live process proof")
		}
		if trustLevel != registry.TrustHardware {
			t.Fatalf("manifest policy revalidation changed hardware trust to %q", trustLevel)
		}
		if runtimeVerified != wantApproved ||
			manifestChecked != wantApproved ||
			metallibVerified != wantApproved {
			t.Fatalf("runtime policy state = verified:%v checked:%v metallib:%v, want %v",
				runtimeVerified, manifestChecked, metallibVerified, wantApproved)
		}

		desired := srv.registry.DesiredModelsForProvider(provider.ID)
		if wantApproved {
			if !reflect.DeepEqual(effective, capabilities) {
				t.Fatalf("effective capabilities = %v, want %v", effective, capabilities)
			}
			if len(desired) != 1 ||
				desired[0].DesiredBuild != registry.Qwen38NAXModelID {
				t.Fatalf("promoted desired state = %+v, want protected build", desired)
			}
			if models := srv.registry.ListModels(); len(models) != 1 {
				t.Fatalf("routable models = %d, want 1 after approval", len(models))
			}
			return
		}
		if len(effective) != 0 {
			t.Fatalf("mismatched manifest left effective capabilities %v", effective)
		}
		if len(desired) != 0 {
			t.Fatalf("demoted desired state = %+v, want empty", desired)
		}
		if models := srv.registry.ListModels(); len(models) != 0 {
			t.Fatalf("routable models = %d, want 0 after manifest mismatch", len(models))
		}
	}

	setManifest(oldMetallib)
	assertState(true)
	setManifest(newMetallib)
	assertState(false)
	runtimePolicyActive, runtimeOK, _ := srv.applyChallengeRuntimePolicy(
		provider,
		&protocol.AttestationResponseMessage{
			TemplateHashes: map[string]string{"mlx_metallib": oldMetallib},
		},
	)
	if !runtimePolicyActive {
		t.Fatal("rotated runtime manifest was not applied")
	}
	if runtimeOK {
		t.Fatal("unchanged runtime unexpectedly passed the rotated manifest")
	}
	if err := srv.registry.ReconcileAttestedRuntimeCapabilities(provider.ID); err != nil {
		t.Fatalf("reconcile policy-only challenge mismatch: %v", err)
	}
	assertState(false)
	setManifest(oldMetallib)
	assertState(true)

	t.Run("temporary minimum version policy recovers without reconnect", func(t *testing.T) {
		srv.minProviderVersion = "9.9.9"
		version, allowed := srv.applyChallengeMinVersionPolicy(provider)
		if allowed {
			t.Fatalf("provider version %q unexpectedly passed temporary floor", version)
		}
		if err := srv.registry.ReconcileAttestedRuntimeCapabilities(provider.ID); err != nil {
			t.Fatalf("reconcile temporary version rejection: %v", err)
		}
		assertState(false)

		srv.minProviderVersion = ""
		srv.revalidateConnectedProvidersAgainstRuntimePolicy()
		assertState(true)
		provider.Mu().Lock()
		version = provider.Version
		provider.Mu().Unlock()
		if version != providerVersion {
			t.Fatalf("policy rollback changed provider version to %q, want %q",
				version, providerVersion)
		}
	})

	t.Run("withdrawal tracks identity before policy restore", func(t *testing.T) {
		withdrawManifest()
		assertState(false)
		runtimePolicyActive, runtimeOK, _ := srv.applyChallengeRuntimePolicy(
			provider,
			&protocol.AttestationResponseMessage{
				TemplateHashes: map[string]string{"mlx_metallib": oldMetallib},
			},
		)
		if runtimePolicyActive || runtimeOK {
			t.Fatalf("withdrawn policy reported active=%v runtimeOK=%v",
				runtimePolicyActive, runtimeOK)
		}
		if err := srv.registry.ReconcileAttestedRuntimeCapabilities(provider.ID); err != nil {
			t.Fatalf("reconcile unchanged identity during withdrawal: %v", err)
		}
		assertState(false)
		setManifest(oldMetallib)
		assertState(true)

		withdrawManifest()
		assertState(false)
		runtimePolicyActive, runtimeOK, _ = srv.applyChallengeRuntimePolicy(
			provider,
			&protocol.AttestationResponseMessage{},
		)
		if runtimePolicyActive || runtimeOK {
			t.Fatalf("withdrawn policy with omitted identity reported active=%v runtimeOK=%v",
				runtimePolicyActive, runtimeOK)
		}
		if err := srv.registry.ReconcileAttestedRuntimeCapabilities(provider.ID); err == nil {
			t.Fatal("omitted identity during withdrawal still matched signed claims")
		}
		setManifest(oldMetallib)
		provider.Mu().Lock()
		fresh := provider.FreshCodeAttested
		runtimeVerified := provider.RuntimeVerified
		effective := append([]string(nil), provider.RuntimeCapabilities...)
		storedTemplates := registry.CloneStringMap(provider.TemplateHashes)
		provider.Mu().Unlock()
		if fresh || runtimeVerified || len(effective) != 0 {
			t.Fatalf("restore re-promoted stale withdrawn identity: fresh=%v runtime=%v capabilities=%v",
				fresh, runtimeVerified, effective)
		}
		if len(storedTemplates) != 0 {
			t.Fatalf("withdrawn identity restore retained stale hashes %v", storedTemplates)
		}
		if desired := srv.registry.DesiredModelsForProvider(provider.ID); len(desired) != 0 {
			t.Fatalf("withdrawn identity restore retained desired state %+v", desired)
		}

		// Restore the fixture's proven identity for independent cases below.
		provider.Mu().Lock()
		provider.FreshCodeAttested = true
		provider.TemplateHashes = map[string]string{"mlx_metallib": oldMetallib}
		provider.Mu().Unlock()
		setManifest(oldMetallib)
		assertState(true)
	})

	t.Run("omitted runtime identity cannot retain stale approval", func(t *testing.T) {
		runtimePolicyActive, runtimeOK, _ := srv.applyChallengeRuntimePolicy(
			provider,
			&protocol.AttestationResponseMessage{},
		)
		if !runtimePolicyActive {
			t.Fatal("active runtime manifest was not applied")
		}
		if runtimeOK {
			t.Fatal("challenge omitting the required metallib unexpectedly passed")
		}
		if err := srv.registry.ReconcileAttestedRuntimeCapabilities(provider.ID); err == nil {
			t.Fatal("omitted runtime identity still matched signed registration claims")
		}
		provider.Mu().Lock()
		fresh := provider.FreshCodeAttested
		effective := append([]string(nil), provider.RuntimeCapabilities...)
		storedTemplates := registry.CloneStringMap(provider.TemplateHashes)
		provider.Mu().Unlock()
		if fresh || len(effective) != 0 {
			t.Fatalf("omitted runtime identity retained fresh=%v capabilities=%v",
				fresh, effective)
		}
		if len(storedTemplates) != 0 {
			t.Fatalf("omitted runtime identity retained stale hashes %v", storedTemplates)
		}

		// Restore the fixture's proven identity for the independent changed-
		// identity case below.
		provider.Mu().Lock()
		provider.FreshCodeAttested = true
		provider.TemplateHashes = map[string]string{"mlx_metallib": oldMetallib}
		provider.Mu().Unlock()
		setManifest(oldMetallib)
		assertState(true)
	})

	t.Run("changed reported runtime clears fresh process proof", func(t *testing.T) {
		setManifest(newMetallib)
		assertState(false)
		runtimePolicyActive, runtimeOK, _ := srv.applyChallengeRuntimePolicy(
			provider,
			&protocol.AttestationResponseMessage{
				TemplateHashes: map[string]string{"mlx_metallib": newMetallib},
			},
		)
		if !runtimePolicyActive {
			t.Fatal("active runtime manifest was not applied")
		}
		if !runtimeOK {
			t.Fatal("newly approved changed runtime was rejected")
		}
		if err := srv.registry.ReconcileAttestedRuntimeCapabilities(provider.ID); err == nil {
			t.Fatal("changed runtime identity still matched signed registration claims")
		}
		provider.Mu().Lock()
		fresh := provider.FreshCodeAttested
		effective := append([]string(nil), provider.RuntimeCapabilities...)
		provider.Mu().Unlock()
		if fresh {
			t.Fatal("changed provider-reported runtime identity retained stale process proof")
		}
		if len(effective) != 0 {
			t.Fatalf("changed runtime identity retained effective capabilities %v", effective)
		}
		if desired := srv.registry.DesiredModelsForProvider(provider.ID); len(desired) != 0 {
			t.Fatalf("changed runtime identity retained desired state %+v", desired)
		}
		if models := srv.registry.ListModels(); len(models) != 0 {
			t.Fatalf("changed runtime identity remained routable: %d models", len(models))
		}
	})
}
