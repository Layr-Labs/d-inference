package authorization_test

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/appattest/service"
	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/authorization"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/qualification"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	memorystore "github.com/eigeninference/d-inference/coordinator/store/memory"
)

type authorizationBatchStore struct {
	store.Store
	state map[string]store.AppAttestReadiness
	err   error
}

func (s *authorizationBatchStore) GetAppAttestReadinessBatch(context.Context, []string) (map[string]store.AppAttestReadiness, error) {
	return s.state, s.err
}

type authorizationFixture struct {
	service    *service.Service
	controller *authorization.Controller
	registry   *registry.Registry
	store      *memorystore.MemoryStore
	readiness  store.AppAttestReadinessBatchStore
	policy     func() *authorization.ReleasePolicy
	bootstrap  qualification.Bootstrap
	cache      qualification.Cache
	evidence   appattest.AuthorizationEvidence
	status     protocol.AppAttestStatus
}

func newAuthorizationFixture(t *testing.T, removalEnabled bool) (*authorizationFixture, *registry.Provider, *authorization.Record, store.AppAttestReadiness) {
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
	f := &authorizationFixture{registry: r, store: memorystore.NewMemory(store.Config{})}
	f.readiness = f.store
	f.policy = func() *authorization.ReleasePolicy {
		return &authorization.ReleasePolicy{Generation: 7, Known: true, ContainsQualifiedRelease: func(store.Release) bool { return true }, Approves: func(_ *registry.Provider, status *protocol.AppAttestStatus) bool {
			return status != nil && status.BinaryHash == strings.Repeat("a", 64) && status.AppVersion == "0.9.4"
		}}
	}
	f.bootstrap = qualification.Bootstrap{BuildHashes: strings.Repeat("a", 64), CodeHashes: strings.Repeat("a", 64) + ":" + strings.Repeat("c", 64)}
	if err := f.cache.Refresh(context.Background(), f.store, r.SetAppAttestQualificationGeneration); err != nil {
		t.Fatal(err)
	}
	f.controller = authorization.New(authorization.Dependencies{
		Registry:      r,
		Readiness:     func() store.AppAttestReadinessBatchStore { return f.readiness },
		ReleasePolicy: func() *authorization.ReleasePolicy { return f.policy() },
		Qualify: func(e *appattest.AuthorizationEvidence, status *protocol.AppAttestStatus, policy *authorization.ReleasePolicy) (uint64, time.Time) {
			var catalog *qualification.Catalog
			if policy != nil {
				catalog = &qualification.Catalog{Known: policy.Known, ContainsQualifiedRelease: policy.ContainsQualifiedRelease}
			}
			return f.cache.Apply(e, status, catalog, f.bootstrap)
		},
		Revoke: func(key string) { f.controller.Revoke(key) },
	})
	f.service = service.New(context.Background(), service.Config{ServingEnabled: true, MDMRemovalEnabled: removalEnabled, Environment: "production"}, service.Dependencies{
		Store: f.store, Registry: r, Logger: logger,
		CurrentReleasePolicy: func() service.ReleasePolicy { return *f.policy() },
	})
	now := time.Now().UTC()
	category := uint32(6)
	binding := appattest.AuthorizationBinding{Account: "account", Machine: "machine", Credential: "credential", Connection: "proof", Endpoint: key, AppID: "TEST.app", Environment: "production"}
	f.evidence = appattest.AuthorizationEvidence{CodeDirectoryHash: strings.Repeat("c", 64), Binding: binding, Expected: binding, ProtocolVersion: 3, CredentialVerified: true, EndpointBound: true, AssertionAt: now,
		ValidationCategory: &category, ReportedVersion: "0.9.4", CatalogKnown: true, BuildMatched: true, BuildQualified: true,
		CodeMeasurementKnown: true, CodeMeasurementMatched: true, VerificationKeyKnown: true, VerificationKeyMatched: true,
		HardwareKnown: true, HardwareMatched: true, ArchiveComplete: true, RenewalConfigured: true}
	f.status = protocol.AppAttestStatus{BinaryHash: strings.Repeat("a", 64), AppVersion: "0.9.4", AttestationPublicKey: "se", MachineModel: "Mac16,10", MemoryGB: "32"}
	record := authorization.NewRecord(f.evidence, f.status, "proof", nil, 0)
	state := store.AppAttestReadiness{Receipt: &store.AppAttestReceipt{Outcome: "verified", Details: json.RawMessage(`{"risk_metric":1}`), ExpiresAt: now.Add(time.Hour), NextAt: now.Add(30 * time.Minute)}}
	t.Cleanup(func() { r.Disconnect(p.ID) })
	return f, p, record, state
}
