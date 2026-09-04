package api

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"testing/synctest"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

// TestProviderRegistrationWithValidAttestation verifies that a provider
// with a valid Secure Enclave attestation is marked as attested.
func TestProviderRegistrationWithValidAttestation(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	pubKey := testPublicKeyB64()
	attestationJSON := createTestAttestationJSON(t, pubKey)

	regMsg := protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "attested-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 "mlx-swift",
		PublicKey:               pubKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
		Attestation:             attestationJSON,
	}
	regData, _ := json.Marshal(regMsg)
	conn.Write(ctx, websocket.MessageText, regData)
	time.Sleep(200 * time.Millisecond)

	if reg.ProviderCount() != 1 {
		t.Fatalf("provider count = %d, want 1", reg.ProviderCount())
	}

	// Upgrade to hardware trust (simulates MDM verification completing).
	p := findProviderByModel(reg, "attested-model")
	if p != nil {
		reg.SetTrustLevel(p.ID, registry.TrustHardware)
		reg.RecordChallengeSuccess(p.ID)
	}

	models := reg.ListModels()
	if len(models) != 1 {
		t.Fatalf("models = %d, want 1", len(models))
	}
	if models[0].AttestedProviders != 1 {
		t.Errorf("attested_providers = %d, want 1", models[0].AttestedProviders)
	}
}

func TestProviderRegistrationBindsProtectedRuntimeClaims(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	reg := registry.New(logger)
	reg.SetModelCatalog([]registry.CatalogEntry{{ID: registry.Qwen38NAXModelID}})
	srv := NewServer(
		reg,
		store.NewMemory(store.Config{AdminKey: "test-key"}),
		ServerConfig{},
		logger,
	)
	metallibHash := strings.Repeat("a", 64)
	srv.SetRuntimeManifest(&RuntimeManifest{
		TemplateHashes: map[string]map[string]bool{"mlx_metallib": {metallibHash: true}},
	})
	publicKey := testPublicKeyB64()
	regMsg := &protocol.RegisterMessage{
		Type:    protocol.TypeRegister,
		Version: minProviderVersionForReconnectAttestation,
		Hardware: protocol.Hardware{
			ChipName:   "Apple M5 Max",
			ChipFamily: "M5",
		},
		Models:    []protocol.ModelInfo{{ID: registry.Qwen38NAXModelID}},
		Backend:   "mlx-swift",
		PublicKey: publicKey,
		Attestation: buildTestAttestationJSONWithFields(
			t,
			publicKey,
			"",
			"",
			time.Now(),
			map[string]interface{}{
				"chipFamily":   "M5",
				"chipName":     "Apple M5 Max",
				"metallibHash": metallibHash,
				"runtimeCapabilities": []string{
					registry.ProviderCapabilityAppleM5,
					registry.ProviderCapabilityMLXNAX,
				},
			},
		),
		RuntimeCapabilities: []string{
			registry.ProviderCapabilityAppleM5,
			registry.ProviderCapabilityMLXNAX,
		},
		TemplateHashes: map[string]string{"mlx_metallib": metallibHash},
	}
	provider := reg.Register("signed-runtime", nil, regMsg)
	srv.verifyProviderAttestation(provider.ID, provider, regMsg)
	runtimeOK, mismatches := srv.verifyRuntimeHashesForBackend(
		regMsg.Backend, "", "", regMsg.TemplateHashes)
	if !runtimeOK {
		t.Fatalf("runtime manifest rejected valid metallib: %v", mismatches)
	}
	provider.Mu().Lock()
	provider.RuntimeVerified = true
	provider.RuntimeManifestChecked = true
	provider.MetallibVerified = true
	provider.TemplateHashes = registry.CloneStringMap(regMsg.TemplateHashes)
	provider.Mu().Unlock()
	if err := reg.ReconcileAttestedRuntimeCapabilities(provider.ID); err != nil {
		t.Fatal(err)
	}
	if len(provider.RuntimeCapabilities) != 0 {
		t.Fatalf("capabilities promoted before hardware/code trust: %v",
			provider.RuntimeCapabilities)
	}
	if got := reg.ModelProviderSnapshot()[registry.Qwen38NAXModelID]; got != 0 {
		t.Fatalf("protected model exposed while hardware/code trust pending: %d", got)
	}

	reg.SetTrustLevel(provider.ID, registry.TrustHardware)
	if len(provider.RuntimeCapabilities) != 0 {
		t.Fatalf("hardware trust alone promoted capabilities: %v",
			provider.RuntimeCapabilities)
	}
	provider.SetFreshCodeAttested()
	provider.Mu().Lock()
	provider.ChallengeVerifiedSIP = true
	provider.LastChallengeVerified = time.Now()
	provider.Mu().Unlock()
	if len(provider.RuntimeCapabilities) != 2 {
		t.Fatalf("fully verified runtime capabilities = %v",
			provider.RuntimeCapabilities)
	}
	provider.SetCodeAttested(false)
	if len(provider.RuntimeCapabilities) != 0 {
		t.Fatalf("code-attestation loss retained capabilities: %v",
			provider.RuntimeCapabilities)
	}
	provider.SetFreshCodeAttested()
	if got := reg.ModelProviderSnapshot()[registry.Qwen38NAXModelID]; got != 1 {
		t.Fatalf("valid signed protected model count = %d, want 1", got)
	}
	reg.SetTrustLevel(provider.ID, registry.TrustSelfSigned)
	if len(provider.RuntimeCapabilities) != 0 {
		t.Fatalf("hardware-trust loss retained capabilities: %v",
			provider.RuntimeCapabilities)
	}
}

