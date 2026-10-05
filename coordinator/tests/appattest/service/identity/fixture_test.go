package identity_test

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
	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/authorization"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/qualification"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	memorystore "github.com/eigeninference/d-inference/coordinator/store/memory"
)

type identityFixture struct {
	registry       *registry.Registry
	authorizer     *authorization.Controller
	store          store.Store
	qualifications qualification.Cache
	evidence       appattest.AuthorizationEvidence
	status         protocol.AppAttestStatus
	bootstrap      qualification.Bootstrap
	observe        func(string, string)
	notify         func(*registry.Provider)
	notifications  *authorization.Outbox
}

func newAuthorizationFixture(t *testing.T) (*identityFixture, *registry.Provider, *authorization.Record, store.AppAttestReadiness) {
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
	f := &identityFixture{registry: r, store: &statusReadinessStore{MemoryStore: memorystore.NewMemory(store.Config{})}, bootstrap: qualification.Bootstrap{BuildHashes: strings.Repeat("a", 64), CodeHashes: strings.Repeat("a", 64) + ":" + strings.Repeat("c", 64)}}
	if err := f.RefreshBuildQualifications(context.Background()); err != nil {
		t.Fatal(err)
	}
	f.authorizer = f.newAuthorizer()
	now := time.Now().UTC()
	category := uint32(6)
	binding := appattest.AuthorizationBinding{Account: "account", Machine: "machine", Credential: "credential", Connection: "proof", Endpoint: key, AppID: "TEST.app", Environment: "production"}
	f.evidence = appattest.AuthorizationEvidence{CodeDirectoryHash: strings.Repeat("c", 64), Binding: binding, Expected: binding, ProtocolVersion: 3, CredentialVerified: true, EndpointBound: true, AssertionAt: now,
		ValidationCategory: &category, ReportedVersion: "0.9.4", CatalogKnown: true, BuildMatched: true, BuildQualified: true,
		CodeMeasurementKnown: true, CodeMeasurementMatched: true, VerificationKeyKnown: true, VerificationKeyMatched: true,
		HardwareKnown: true, HardwareMatched: true, ArchiveComplete: true, RenewalConfigured: true}
	f.status = protocol.AppAttestStatus{BinaryHash: strings.Repeat("a", 64), AppVersion: "0.9.4", AttestationPublicKey: "se", MachineModel: "Mac16,10", MemoryGB: "32"}
	state := store.AppAttestReadiness{Receipt: &store.AppAttestReceipt{Outcome: "verified", Details: json.RawMessage(`{"risk_metric":1}`), ExpiresAt: now.Add(time.Hour), NextAt: now.Add(30 * time.Minute)}}
	f.store.(*statusReadinessStore).state = state
	t.Cleanup(func() { r.Disconnect(p.ID) })
	return f, p, authorization.NewRecord(f.evidence, f.status, "proof", nil, 0), state
}

func (f *identityFixture) newAuthorizer() *authorization.Controller {
	return authorization.New(authorization.Dependencies{
		Registry: f.registry,
		Readiness: func() store.AppAttestReadinessBatchStore {
			st, _ := store.As[store.AppAttestReadinessBatchStore](f.store)
			return st
		},
		ReleasePolicy: func() *authorization.ReleasePolicy {
			return &authorization.ReleasePolicy{Generation: 7, Known: true, ContainsQualifiedRelease: func(store.Release) bool { return true }, Approves: func(_ *registry.Provider, status *protocol.AppAttestStatus) bool {
				return status != nil && status.BinaryHash == strings.Repeat("a", 64) && status.AppVersion == "0.9.4"
			}}
		},
		Qualify: func(e *appattest.AuthorizationEvidence, status *protocol.AppAttestStatus, policy *authorization.ReleasePolicy) (uint64, time.Time) {
			var catalog *qualification.Catalog
			if policy != nil {
				catalog = &qualification.Catalog{Known: policy.Known, ContainsQualifiedRelease: policy.ContainsQualifiedRelease}
			}
			return f.qualifications.Apply(e, status, catalog, f.bootstrap)
		},
		Revoke: f.RevokeCredential,
		Notify: func(p *registry.Provider) {
			if f.notify != nil {
				f.notify(p)
			}
		},
		Notifications: f.notifications,
	})
}

func (f *identityFixture) RefreshBuildQualifications(ctx context.Context) error {
	st, _ := store.As[store.AppAttestBuildStore](f.store)
	return f.qualifications.Refresh(ctx, st, f.registry.SetAppAttestQualificationGeneration)
}

func (f *identityFixture) RevokeCredential(key string) { f.authorizer.Revoke(key) }

func (f *identityFixture) proof(e appattest.AuthorizationEvidence) authorization.VerifiedProof {
	return authorization.NewVerifiedProof(e, &f.status, "proof", nil, 0)
}

func identityForAuthorization(f *identityFixture, p *registry.Provider, inventory authorization.Inventory) *authorization.Identity {
	return authorization.NewIdentity(authorization.IdentityDependencies{
		Controller: f.authorizer, Registry: f.registry, Inventory: inventory,
		Operational: func() store.MachineOperationalStore {
			st, _ := store.As[store.MachineOperationalStore](f.store)
			return st
		},
		Recovery: func() store.MachineContinuityRecoveryStore {
			st, _ := store.As[store.MachineContinuityRecoveryStore](f.store)
			return st
		},
		Readiness: func() store.AppAttestReadinessStore {
			st, _ := store.As[store.AppAttestReadinessStore](f.store)
			return st
		},
		Observe: func(stage, outcome string) {
			if f.observe != nil {
				f.observe(stage, outcome)
			}
		},
	}, p, f.evidence.Binding.Account)
}

type statusReadinessStore struct {
	*memorystore.MemoryStore
	state store.AppAttestReadiness
}

func (s *statusReadinessStore) GetAppAttestReadiness(context.Context, string) (store.AppAttestReadiness, error) {
	return s.state, nil
}
func (s *statusReadinessStore) ResolveMachineContinuity(context.Context, string, string, string, []string) (store.MachineContinuity, error) {
	return store.MachineContinuity{Machine: store.MachineIdentity{ID: "machine", Assurance: "key_bound"}}, nil
}

type authorizationBatchStore struct {
	store.Store
	state map[string]store.AppAttestReadiness
	err   error
}

func (s *authorizationBatchStore) GetAppAttestReadinessBatch(context.Context, []string) (map[string]store.AppAttestReadiness, error) {
	return s.state, s.err
}
