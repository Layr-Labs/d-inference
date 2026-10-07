package authorization_test

import (
	"context"
	"errors"
	"strings"
	"testing"
	"testing/synctest"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest/service"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/authorization"
	"github.com/eigeninference/d-inference/coordinator/store"
	memorystore "github.com/eigeninference/d-inference/coordinator/store/memory"
)

type failingBuildStore struct{ *memorystore.MemoryStore }

func (*failingBuildStore) ListAppAttestBuildQualifications(context.Context) ([]store.AppAttestBuildQualification, error) {
	return nil, errors.New("unavailable")
}

func TestBuildQualificationRevocationFencesCachedEvidenceAndLateGrant(t *testing.T) {
	f, p, record, readiness := newAuthorizationFixture(t, true)
	if !f.controller.Apply(p, record, readiness, time.Now()) {
		t.Fatal("initial legacy-env grant")
	}
	old := p.GetAppAttestServingAuthorization()
	st, _ := store.As[store.AppAttestBuildStore](f.store)
	if _, err := st.RevokeAppAttestBuild(context.Background(), f.status.BinaryHash, "operator", "withdraw build"); err != nil {
		t.Fatal(err)
	}
	f.cache.FenceBuild(f.status.BinaryHash, f.registry.SetAppAttestQualificationGeneration)
	if f.registry.GrantAppAttestServingAuthorization(p, old) {
		t.Fatal("old generation raced past revocation")
	}
	if f.controller.Apply(p, record, readiness, time.Now()) {
		t.Fatal("cached match booleans resurrected withdrawn build")
	}
	if err := f.cache.Refresh(context.Background(), st, f.registry.SetAppAttestQualificationGeneration); err != nil {
		t.Fatal(err)
	}
	if f.controller.Apply(p, record, readiness, time.Now()) {
		t.Fatal("env compatibility overrode durable revocation")
	}
}

func TestBuildQualificationStoreOutageCannotExtendLease(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		f, p, record, readiness := newAuthorizationFixture(t, true)
		if !f.controller.Apply(p, record, readiness, time.Now()) {
			t.Fatal("initial grant")
		}
		deadline := p.GetAppAttestServingAuthorization().ValidUntil
		st := &failingBuildStore{memorystore.NewMemory(store.Config{})}
		time.Sleep(20 * time.Second)
		if f.cache.Refresh(context.Background(), st, f.registry.SetAppAttestQualificationGeneration) == nil {
			t.Fatal("hidden database outage")
		}
		if !f.controller.Apply(p, record, readiness, time.Now()) || !p.GetAppAttestServingAuthorization().ValidUntil.Equal(deadline) {
			t.Fatal("fresh receipt read extended stale qualification")
		}
		time.Sleep(11 * time.Second)
		if f.controller.Apply(p, record, readiness, time.Now()) {
			t.Fatal("expired qualification granted")
		}
		if _, ok := f.registry.ProviderServingAuthorization(p); ok {
			t.Fatal("expired qualification still dispatchable")
		}
	})
}

func TestDurableBuildQualificationHotReloadAndRestart(t *testing.T) {
	f, p, record, readiness := newAuthorizationFixture(t, true)
	f.bootstrap.BuildHashes, f.bootstrap.CodeHashes = "", ""
	if f.controller.Apply(p, record, readiness, time.Now()) {
		t.Fatal("missing durable approval granted")
	}
	q := store.AppAttestBuildQualification{AppAttestBuildIdentity: store.AppAttestBuildIdentity{
		Release: store.Release{Version: f.status.AppVersion, Platform: "macos-arm64", Backend: "mlx-swift", BinaryHash: f.status.BinaryHash,
			BundleHash: strings.Repeat("b", 64), MetallibHash: strings.Repeat("d", 64), URL: "https://example.com/bundle"},
		CodeDirectoryHash: f.evidence.CodeDirectoryHash, SourceCommit: strings.Repeat("f", 40), CIRunID: "123"}, Evidence: "physical transition tests", ApprovedBy: "operator"}
	st, _ := store.As[store.AppAttestBuildStore](f.store)
	if _, err := st.QualifyAppAttestBuild(context.Background(), q); err != nil {
		t.Fatal(err)
	}
	if err := f.cache.Refresh(context.Background(), st, f.registry.SetAppAttestQualificationGeneration); err != nil {
		t.Fatal(err)
	}
	if !f.cache.BuildReady(q.AppAttestBuildIdentity) || !f.controller.Apply(p, record, readiness, time.Now()) {
		t.Fatal("hot approval did not authorize existing verified evidence")
	}
	generation := p.GetAppAttestServingAuthorization().QualificationGeneration
	if err := f.cache.Refresh(context.Background(), st, f.registry.SetAppAttestQualificationGeneration); err != nil {
		t.Fatal(err)
	}
	if p.GetAppAttestServingAuthorization().QualificationGeneration != generation {
		t.Fatal("unchanged poll churned grants")
	}
	// The next decision uses the actual Apple measurement, not a prior true bool.
	f.evidence.CodeDirectoryHash = strings.Repeat("e", 64)
	record = authorization.NewRecord(f.evidence, f.status, "proof", nil, 0)
	if f.controller.Apply(p, record, readiness, time.Now()) {
		t.Fatal("wrong current Apple code measurement accepted")
	}
	fresh := service.New(context.Background(), service.Config{}, service.Dependencies{Store: f.store})
	if err := fresh.RefreshBuildQualifications(context.Background()); err != nil || !fresh.BuildReady(q.AppAttestBuildIdentity) {
		t.Fatalf("restart lost approval: %v", err)
	}
}