func TestProviderRegistrationAttestationFreshnessVersionGate(t *testing.T) {
	cases := []struct {
		name            string
		version         string
		timestampOffset time.Duration
		accepted        bool
	}{
		{
			name:            "missing version retains legacy reconnect semantics",
			timestampOffset: -10 * time.Minute,
			accepted:        true,
		},
		{
			name:            "last legacy release accepts reconnect replay",
			version:         "0.8.14",
			timestampOffset: -10 * time.Minute,
			accepted:        true,
		},
		{
			name:            "capability release rejects stale replay",
			version:         minProviderVersionForReconnectAttestation,
			timestampOffset: -10 * time.Minute,
		},
		{
			name:            "newer release rejects stale replay",
			version:         "0.8.16",
			timestampOffset: -10 * time.Minute,
		},
		{
			name:            "capability release accepts future skew just under boundary",
			version:         minProviderVersionForReconnectAttestation,
			timestampOffset: RegistrationAttestationMaxFutureSkew - time.Second,
			accepted:        true,
		},
		{
			name:            "capability release accepts future skew at boundary",
			version:         minProviderVersionForReconnectAttestation,
			timestampOffset: RegistrationAttestationMaxFutureSkew,
			accepted:        true,
		},
		{
			name:            "capability release rejects future skew just over boundary",
			version:         minProviderVersionForReconnectAttestation,
			timestampOffset: RegistrationAttestationMaxFutureSkew + time.Second,
		},
		{
			name:     "capability release accepts fresh reconnect",
			version:  minProviderVersionForReconnectAttestation,
			accepted: true,
		},
	}

	for index, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				logger := slog.New(slog.NewTextHandler(io.Discard, nil))
				reg := registry.New(logger)
				srv := NewServer(
					reg,
					store.NewMemory(store.Config{AdminKey: "test-key"}),
					ServerConfig{},
					logger,
				)
				defer srv.Close()
				publicKey := testPublicKeyB64()
				// The bubble freezes time at a whole-second instant while this
				// synchronous verification runs, so the signed fixture keeps exact
				// below/at/one-second-over boundary coverage without aging between
				// construction and CheckTimestamp. Production clocks are untouched.
				timestamp := time.Now().Add(tc.timestampOffset)
				regMsg := &protocol.RegisterMessage{
					Type:      protocol.TypeRegister,
					Version:   tc.version,
					PublicKey: publicKey,
					Attestation: buildTestAttestationJSONWithFields(
						t, publicKey, "", "", timestamp, nil),
				}
				provider := reg.Register(fmt.Sprintf("reconnect-%d", index), nil, regMsg)
				srv.verifyProviderAttestation(provider.ID, provider, regMsg)

				provider.Mu().Lock()
				defer provider.Mu().Unlock()
				if tc.accepted {
					if provider.Status == registry.StatusUntrusted ||
						provider.AttestationResult == nil ||
						!provider.AttestationResult.Valid {
						t.Fatalf("freshness-compatible registration rejected: status=%s result=%+v",
							provider.Status, provider.AttestationResult)
					}
					if provider.LastChallengeVerified.IsZero() {
						t.Fatal("accepted registration did not initialize periodic challenge freshness")
					}
					return
				}
				if provider.Status != registry.StatusUntrusted ||
					provider.AttestationResult == nil ||
					provider.AttestationResult.Error != "attestation timestamp outside freshness window" {
					t.Fatalf("replayed attestation state = status=%s result=%+v",
						provider.Status, provider.AttestationResult)
				}
				if len(provider.RuntimeCapabilities) != 0 {
					t.Fatalf("replayed attestation retained capabilities: %v",
						provider.RuntimeCapabilities)
				}
			})
		})
	}
}

