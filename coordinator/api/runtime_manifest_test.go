package api

import (
	"log/slog"
	"os"
	"strings"
	"testing"
	"time"

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
