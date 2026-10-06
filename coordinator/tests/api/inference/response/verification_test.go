package response_test

import (
	"encoding/base64"
	"encoding/json"
	"log/slog"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	production "github.com/eigeninference/d-inference/coordinator/api/inference/response"
	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestVerificationHeadersMetadataAndRevocation(t *testing.T) {
	r := registry.New(slog.New(slog.DiscardHandler))
	p := newVerificationProvider(t, r)
	v := r.ProviderVerification(p)
	info := production.CollectCommittedProviderInfo(p)
	info.Verification = &v
	w := httptest.NewRecorder()
	production.WriteCommittedProviderHeaders(w, info)
	if w.Header().Get("X-Provider-Trust-Level") != "self_signed" || w.Header().Get("X-Provider-Authorization-Method") != "app_attest" {
		t.Fatal(w.Header())
	}
	pr := &registry.PendingRequest{RequestID: "job", MetadataDetails: true}
	production.SnapshotChatCompletionMetadata(pr, info)
	var meta types.ChatCompletionMetadata
	if err := json.Unmarshal(pr.ResponseMetadata, &meta); err != nil {
		t.Fatal(err)
	}
	header, err := json.Marshal(meta.Verification)
	if err != nil || string(header) != w.Header().Get("X-Provider-Verification") {
		t.Fatalf("header/body mismatch: %s, %v", header, err)
	}
	r.RevokeAppAttestCredential("credential")
	if meta.Verification.Method() != "app_attest" || r.ProviderVerification(p).Method() != "none" {
		t.Fatal("historical and live verdicts were conflated")
	}
	for _, forbidden := range []string{"credential", "account", "machine_id", "serial", "receipt", "certificate"} {
		if strings.Contains(string(header), forbidden) {
			t.Fatalf("public header leaked %s", forbidden)
		}
	}
}

func newVerificationProvider(t *testing.T, r *registry.Registry) *registry.Provider {
	t.Helper()
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
	r.SetAppAttestServingPolicy(true, 1)
	now := time.Now()
	if !r.GrantAppAttestServingAuthorization(p, registry.AppAttestServingAuthorization{AccountID: "account", MachineID: "machine", CredentialID: "credential", ConnectionID: p.ID, ProofSessionID: "proof", Endpoint: p.PublicKey, PolicyGeneration: 1, IssuedAt: now, ValidUntil: now.Add(30 * time.Second), MachineModel: "Mac16,10", MemoryGB: 32}) {
		t.Fatal("seed registry authorization")
	}
	t.Cleanup(func() { r.Disconnect(p.ID) })
	return p
}