func TestLegacyRegistrationReplayCannotPromoteProtectedRuntimeCapabilities(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	reg := registry.New(logger)
	reg.SetModelCatalog([]registry.CatalogEntry{{ID: registry.Qwen38NAXModelID}})
	srv := NewServer(
		reg,
		store.NewMemory(store.Config{AdminKey: "test-key"}),
		ServerConfig{},
		logger,
	)
	metallibHash := strings.Repeat("a", 64)
	publicKey := testPublicKeyB64()
	regMsg := &protocol.RegisterMessage{
		Type:    protocol.TypeRegister,
		Version: "0.8.14",
		Hardware: protocol.Hardware{
			ChipName:   "Apple M5 Max",
			ChipFamily: "M5",
		},
		Models:    []protocol.ModelInfo{{ID: registry.Qwen38NAXModelID}},
		Backend:   "mlx-swift",
		PublicKey: publicKey,
		Attestation: buildTestAttestationJSONWithFields(
			t,
			publicKey,
			"",
			"",
			time.Now().Add(-10*time.Minute),
			map[string]interface{}{
				"chipFamily":   "M5",
				"chipName":     "Apple M5 Max",
				"metallibHash": metallibHash,
				"runtimeCapabilities": []string{
					registry.ProviderCapabilityAppleM5,
					registry.ProviderCapabilityMLXNAX,
				},
			},
		),
		RuntimeCapabilities: []string{
			registry.ProviderCapabilityAppleM5,
			registry.ProviderCapabilityMLXNAX,
		},
		TemplateHashes: map[string]string{"mlx_metallib": metallibHash},
	}
	provider := reg.Register("legacy-reconnect", nil, regMsg)
	srv.verifyProviderAttestation(provider.ID, provider, regMsg)
	provider.Mu().Lock()
	provider.RuntimeVerified = true
	provider.RuntimeManifestChecked = true
	provider.MetallibVerified = true
	provider.ChallengeVerifiedSIP = true
	provider.LastChallengeVerified = time.Now()
	provider.Mu().Unlock()
	reg.SetTrustLevel(provider.ID, registry.TrustHardware)
	provider.SetFreshCodeAttested()
	if err := reg.ReconcileAttestedRuntimeCapabilities(provider.ID); err != nil {
		t.Fatalf("legacy capability reconciliation failed: %v", err)
	}

	if len(provider.RuntimeCapabilities) != 0 {
		t.Fatalf("legacy reconnect promoted protected capabilities: %v",
			provider.RuntimeCapabilities)
	}
	if got := reg.ModelProviderSnapshot()[registry.Qwen38NAXModelID]; got != 0 {
		t.Fatalf("legacy reconnect exposed exact Qwen build: %d", got)
	}
}

func TestProviderRegistrationRequiresBinaryHashWhenPolicyConfigured(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.SetKnownBinaryHashes([]string{knownGoodBinaryHashForTest})
	srv.SetBinaryHashEnforcement(true) // v0.6.0: binaryHash gating is off by default; exercise the legacy enforcement path

	pubKey := testPublicKeyB64()
	regMsg := &protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "missing-binary-hash-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 "mlx-swift",
		PublicKey:               pubKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
		Attestation:             createTestAttestationJSON(t, pubKey),
	}
	p := reg.Register("provider-1", nil, regMsg)

	srv.verifyProviderAttestation("provider-1", p, regMsg)

	if p.AttestationResult == nil {
		t.Fatal("expected attestation result")
	}
	if p.AttestationResult.Valid {
		t.Fatal("attestation should be invalid when binary hash policy is configured and hash is missing")
	}
	if p.AttestationResult.Error != "binary hash missing" {
		t.Fatalf("attestation error = %q, want %q", p.AttestationResult.Error, "binary hash missing")
	}
	p.Mu().Lock()
	defer p.Mu().Unlock()
	if p.Status != registry.StatusUntrusted {
		t.Fatalf("provider status = %q, want %q", p.Status, registry.StatusUntrusted)
	}
	if p.TrustLevel != registry.TrustNone {
		t.Fatalf("provider trust = %q, want %q", p.TrustLevel, registry.TrustNone)
	}
}

