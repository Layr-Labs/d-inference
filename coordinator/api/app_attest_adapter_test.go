package api

import (
	"context"
	"encoding/base64"
	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// Adapter tests seed registry authorization directly; cryptographic exchanges
// and authorization workers are tested through their private service package.
func newAuthorizationFixture(t *testing.T) (*Server, *registry.Provider, *protocol.AppAttestStatus) {
	t.Helper()
	return newAuthorizationFixtureWithStore(t, memory.NewMemory(store.Config{}))
}

func newAuthorizationFixtureWithStore(t *testing.T, st store.Store) (*Server, *registry.Provider, *protocol.AppAttestStatus) {
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
	s := NewServer(r, st, ServerConfig{AppAttestShadow: AppAttestShadowConfig{ServingEnabled: true, MDMRemovalEnabled: true, Environment: "production"}}, logger)
	t.Cleanup(s.Close)
	policy := publishTestReleasePolicy(t, s, store.Release{BinaryHash: strings.Repeat("a", 64), Version: "0.9.4", Platform: "macos-arm64", MetallibHash: strings.Repeat("b", 64)})
	status := &protocol.AppAttestStatus{BinaryHash: strings.Repeat("a", 64), AppVersion: "0.9.4", AttestationPublicKey: "se", MachineModel: "Mac16,10", MemoryGB: "32"}
	now := time.Now()
	// NewServer synchronously publishes the initial empty qualification snapshot.
	if !r.GrantAppAttestServingAuthorization(p, registry.AppAttestServingAuthorization{AccountID: "account", MachineID: "machine", CredentialID: "credential", ConnectionID: p.ID, ProofSessionID: "proof", Endpoint: p.PublicKey, PolicyGeneration: policy.Generation, QualificationGeneration: 1, IssuedAt: now, ValidUntil: now.Add(30 * time.Second), MachineModel: "Mac16,10", MemoryGB: 32}) {
		t.Fatal("seed registry authorization")
	}
	t.Cleanup(func() { r.Disconnect(p.ID) })
	return s, p, status
}
func TestAppAttestAdminRevocationOwnershipAndIdempotency(t *testing.T) {
	s, p, _ := newAuthorizationFixture(t)
	s.SetAdminKey("admin-secret")
	keys, _ := store.As[store.AppAttestShadowStore](s.store)
	_, err := keys.InsertAppAttestShadowKey(context.Background(), store.AppAttestShadowKey{KeyID: "credential", AccountID: "account"})
	if err != nil {
		t.Fatal(err)
	}
	call := func(account, token string) int {
		r := httptest.NewRequest(http.MethodPost, "/v1/admin/app-attest/revoke", strings.NewReader(`{"key_id":"credential","account_id":"`+account+`","reason":"operator_revoked"}`))
		r.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		s.trust.HandleAdminAppAttestRevoke(w, r)
		return w.Code
	}
	if got := call("account", "wrong"); got == http.StatusOK {
		t.Fatal("unauthenticated revoke")
	}
	if got := call("other", "admin-secret"); got != http.StatusNotFound {
		t.Fatalf("account mismatch %d", got)
	}
	if _, valid := s.registry.ProviderServingAuthorization(p); !valid {
		t.Fatal("wrong account revoked lease")
	}
	for i := 0; i < 2; i++ {
		if got := call("account", "admin-secret"); got != http.StatusOK {
			t.Fatalf("revocation %d", got)
		}
	}
	if _, valid := s.registry.ProviderServingAuthorization(p); valid {
		t.Fatal("successful revocation did not fence")
	}
}

func TestAppAttestPublicAuthorizationDoesNotExposePrivateIdentity(t *testing.T) {
	s, _, _ := newAuthorizationFixture(t)
	w := httptest.NewRecorder()
	s.trust.HandleProviderAttestation(w, httptest.NewRequest(http.MethodGet, "/v1/providers/attestation", nil))
	if w.Code != http.StatusOK || !strings.Contains(w.Body.String(), `"app_attest_authorized":true`) {
		t.Fatalf("public verdict %d %s", w.Code, w.Body.String())
	}
	for _, field := range []string{`"account_id"`, `"machine_id"`, `"credential_id"`, `"key_id"`, `"serial_number"`, `"receipt"`} {
		if strings.Contains(w.Body.String(), field) {
			t.Fatalf("private field %s", field)
		}
	}
}

func TestAppAttestAccountBoundInitialHistoryRestore(t *testing.T) {
	s, p, _ := newAuthorizationFixture(t)
	if err := s.store.UpsertProvider(context.Background(), store.ProviderRecord{ID: "other-history", SEPublicKey: "se", AccountID: "previous-owner", LastSeen: time.Now(), LifetimeTokensGenerated: 99}); err != nil {
		t.Fatal(err)
	}
	if err := s.providers.RestorePersistedProviderState(context.Background(), p, "", "se", "account"); err != nil {
		t.Fatal(err)
	}
	if p.AccountID != "account" || p.Stats.TokensGenerated != 0 {
		t.Fatal("inherited another account history")
	}
}

func TestAppAttestAuthorizerRevalidatesMetalLibraryAndBackend(t *testing.T) {
	for _, mode := range []string{"metallib", "backend", "verification_key", "runtime"} {
		t.Run(mode, func(t *testing.T) {
			s, p, status := newAuthorizationFixture(t)
			if !s.releases.Policy().AppAttestReleaseApproved(p, status) {
				t.Fatal("initial release rejected")
			}
			row := store.Release{BinaryHash: strings.Repeat("a", 64), Version: "0.9.4", Platform: "macos-arm64", MetallibHash: strings.Repeat("b", 64)}
			switch mode {
			case "metallib":
				row.MetallibHash = strings.Repeat("c", 64)
			case "backend":
				row.Backend = "other"
			case "verification_key":
				status.AttestationPublicKey = "other"
			case "runtime":
				p.MetallibVerified = false
			}
			publishTestReleasePolicy(t, s, row)
			if s.releases.Policy().AppAttestReleaseApproved(p, status) {
				t.Fatal("stale runtime reapproved")
			}
			if _, ok := s.registry.ProviderServingAuthorization(p); ok {
				t.Fatal("old generation authorization survived")
			}
		})
	}
}
