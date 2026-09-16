package api

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type authorizationBatchStore struct {
	store.Store
	state map[string]store.AppAttestReadiness
	err   error
}

func (s *authorizationBatchStore) GetAppAttestReadinessBatch(context.Context, []string) (map[string]store.AppAttestReadiness, error) {
	return s.state, s.err
}

func newAuthorizationFixture(t *testing.T) (*Server, *registry.Provider, *appAttestAuthorizationRecord, store.AppAttestReadiness) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	r := registry.New(logger)
	r.SetAppAttestServingPolicy(true, 7)
	key := base64.StdEncoding.EncodeToString(make([]byte, 32))
	p := r.Register("connection", nil, &protocol.RegisterMessage{PublicKey: key, Backend: registry.BackendMLXSwift, EncryptedResponseChunks: true, Hardware: protocol.Hardware{MachineModel: "Mac16,10", MemoryGB: 32}})
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
	s := &Server{registry: r, store: store.NewMemory(store.Config{}), logger: logger, appAttestShadow: AppAttestShadowConfig{ServingEnabled: true, MDMRemovalEnabled: true, Environment: "production"}}
	s.releaseTrustPolicy.Store(&releaseTrustPolicySnapshot{Generation: 7, ByBinaryHash: map[string][]approvedReleasePolicy{strings.Repeat("a", 64): {{Version: "0.9.4", Platform: "macos-arm64", MetallibHash: strings.Repeat("b", 64)}}}})
	s.appAttestAuthorizer = &appAttestAuthorizer{s: s, current: map[*registry.Provider]*appAttestAuthorizationRecord{}}
	now := time.Now().UTC()
	category := uint32(6)
	binding := appattest.AuthorizationBinding{Account: "account", Machine: "machine", Credential: "credential", Connection: "proof", Endpoint: key, AppID: "TEST.app", Environment: "production"}
	e := appattest.AuthorizationEvidence{Binding: binding, Expected: binding, ProtocolVersion: 3, CredentialVerified: true, EndpointBound: true, AssertionAt: now,
		ValidationCategory: &category, ReportedVersion: "0.9.4", CatalogKnown: true, BuildMatched: true, BuildQualified: true,
		CodeMeasurementKnown: true, CodeMeasurementMatched: true, VerificationKeyKnown: true, VerificationKeyMatched: true,
		HardwareKnown: true, HardwareMatched: true, ArchiveComplete: true, RenewalConfigured: true}
	record := &appAttestAuthorizationRecord{evidence: e, status: protocol.AppAttestStatus{BinaryHash: strings.Repeat("a", 64), AppVersion: "0.9.4", AttestationPublicKey: "se", MachineModel: "Mac16,10", MemoryGB: "32"}, proofSession: "proof"}
	state := store.AppAttestReadiness{Receipt: &store.AppAttestReceipt{Outcome: "verified", Details: json.RawMessage(`{"risk_metric":1}`), ExpiresAt: now.Add(time.Hour), NextAt: now.Add(30 * time.Minute)}}
	t.Cleanup(func() { r.Disconnect(p.ID) })
	return s, p, record, state
}

func TestAppAttestAuthorizerBoundsRevocationSnapshotAndAssertion(t *testing.T) {
	s, p, record, state := newAuthorizationFixture(t)
	a := s.appAttestAuthorizer
	observed := time.Now().Add(-10 * time.Second)
	if !a.apply(p, record, state, observed) {
		t.Fatal("valid policy not granted")
	}
	lease := p.GetAppAttestServingAuthorization()
	if !lease.ValidUntil.Equal(observed.Add(appAttestRevocationFreshness)) {
		t.Fatal("snapshot age extended")
	}
	if status := s.providerServingAuthorizationStatus(p); status.Path != "app_attest" || !status.MDMRemovalReady {
		t.Fatalf("readiness %+v", status)
	}
	// Fresh receipt/revocation reads cannot extend an old assertion.
	record.evidence.AssertionAt = time.Now().Add(-appattest.AssertionFreshness + 2*time.Second)
	if !a.apply(p, record, state, time.Now()) {
		t.Fatal("freshness margin rejected")
	}
	if got := p.GetAppAttestServingAuthorization().ValidUntil; !got.Equal(record.evidence.AssertionAt.Add(appattest.AssertionFreshness)) {
		t.Fatal("assertion extended")
	}
	if a.apply(p, record, state, time.Now().Add(-appAttestRevocationFreshness-time.Second)) {
		t.Fatal("stale revocation snapshot granted")
	}
}

