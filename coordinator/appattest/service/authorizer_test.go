package service

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
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

func newAuthorizationFixture(t *testing.T) (*Service, *registry.Provider, *appAttestAuthorizationRecord, store.AppAttestReadiness) {
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
	s := &Service{registry: r, store: store.NewMemory(store.Config{}), logger: logger, config: Config{ServingEnabled: true, MDMRemovalEnabled: true, Environment: "production"}}
	s.currentReleasePolicy = func() ReleasePolicy {
		return ReleasePolicy{Generation: 7, Known: true, Approves: func(_ *registry.Provider, status *protocol.AppAttestStatus) bool {
			return status != nil && status.BinaryHash == strings.Repeat("a", 64) && status.AppVersion == "0.9.4"
		}}
	}
	s.authorizer = &authorizer{s: s, current: map[*registry.Provider]*appAttestAuthorizationRecord{}}
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
	a := s.authorizer
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
	a := s.authorizer
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
				s.currentReleasePolicy = func() ReleasePolicy {
					return ReleasePolicy{Generation: 8, Known: true, Approves: func(*registry.Provider, *protocol.AppAttestStatus) bool { return false }}
				}
			case "expired_receipt":
				state.Receipt.ExpiresAt = time.Now().Add(-time.Second)
			}
			if s.authorizer.apply(p, record, state, time.Now()) {
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
	if c := ConfigFromEnvironment(); c.ServingEnabled || c.MDMRemovalEnabled {
		t.Fatal("default legacy behavior changed")
	}
	s, p, record, state := newAuthorizationFixture(t)
	s.config.MDMRemovalEnabled = false
	if !s.authorizer.apply(p, record, state, time.Now()) {
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

func TestAppAttestSignedNegativeCannotFallbackToLegacy(t *testing.T) {
	s, p, record, state := newAuthorizationFixture(t)
	if !s.authorizer.apply(p, record, state, time.Now()) {
		t.Fatal("grant")
	}
	p.SetAttested(true, registry.TrustHardware)
	p.CodeAttested = true
	p.ChallengeVerifiedSIP = true
	p.SetLastChallengeVerified(time.Now())
	if !s.registry.ProviderLegacyServingAuthorized(p) {
		t.Fatal("legacy fixture")
	}
	x := &Session{s: s, provider: p, protocolVersion: 3}
	x.updateServingAuthorization(&record.status, record.evidence, appattest.AuthorizationVerdict{Outcome: "ineligible", Reasons: []string{"apple_code_measurement_mismatch"}})
	if p.GetStatus() != registry.StatusUntrusted || s.registry.ProviderLegacyServingAuthorized(p) {
		t.Fatal("signed negative bypassed by legacy")
	}
}