func TestProviderRegistrationAcceptsKnownBinaryHash(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.SetKnownBinaryHashes([]string{knownGoodBinaryHashForTest})
	srv.SetBinaryHashEnforcement(true) // v0.6.0: binaryHash gating is off by default; exercise the legacy enforcement path

	pubKey := testPublicKeyB64()
	regMsg := &protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "known-binary-hash-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 "mlx-swift",
		PublicKey:               pubKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
		Attestation:             createTestAttestationJSONWithBinaryHash(t, pubKey, knownGoodBinaryHashForTest),
	}
	p := reg.Register("provider-1", nil, regMsg)

	srv.verifyProviderAttestation("provider-1", p, regMsg)

	if p.AttestationResult == nil {
		t.Fatal("expected attestation result")
	}
	if !p.AttestationResult.Valid {
		t.Fatalf("attestation should be valid with a known binary hash, got %q", p.AttestationResult.Error)
	}
	p.Mu().Lock()
	defer p.Mu().Unlock()
	if p.Status == registry.StatusUntrusted {
		t.Fatal("provider should not be marked untrusted with a known binary hash")
	}
	if p.TrustLevel != registry.TrustSelfSigned {
		t.Fatalf("provider trust = %q, want %q", p.TrustLevel, registry.TrustSelfSigned)
	}
}

func TestProviderRegistrationRejectsInvalidConfiguredBinaryHash(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.SetKnownBinaryHashes([]string{"not-a-sha256"})
	srv.SetBinaryHashEnforcement(true) // v0.6.0: exercise the legacy enforcement path

	pubKey := testPublicKeyB64()
	regMsg := &protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "invalid-configured-hash-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 "mlx-swift",
		PublicKey:               pubKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
		Attestation:             createTestAttestationJSONWithBinaryHash(t, pubKey, "not-a-sha256"),
	}
	p := reg.Register("provider-1", nil, regMsg)

	srv.verifyProviderAttestation("provider-1", p, regMsg)

	policyConfigured, knownHashes := srv.binaryHashPolicySnapshot()
	if !policyConfigured {
		t.Fatal("binary hash policy should remain configured even when configured hashes are invalid")
	}
	if len(knownHashes) != 0 {
		t.Fatalf("known binary hashes = %d, want 0 valid hashes", len(knownHashes))
	}
	if p.AttestationResult == nil {
		t.Fatal("expected attestation result")
	}
	if p.AttestationResult.Valid {
		t.Fatal("attestation should be invalid when configured hash and reported hash are invalid")
	}
	p.Mu().Lock()
	defer p.Mu().Unlock()
	if p.Status != registry.StatusUntrusted {
		t.Fatalf("provider status = %q, want %q", p.Status, registry.StatusUntrusted)
	}
}

func TestSyncBinaryHashesRejectsInvalidStoredReleaseHashWithoutFailingOpen(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	if err := st.SetRelease(&store.Release{
		Version:    "1.0.0",
		Platform:   "macos-arm64",
		BinaryHash: "not-a-sha256",
		BundleHash: strings.Repeat("b", 64),
		URL:        "https://r2.example.com/releases/v1.0.0/darkbloom-bundle-macos-arm64.tar.gz",
	}); err != nil {
		t.Fatalf("SetRelease: %v", err)
	}

	srv.SyncBinaryHashes()

	policyConfigured, knownHashes := srv.binaryHashPolicySnapshot()
	if !policyConfigured {
		t.Fatal("binary hash policy should remain configured when an active release has an invalid hash")
	}
	if len(knownHashes) != 0 {
		t.Fatalf("known binary hashes = %d, want 0 valid hashes", len(knownHashes))
	}
}

