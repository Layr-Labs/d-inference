package service

import (
	"context"
	"errors"
	"strings"
	"testing"
	"testing/synctest"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

type failingBuildStore struct{ *store.MemoryStore }

func (*failingBuildStore) ListAppAttestBuildQualifications(context.Context) ([]store.AppAttestBuildQualification, error) {
	return nil, errors.New("unavailable")
}

func TestBuildQualificationRevocationFencesCachedEvidenceAndLateGrant(t *testing.T) {
	s, p, record, readiness := newAuthorizationFixture(t)
	if !s.authorizer.apply(p, record, readiness, time.Now()) {
		t.Fatal("initial legacy-env grant")
	}
	old := p.GetAppAttestServingAuthorization()
	st, _ := store.As[store.AppAttestBuildStore](s.store)
	if _, err := st.RevokeAppAttestBuild(context.Background(), record.status.BinaryHash, "operator", "withdraw build"); err != nil {
		t.Fatal(err)
	}
	s.FenceBuild(record.status.BinaryHash)
	if s.registry.GrantAppAttestServingAuthorization(p, old) {
		t.Fatal("old generation raced past revocation")
	}
	if s.authorizer.apply(p, record, readiness, time.Now()) {
		t.Fatal("cached match booleans resurrected withdrawn build")
	}
	if err := s.RefreshBuildQualifications(context.Background()); err != nil {
		t.Fatal(err)
	}
	if s.authorizer.apply(p, record, readiness, time.Now()) {
		t.Fatal("env compatibility overrode durable revocation")
	}
}

func TestBuildQualificationStoreOutageCannotExtendLease(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		s, p, record, readiness := newAuthorizationFixture(t)
		if !s.authorizer.apply(p, record, readiness, time.Now()) {
			t.Fatal("initial grant")
		}
		deadline := p.GetAppAttestServingAuthorization().ValidUntil
		s.store = &failingBuildStore{store.NewMemory(store.Config{})}
		time.Sleep(20 * time.Second)
		if s.RefreshBuildQualifications(context.Background()) == nil {
			t.Fatal("hidden database outage")
		}
		if !s.authorizer.apply(p, record, readiness, time.Now()) || !p.GetAppAttestServingAuthorization().ValidUntil.Equal(deadline) {
			t.Fatal("fresh receipt read extended stale qualification")
		}
		time.Sleep(11 * time.Second)
		if s.authorizer.apply(p, record, readiness, time.Now()) {
			t.Fatal("expired qualification granted")
		}
		if _, ok := s.registry.ProviderServingAuthorization(p); ok {
			t.Fatal("expired qualification still dispatchable")
		}
	})
}

func TestDurableBuildQualificationHotReloadAndRestart(t *testing.T) {
	s, p, record, readiness := newAuthorizationFixture(t)
	s.config.QualifiedBuildHashes, s.config.QualifiedCodeHashes = "", ""
	if s.authorizer.apply(p, record, readiness, time.Now()) {
		t.Fatal("missing durable approval granted")
	}
	q := store.AppAttestBuildQualification{AppAttestBuildIdentity: store.AppAttestBuildIdentity{
		Release: store.Release{Version: record.status.AppVersion, Platform: "macos-arm64", Backend: "mlx-swift", BinaryHash: record.status.BinaryHash,
			BundleHash: strings.Repeat("b", 64), MetallibHash: strings.Repeat("d", 64), URL: "https://example.com/bundle"},
		CodeDirectoryHash: record.evidence.CodeDirectoryHash, SourceCommit: strings.Repeat("f", 40), CIRunID: "123"}, Evidence: "physical transition tests", ApprovedBy: "operator"}
	st, _ := store.As[store.AppAttestBuildStore](s.store)
	if _, err := st.QualifyAppAttestBuild(context.Background(), q); err != nil {
		t.Fatal(err)
	}
	if err := s.RefreshBuildQualifications(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !s.BuildReady(q.AppAttestBuildIdentity) || !s.authorizer.apply(p, record, readiness, time.Now()) {
		t.Fatal("hot approval did not authorize existing verified evidence")
	}
	generation := p.GetAppAttestServingAuthorization().QualificationGeneration
	if err := s.RefreshBuildQualifications(context.Background()); err != nil {
		t.Fatal(err)
	}
	if p.GetAppAttestServingAuthorization().QualificationGeneration != generation {
		t.Fatal("unchanged poll churned grants")
	}
	// The next decision uses the actual Apple measurement, not a prior true bool.
	record.evidence.CodeDirectoryHash = strings.Repeat("e", 64)
	if s.authorizer.apply(p, record, readiness, time.Now()) {
		t.Fatal("wrong current Apple code measurement accepted")
	}
	fresh := New(context.Background(), Config{}, Dependencies{Store: s.store})
	if err := fresh.RefreshBuildQualifications(context.Background()); err != nil || !fresh.BuildReady(q.AppAttestBuildIdentity) {
		t.Fatalf("restart lost approval: %v", err)
	}
}