func TestAppAttestAuthorizerRefreshFailureDoesNotExtendAndRevocationFences(t *testing.T) {
	s, p, record, state := newAuthorizationFixture(t)
	a := s.appAttestAuthorizer
	st := &authorizationBatchStore{Store: s.store, state: map[string]store.AppAttestReadiness{"credential": state}}
	s.store = st
	a.remember(p, record)
	a.refresh(context.Background())
	before := p.GetAppAttestServingAuthorization()
	if before.CredentialID == "" {
		t.Fatal("no initial lease")
	}
	st.err = errors.New("database unavailable")
	a.refresh(context.Background())
	if !p.GetAppAttestServingAuthorization().ValidUntil.Equal(before.ValidUntil) {
		t.Fatal("outage extended authorization")
	}
	st.err = nil
	st.state["credential"] = store.AppAttestReadiness{Revoked: true}
	a.refresh(context.Background())
	if _, valid := s.registry.ProviderServingAuthorization(p); valid {
		t.Fatal("revoked credential active")
	}
	if a.apply(p, record, state, time.Now()) {
		t.Fatal("late nonrevoked snapshot undid revocation")
	}
}

func TestAppAttestAuthorizerRejectsMissingPolicyAndArchive(t *testing.T) {
	for _, mode := range []string{"unqualified", "missing_code", "archive_gap", "catalog_changed", "expired_receipt"} {
		t.Run(mode, func(t *testing.T) {
			s, p, record, state := newAuthorizationFixture(t)
			switch mode {
			case "unqualified":
				record.evidence.BuildQualified = false
			case "missing_code":
				record.evidence.CodeMeasurementKnown = false
			case "archive_gap":
				record.dropped = func() uint64 { return 1 }
			case "catalog_changed":
				s.releaseTrustPolicy.Store(&releaseTrustPolicySnapshot{Generation: 8, ByBinaryHash: map[string][]approvedReleasePolicy{"other": {{Version: "0.9.4", Platform: "macos-arm64"}}}})
			case "expired_receipt":
				state.Receipt.ExpiresAt = time.Now().Add(-time.Second)
			}
			if s.appAttestAuthorizer.apply(p, record, state, time.Now()) {
				t.Fatal("incomplete/negative evidence authorized")
			}
			if s.providerServingAuthorizationStatus(p).MDMRemovalReady {
				t.Fatal("offered unsafe removal")
			}
		})
	}
}

func TestAppAttestServingAndRemovalAreIndependentOptIns(t *testing.T) {
	t.Setenv("EIGENINFERENCE_APP_ATTEST_SERVING", "false")
	t.Setenv("EIGENINFERENCE_APP_ATTEST_MDM_REMOVAL", "false")
	if c := readAppAttestShadowConfig(); c.ServingEnabled || c.MDMRemovalEnabled {
		t.Fatal("default legacy behavior changed")
	}
	s, p, record, state := newAuthorizationFixture(t)
	s.appAttestShadow.MDMRemovalEnabled = false
	if !s.appAttestAuthorizer.apply(p, record, state, time.Now()) {
		t.Fatal("serving depends on migration switch")
	}
	if v := s.providerServingAuthorizationStatus(p); v.Path != "app_attest" || v.MDMRemovalReady {
		t.Fatal("migration switch ineffective")
	}
	for _, reason := range []string{"apple_invalid_key", "keychain_error", "timeout", "authenticator_trailing_data", "storage_error"} {
		if confirmedAppAttestViolation(reason) {
			t.Fatalf("recovery classified as tamper: %s", reason)
		}
	}
	for _, reason := range []string{"signature", "mac_acl", "nonce"} {
		if !confirmedAppAttestViolation(reason) {
			t.Fatalf("hard violation ignored: %s", reason)
		}
	}
}