func TestSyncBinaryHashesPreservesAdditionalConfiguredHashes(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	manualHash := strings.Repeat("a", 64)
	releaseHash := strings.Repeat("b", 64)
	srv.AddKnownBinaryHashes([]string{manualHash})
	if err := st.SetRelease(&store.Release{
		Version:    "1.0.0",
		Platform:   "macos-arm64",
		BinaryHash: releaseHash,
		BundleHash: strings.Repeat("c", 64),
		URL:        "https://r2.example.com/releases/v1.0.0/darkbloom-bundle-macos-arm64.tar.gz",
	}); err != nil {
		t.Fatalf("SetRelease: %v", err)
	}

	srv.SyncBinaryHashes()
	policyConfigured, knownHashes := srv.binaryHashPolicySnapshot()
	if !policyConfigured {
		t.Fatal("binary hash policy should be configured after manual hash and active release")
	}
	if !knownHashes[manualHash] {
		t.Fatal("manual binary hash was dropped during release sync")
	}
	if !knownHashes[releaseHash] {
		t.Fatal("release binary hash was not synced")
	}

	if err := st.DeleteRelease("1.0.0", "macos-arm64"); err != nil {
		t.Fatalf("DeleteRelease: %v", err)
	}
	srv.SyncBinaryHashes()
	policyConfigured, knownHashes = srv.binaryHashPolicySnapshot()
	if !policyConfigured {
		t.Fatal("binary hash policy should remain configured after release deletion because manual hash remains")
	}
	if !knownHashes[manualHash] {
		t.Fatal("manual binary hash was dropped during release deletion sync")
	}
	if knownHashes[releaseHash] {
		t.Fatal("inactive release binary hash should not remain after sync")
	}
}

func TestAdminDeleteReleaseBlocksActiveBinaryHashWhenEnforced(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{AdminKey: "admin-key"}, logger)
	srv.SetBinaryHashEnforcement(true)

	releaseHash := strings.Repeat("c", 64)
	if err := st.SetRelease(&store.Release{
		Version:    "1.0.0",
		Platform:   "macos-arm64",
		BinaryHash: releaseHash,
		BundleHash: strings.Repeat("d", 64),
		URL:        "https://r2.example.com/releases/v1.0.0/darkbloom-bundle-macos-arm64.tar.gz",
	}); err != nil {
		t.Fatalf("SetRelease: %v", err)
	}
	p := reg.Register("provider-old", nil, &protocol.RegisterMessage{
		Type:    protocol.TypeRegister,
		Backend: "mlx-swift",
		Hardware: protocol.Hardware{
			MachineModel: "Mac15,8",
			ChipName:     "Apple M3 Max",
			MemoryGB:     64,
		},
		Models: []protocol.ModelInfo{{ID: "test-model", ModelType: "chat", Quantization: "4bit"}},
	})
	p.SetAttestationResult(&attestation.VerificationResult{Valid: true, BinaryHash: releaseHash})

	req := httptest.NewRequest(http.MethodDelete, "/v1/admin/releases", strings.NewReader(`{"version":"1.0.0","platform":"macos-arm64"}`))
	req.Header.Set("Authorization", "Bearer admin-key")
	w := httptest.NewRecorder()
	srv.handleAdminDeleteRelease(w, req)
	if w.Code != http.StatusConflict {
		t.Fatalf("delete without force status = %d, want %d; body=%s", w.Code, http.StatusConflict, w.Body.String())
	}
	if latest := st.GetLatestRelease("macos-arm64"); latest == nil || !latest.Active {
		t.Fatal("release should remain active after protected delete")
	}

	forceReq := httptest.NewRequest(http.MethodDelete, "/v1/admin/releases", strings.NewReader(`{"version":"1.0.0","platform":"macos-arm64","force":true}`))
	forceReq.Header.Set("Authorization", "Bearer admin-key")
	forceW := httptest.NewRecorder()
	srv.handleAdminDeleteRelease(forceW, forceReq)
	if forceW.Code != http.StatusOK {
		t.Fatalf("force delete status = %d, want %d; body=%s", forceW.Code, http.StatusOK, forceW.Body.String())
	}
	if latest := st.GetLatestRelease("macos-arm64"); latest != nil {
		t.Fatal("release should be inactive after forced delete")
	}
}

