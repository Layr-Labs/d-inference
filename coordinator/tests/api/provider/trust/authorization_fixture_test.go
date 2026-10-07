package trust_test

import (
	"encoding/base64"
	"io"
	"log/slog"
	"strings"
	"testing"
	"time"

	production "github.com/eigeninference/d-inference/coordinator/api/provider/trust"
	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func newAuthorizationFixture(t *testing.T) (*trustFixture, *registry.Provider, *protocol.AppAttestStatus) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	r := registry.New(logger)
	key := base64.StdEncoding.EncodeToString(make([]byte, 32))
	p := r.Register("connection", nil, &protocol.RegisterMessage{PublicKey: key, AppAttestProtocol: 3, Backend: registry.BackendMLXSwift, EncryptedResponseChunks: true, Hardware: protocol.Hardware{MachineModel: "Mac16,10", MemoryGB: 32}})
	p.AccountID, p.RuntimeVerified, p.RuntimeManifestChecked = "account", true, true
	p.PrivacyCapabilities = &protocol.PrivacyCapabilities{TextBackendInprocess: true, TextProxyDisabled: true, AntiDebugEnabled: true, CoreDumpsDisabled: true, EnvScrubbed: true}
	p.Version, p.MetallibVerified = "0.9.4", true
	p.TemplateHashes = map[string]string{"mlx_metallib": strings.Repeat("b", 64)}
	p.AttestationResult = &attestation.VerificationResult{Valid: true, PublicKey: "se", EncryptionPublicKey: key, MetallibHash: strings.Repeat("b", 64)}
	p.SetAttested(true, registry.TrustSelfSigned)
	p.CompleteProviderStateRestore()
	if !r.BindVerifiedMachineIdentity(p, "account", "machine") {
		t.Fatal("identity")
	}
	s := newTrustFixture(t, production.Dependencies{Registry: r, Store: memory.NewMemory(store.Config{}), Logger: logger}, production.Config{AppAttest: production.AppAttestShadowConfig{ServingEnabled: true, MDMRemovalEnabled: true, Environment: "production"}})
	t.Cleanup(s.Close)
	policy := publishTestReleasePolicy(t, s, store.Release{BinaryHash: strings.Repeat("a", 64), Version: "0.9.4", Platform: "macos-arm64", MetallibHash: strings.Repeat("b", 64)})
	status := &protocol.AppAttestStatus{BinaryHash: strings.Repeat("a", 64), AppVersion: "0.9.4", AttestationPublicKey: "se", MachineModel: "Mac16,10", MemoryGB: "32"}
	now := time.Now()
	if !r.GrantAppAttestServingAuthorization(p, registry.AppAttestServingAuthorization{AccountID: "account", MachineID: "machine", CredentialID: "credential", ConnectionID: p.ID, ProofSessionID: "proof", Endpoint: p.PublicKey, PolicyGeneration: policy.Generation, IssuedAt: now, ValidUntil: now.Add(30 * time.Second), MachineModel: "Mac16,10", MemoryGB: 32}) {
		t.Fatal("seed registry authorization")
	}
	t.Cleanup(func() { r.Disconnect(p.ID) })
	return s, p, status
}