func TestAppAttestAdminRevocationOwnershipAndIdempotency(t *testing.T) {
	s, p, record, state := newAuthorizationFixture(t)
	s.adminKey = "admin-secret"
	keys, _ := store.As[store.AppAttestShadowStore](s.store)
	_, err := keys.InsertAppAttestShadowKey(context.Background(), store.AppAttestShadowKey{KeyID: "credential", AccountID: "account"})
	if err != nil {
		t.Fatal(err)
	}
	if !s.appAttestAuthorizer.apply(p, record, state, time.Now()) {
		t.Fatal("grant")
	}
	call := func(account, token string) int {
		r := httptest.NewRequest(http.MethodPost, "/v1/admin/app-attest/revoke", strings.NewReader(`{"key_id":"credential","account_id":"`+account+`","reason":"operator_revoked"}`))
		r.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		s.handleAdminAppAttestRevoke(w, r)
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

func TestAppAttestAuthorizerRevalidatesMetalLibraryAndBackend(t *testing.T) {
	for _, mode := range []string{"metallib", "backend", "verification_key", "runtime"} {
		t.Run(mode, func(t *testing.T) {
			s, p, record, state := newAuthorizationFixture(t)
			if !s.appAttestAuthorizer.apply(p, record, state, time.Now()) {
				t.Fatal("initial grant")
			}
			snapshot := &releaseTrustPolicySnapshot{Generation: 8, ByBinaryHash: map[string][]approvedReleasePolicy{strings.Repeat("a", 64): {{Version: "0.9.4", Platform: "macos-arm64", MetallibHash: strings.Repeat("b", 64)}}}}
			switch mode {
			case "metallib":
				snapshot.ByBinaryHash[strings.Repeat("a", 64)][0].MetallibHash = strings.Repeat("c", 64)
			case "backend":
				snapshot.ByBinaryHash[strings.Repeat("a", 64)][0].Backend = "other"
			case "verification_key":
				record.status.AttestationPublicKey = "other"
			case "runtime":
				p.MetallibVerified = false
			}
			s.publishReleaseTrustPolicy(snapshot)
			if s.appAttestAuthorizer.apply(p, record, state, time.Now()) {
				t.Fatal("stale runtime reapproved")
			}
		})
	}
}

func TestAppAttestSignedNegativeCannotFallbackToLegacy(t *testing.T) {
	s, p, record, state := newAuthorizationFixture(t)
	if !s.appAttestAuthorizer.apply(p, record, state, time.Now()) {
		t.Fatal("grant")
	}
	p.SetAttested(true, registry.TrustHardware)
	p.CodeAttested = true
	p.ChallengeVerifiedSIP = true
	p.SetLastChallengeVerified(time.Now())
	if !s.registry.ProviderLegacyServingAuthorized(p) {
		t.Fatal("legacy fixture")
	}
	x := &appAttestShadowSession{s: s, provider: p, protocolVersion: 3}
	x.updateServingAuthorization(&record.status, record.evidence, appattest.AuthorizationVerdict{Outcome: "ineligible", Reasons: []string{"apple_code_measurement_mismatch"}})
	if p.GetStatus() != registry.StatusUntrusted || s.registry.ProviderLegacyServingAuthorized(p) {
		t.Fatal("signed negative bypassed by legacy")
	}
}

func TestAppAttestPublicAuthorizationDoesNotExposePrivateIdentity(t *testing.T) {
	s, p, record, state := newAuthorizationFixture(t)
	if !s.appAttestAuthorizer.apply(p, record, state, time.Now()) {
		t.Fatal("grant")
	}
	w := httptest.NewRecorder()
	s.handleProviderAttestation(w, httptest.NewRequest(http.MethodGet, "/v1/providers/attestation", nil))
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
	s, p, _, _ := newAuthorizationFixture(t)
	s.registry.SetStore(s.store)
	if err := s.store.UpsertProvider(context.Background(), store.ProviderRecord{ID: "other-history", SEPublicKey: "se", AccountID: "previous-owner", LastSeen: time.Now(), LifetimeTokensGenerated: 99}); err != nil {
		t.Fatal(err)
	}
	if err := s.restorePersistedProviderState(context.Background(), p, "", "se", "account"); err != nil {
		t.Fatal(err)
	}
	if p.AccountID != "account" || p.Stats.TokensGenerated != 0 {
		t.Fatal("inherited another account history")
	}
}