func TestBinaryHashPolicySnapshotConcurrentSync(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	manualHash := strings.Repeat("a", 64)
	srv.AddKnownBinaryHashes([]string{manualHash})

	done := make(chan struct{})
	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-done:
					return
				default:
					policyConfigured, knownHashes := srv.binaryHashPolicySnapshot()
					if policyConfigured && !knownHashes[manualHash] {
						t.Errorf("manual hash missing from policy snapshot")
						return
					}
				}
			}
		}()
	}

	for i := 0; i < 50; i++ {
		version := fmt.Sprintf("1.0.%d", i)
		releaseHash := fmt.Sprintf("%064x", i+1)
		if err := st.SetRelease(&store.Release{
			Version:    version,
			Platform:   "macos-arm64",
			BinaryHash: releaseHash,
			BundleHash: strings.Repeat("c", 64),
			URL:        "https://r2.example.com/releases/v" + version + "/darkbloom-bundle-macos-arm64.tar.gz",
		}); err != nil {
			t.Fatalf("SetRelease: %v", err)
		}
		srv.SyncBinaryHashes()
		if err := st.DeleteRelease(version, "macos-arm64"); err != nil {
			t.Fatalf("DeleteRelease: %v", err)
		}
		srv.SyncBinaryHashes()
	}

	close(done)
	wg.Wait()
}

// TestProviderRegistrationWithInvalidAttestation verifies that a provider
// with an invalid attestation is still registered but not marked as attested.
func TestProviderRegistrationWithInvalidAttestation(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	// Invalid attestation: garbage JSON that won't verify
	invalidAttestation := json.RawMessage(`{"attestation":{"chipName":"Fake","hardwareModel":"Bad","osVersion":"0","publicKey":"dGVzdA==","secureBootEnabled":true,"secureEnclaveAvailable":true,"sipEnabled":true,"timestamp":"2025-01-01T00:00:00Z"},"signature":"YmFkc2ln"}`)

	regMsg := protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "unattested-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 "mlx-swift",
		PublicKey:               testPublicKeyB64(),
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
		Attestation:             invalidAttestation,
	}
	regData, _ := json.Marshal(regMsg)
	conn.Write(ctx, websocket.MessageText, regData)
	time.Sleep(200 * time.Millisecond)

	// Provider should still be registered but not routable (no hardware trust).
	if reg.ProviderCount() != 1 {
		t.Fatalf("provider count = %d, want 1", reg.ProviderCount())
	}

	// Without hardware trust, models should not be listed.
	models := reg.ListModels()
	if len(models) != 0 {
		t.Fatalf("models = %d, want 0 (invalid attestation, no hardware trust)", len(models))
	}
}

// TestProviderRegistrationWithoutAttestation verifies that a provider
// without an attestation still works in Open Mode.
func TestProviderRegistrationWithoutAttestation(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	regMsg := protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: protocol.Hardware{ChipName: "M3 Max", MemoryGB: 64},
		Models:   []protocol.ModelInfo{{ID: "open-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:  "mlx-swift",
		// No attestation — Open Mode
	}
	regData, _ := json.Marshal(regMsg)
	conn.Write(ctx, websocket.MessageText, regData)
	time.Sleep(200 * time.Millisecond)

	if reg.ProviderCount() != 1 {
		t.Fatalf("provider count = %d, want 1", reg.ProviderCount())
	}

	// Without attestation, provider has no hardware trust and should not be listed.
	models := reg.ListModels()
	if len(models) != 0 {
		t.Fatalf("models = %d, want 0 (no attestation, no hardware trust)", len(models))
	}
}

// TestProviderRegistrationWithoutAttestationRejectedWhenBinaryHashPolicyConfigured
// verifies that when a binary-hash policy is in force (SetKnownBinaryHashes),
// a Register message with no attestation is marked Untrusted with the
// "attestation missing" error rather than silently accepted.
//
// Ported from master's coordinator/internal/api/provider_test.go (PR #99 regression).
func TestProviderRegistrationWithoutAttestationRejectedWhenBinaryHashPolicyConfigured(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.SetKnownBinaryHashes([]string{knownGoodBinaryHashForTest})
	srv.SetBinaryHashEnforcement(true) // v0.6.0: binaryHash gating is off by default; exercise the legacy enforcement path

	regMsg := &protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "no-attestation-policy-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 "mlx-swift",
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
	}
	p := reg.Register("provider-1", nil, regMsg)

	srv.verifyProviderAttestation("provider-1", p, regMsg)

	if p.AttestationResult == nil {
		t.Fatal("expected attestation result")
	}
	if p.AttestationResult.Valid {
		t.Fatal("missing attestation should be invalid when binary hash policy is configured")
	}
	if p.AttestationResult.Error != "attestation missing" {
		t.Fatalf("attestation error = %q, want %q", p.AttestationResult.Error, "attestation missing")
	}
	p.Mu().Lock()
	defer p.Mu().Unlock()
	if p.Status != registry.StatusUntrusted {
		t.Fatalf("provider status = %q, want %q", p.Status, registry.StatusUntrusted)
	}
}

