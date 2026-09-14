package api

import (
	"context"
	"github.com/eigeninference/d-inference/coordinator/providercontrol/codeidentity"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"strings"
	"testing"
	"time"
)

func TestCodeCoverageSweepDisconnectAndClose(t *testing.T) {
	st := store.NewMemory(store.Config{})
	srv := NewServer(registry.New(quietLogger()), st, ServerConfig{}, quietLogger())
	now := time.Date(2026, 9, 8, 0, 0, 0, 0, time.UTC)
	cfg := codeidentity.DefaultConfig()
	cfg.Now = func() time.Time { return now }
	configureCodeIdentityFixture(srv, cfg)
	p := newTrustReuseProvider(t, srv, "coverage-p", "coverage-se", "serial")
	p.Mu().Lock()
	p.Version = "0.9.0"
	p.APNsDeviceToken = "token"
	p.Status = registry.StatusOnline
	p.TrustLevel = registry.TrustHardware
	p.CodeAttested = true
	p.FreshCodeAttested = true
	p.AttestationResult.BinaryHash = strings.Repeat("a", 64)
	p.Mu().Unlock()
	proof := store.CodeAttestation{SEPubKey: "coverage-se", Version: p.Version,
		APNsToken: p.APNsDeviceToken, NodePublicKey: p.PublicKey, BinaryHash: p.AttestationResult.BinaryHash,
		AttestedAt: now}
	seedCodeIdentityProof(t, srv, proof)
	check := func(want time.Time) {
		t.Helper()
		rows, _ := st.ListCodeAttestations(context.Background())
		if len(rows) != 1 || rows[0].ContinuousCoverageUntil == nil || !rows[0].ContinuousCoverageUntil.Equal(want) {
			t.Fatalf("coverage=%+v want=%s", rows, want)
		}
	}
	now = now.Add(time.Hour)
	srv.sweepCodeAttestCoverage()
	check(now)
	lastSweep := now
	now = now.Add(25 * time.Second)
	// providerReadLoop marks the dead socket offline before deferred cleanup.
	p.Mu().Lock()
	p.Status = registry.StatusOffline
	p.Mu().Unlock()
	srv.sweepCodeAttestCoverage()
	check(lastSweep) // periodic sweeps must never keep offline evidence alive
	srv.stopCodeAttestCoverageForProvider(p.ID)
	check(now)
	disconnectedAt := now
	rows, err := st.ListCodeAttestations(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	for _, gap := range []time.Duration{100 * time.Second, 120 * time.Second, 121 * time.Second} {
		fixtureStore := store.NewMemory(store.Config{})
		for _, row := range rows {
			if err := fixtureStore.UpsertCodeAttestation(context.Background(), row); err != nil {
				t.Fatal(err)
			}
		}
		cfg := codeidentity.DefaultConfig()
		cfg.Now = func() time.Time { return disconnectedAt.Add(gap) }
		th := codeidentity.New(cfg, srv.codeIdentityDependencies())
		th.Seed(context.Background(), fixtureStore)
		if got := th.ReuseBasis("coverage-se", p.Version, p.APNsDeviceToken, p.PublicKey) != ""; got != (gap <= 120*time.Second) {
			t.Fatalf("reuse after disconnect gap %s = %v", gap, got)
		}
	}
	// Graceful server shutdown still stamps connections that remain online.
	p.Mu().Lock()
	p.Status = registry.StatusOnline
	p.Mu().Unlock()
	now = now.Add(10 * time.Second)
	srv.Close()
	check(now)
}