// TestListModelsWithAttestationInfo verifies that /v1/models includes
// attestation metadata.
func TestListModelsWithAttestationInfo(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"

	// Register an attested provider
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	pubKey := testPublicKeyB64()
	attestationJSON := createTestAttestationJSON(t, pubKey)
	regMsg := protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "attested-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 "mlx-swift",
		PublicKey:               pubKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
		Attestation:             attestationJSON,
	}
	regData, _ := json.Marshal(regMsg)
	conn.Write(ctx, websocket.MessageText, regData)
	time.Sleep(200 * time.Millisecond)

	// Upgrade to hardware trust for model listing.
	p := findProviderByModel(reg, "attested-model")
	if p != nil {
		reg.SetTrustLevel(p.ID, registry.TrustHardware)
		reg.RecordChallengeSuccess(p.ID)
	}

	// Check /v1/models
	req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", w.Code)
	}

	var body map[string]any
	json.Unmarshal(w.Body.Bytes(), &body)
	data := body["data"].([]any)
	if len(data) != 1 {
		t.Fatalf("models = %d, want 1", len(data))
	}

	model := data[0].(map[string]any)
	metadata := model["metadata"].(map[string]any)

	attestedProviders := metadata["attested_providers"].(float64)
	if attestedProviders != 1 {
		t.Errorf("attested_providers = %v, want 1", attestedProviders)
	}

	attestation := metadata["attestation"].(map[string]any)
	if attestation["secure_enclave"] != true {
		t.Errorf("secure_enclave = %v, want true", attestation["secure_enclave"])
	}
	if attestation["sip_enabled"] != true {
		t.Errorf("sip_enabled = %v, want true", attestation["sip_enabled"])
	}
	if attestation["secure_boot"] != true {
		t.Errorf("secure_boot = %v, want true", attestation["secure_boot"])
	}
}

func TestAttestationRejectsMissingEncryptionKeyForRegisteredPublicKey(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	pubKey := testPublicKeyB64()
	attestationJSON := createTestAttestationJSON(t, "")
	regMsg := protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "binding-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 "mlx-swift",
		PublicKey:               pubKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
		Attestation:             attestationJSON,
	}
	regData, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		t.Fatalf("write register: %v", err)
	}
	time.Sleep(200 * time.Millisecond)

	p := findProviderByModel(reg, "binding-model")
	if p == nil {
		t.Fatal("expected provider to be registered")
	}
	ar := p.GetAttestationResult()
	if ar == nil {
		t.Fatal("expected attestation result to be recorded")
	}
	if ar.Valid {
		t.Fatal("attestation should be invalid when encryptionPublicKey is missing")
	}
	if ar.Error != "attestation missing encryption public key" {
		t.Fatalf("attestation error = %q", ar.Error)
	}
}

func TestAttestationRejectsMismatchedEncryptionKey(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	pubKey := testPublicKeyB64()
	attestationJSON := createTestAttestationJSON(t, testPublicKeyB64())
	regMsg := protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "binding-mismatch-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 "mlx-swift",
		PublicKey:               pubKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
		Attestation:             attestationJSON,
	}
	regData, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		t.Fatalf("write register: %v", err)
	}
	time.Sleep(200 * time.Millisecond)

	p := findProviderByModel(reg, "binding-mismatch-model")
	if p == nil {
		t.Fatal("expected provider to be registered")
	}
	ar := p.GetAttestationResult()
	if ar == nil {
		t.Fatal("expected attestation result to be recorded")
	}
	if ar.Valid {
		t.Fatal("attestation should be invalid when encryptionPublicKey mismatches")
	}
	if ar.Error != "encryption key mismatch" {
		t.Fatalf("attestation error = %q", ar.Error)
	}
}
