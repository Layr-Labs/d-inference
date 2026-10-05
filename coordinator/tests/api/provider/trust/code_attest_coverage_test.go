package trust_test

import (
	"context"
	"strings"
	"testing"
	"time"

	production "github.com/eigeninference/d-inference/coordinator/api/provider/trust"

	identitystate "github.com/eigeninference/d-inference/coordinator/internal/provider/identity/state"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestCodeContinuityResumeStillRequiresLiveProcessProof(t *testing.T) {
	ctx := context.Background()
	st := store.NewCached(memory.NewMemory(store.Config{}), store.DefaultCacheConfig())
	old := newTrustFixture(t, production.Dependencies{Registry: registry.New(quietLogger()), Store: st, Logger: quietLogger()}, production.Config{})
	t.Cleanup(old.Close)
	now := time.Date(2026, 9, 8, 0, 0, 0, 0, time.UTC)
	old.codeAttestThrottle.Now = func() time.Time { return now }
	old.SeedCodeAttestCache(ctx)
	old.codeAttestThrottle.RetrySpacing = time.Millisecond
	old.codeAttestThrottle.RetryJitter = 0
	pub, priv, seKey, sePub := providerKeyMaterial(t)
	p := newCodeAttestProvider(pub, sePub)
	p.Version = "0.9.0"
	p.Status = registry.StatusOnline
	p.TrustLevel = registry.TrustHardware
	p.AttestationResult.BinaryHash = strings.Repeat("a", 64)
	old.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, key, nonce string) error {
		return completeRoundTrip(t, old, p, p.ID, priv, seKey, key, nonce)
	}})
	old.CodeAttestLoop(ctx, p.ID, p)
	if !p.GetFreshCodeAttested() {
		t.Fatal("real initial process proof failed")
	}
	proofAt := now
	// Persist deterministically; the production asynchronous write is identical.
	proof, _ := old.codeAttestThrottle.ProofForIdentity(sePub, p.Version, p.APNsDeviceToken, p.PublicKey, p.AttestationResult.BinaryHash)
	if err := st.UpsertCodeAttestation(ctx, proof); err != nil {
		t.Fatal(err)
	}
	now = now.Add(2 * time.Hour)
	observation, ok := old.CodeCoverageObservation(p, false)
	if !ok {
		t.Fatal("verified live process did not produce coverage")
	}
	old.PersistCodeCoverage([]store.CodeAttestation{observation})
	rows, err := st.ListCodeAttestations(ctx)
	if err != nil || len(rows) != 1 || !rows[0].AttestedAt.Equal(proofAt) {
		t.Fatal("coverage changed original APNs proof time")
	}
	now = now.Add(60 * time.Second)
	next := newTrustFixture(t, production.Dependencies{Registry: registry.New(quietLogger()), Store: st, Logger: quietLogger()}, production.Config{})
	t.Cleanup(next.Close)
	next.codeAttestThrottle.Now = func() time.Time { return now }
	next.SeedCodeAttestCache(ctx)
	reconnect := newCodeAttestProvider(pub, sePub)
	reconnect.Version = p.Version
	reconnect.AttestationResult.BinaryHash = p.AttestationResult.BinaryHash
	pushes, resumes := 0, 0
	next.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, _, _ string) error { pushes++; return nil }})
	next.codeResumeSender = func(_ string, m protocol.CodeAttestationResumeChallenge) error {
		resumes++
		return completeResumeRoundTrip(t, next, reconnect, reconnect.ID, priv, seKey, m)
	}
	next.CodeAttestLoop(ctx, reconnect.ID, reconnect)
	if pushes != 0 || resumes != 1 || !reconnect.GetFreshCodeAttested() {
		t.Fatalf("pushes=%d resumes=%d fresh=%v", pushes, resumes, reconnect.GetFreshCodeAttested())
	}
	rows, _ = st.ListCodeAttestations(ctx)
	if !rows[0].AttestedAt.Equal(proofAt) {
		t.Fatal("resume fabricated a new APNs timestamp")
	}
}

func TestCodeContinuityRefusesChangedOrExpiredIdentity(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	covered := now.Add(-60 * time.Second)
	base := store.CodeAttestation{SEPubKey: "se", Version: "0.9.0", APNsToken: "token", NodePublicKey: "process", BinaryHash: strings.Repeat("a", 64), AttestedAt: now.Add(-time.Hour), ContinuousCoverageUntil: &covered}
	for _, tc := range []struct {
		name                     string
		modify                   func(*store.CodeAttestation)
		se, version, token, node string
	}{
		{"same process", func(*store.CodeAttestation) {}, "se", "0.9.0", "token", "process"},
		{"changed process", func(*store.CodeAttestation) {}, "se", "0.9.0", "token", "new-process"},
		{"changed token", func(*store.CodeAttestation) {}, "se", "0.9.0", "new-token", "process"},
		{"changed version", func(*store.CodeAttestation) {}, "se", "0.9.1", "token", "process"},
		{"missing coverage", func(r *store.CodeAttestation) { r.ContinuousCoverageUntil = nil }, "se", "0.9.0", "token", "process"},
		{"expired coverage", func(r *store.CodeAttestation) { v := now.Add(-121 * time.Second); r.ContinuousCoverageUntil = &v }, "se", "0.9.0", "token", "process"},
		{"future coverage", func(r *store.CodeAttestation) { v := now.Add(time.Millisecond); r.ContinuousCoverageUntil = &v }, "se", "0.9.0", "token", "process"},
		{"missing binary", func(r *store.CodeAttestation) { r.BinaryHash = "" }, "se", "0.9.0", "token", "process"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			th := newThrottleFixture()
			th.Now = func() time.Time { return now }
			r := base
			tc.modify(&r)
			th.Seed([]store.CodeAttestation{r})
			got := th.reuseAttestation(tc.se, tc.version, tc.token, tc.node)
			if got != (tc.name == "same process") {
				t.Fatalf("reuse=%v", got)
			}
			if _, ok := th.ReuseAttestationForTransition("se", "token"); ok {
				t.Fatal("old proof must never authorize a process/release transition")
			}
			th.InvalidateReuse("se")
			if th.reuseAttestation("se", "0.9.0", "token", "process") {
				t.Fatal("invalidation bypassed")
			}
		})
	}
}

func TestCodeCoverageRequiresVerifiedCurrentBinding(t *testing.T) {
	srv := newTrustFixture(t, production.Dependencies{Registry: registry.New(quietLogger()), Store: memory.NewMemory(store.Config{}), Logger: quietLogger()}, production.Config{})
	t.Cleanup(srv.Close)
	now := time.Unix(1_800_000_000, 0)
	srv.codeAttestThrottle.Now = func() time.Time { return now }
	pub, _, _, se := providerKeyMaterial(t)
	p := newCodeAttestProvider(pub, se)
	p.Version = "0.9.0"
	p.Status = registry.StatusOnline
	p.TrustLevel = registry.TrustHardware
	p.AttestationResult.BinaryHash = strings.Repeat("a", 64)
	srv.codeAttestThrottle.RecordAttestedForProcess(se, p.Version, p.APNsDeviceToken, p.PublicKey, p.AttestationResult.BinaryHash)
	for _, tc := range []struct {
		name   string
		change func(*registry.Provider)
	}{
		{"unverified", func(p *registry.Provider) { p.CodeAttested = false }},
		{"no live process proof", func(p *registry.Provider) { p.FreshCodeAttested = false }},
		{"untrusted", func(p *registry.Provider) { p.Status = registry.StatusUntrusted }},
		{"no hardware trust", func(p *registry.Provider) { p.TrustLevel = registry.TrustSelfSigned }},
		{"new node", func(p *registry.Provider) { p.PublicKey = "other" }},
		{"new binary", func(p *registry.Provider) { p.AttestationResult.BinaryHash = strings.Repeat("b", 64) }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			p.CodeAttested = true
			p.FreshCodeAttested = true
			p.Status = registry.StatusOnline
			p.TrustLevel = registry.TrustHardware
			p.PublicKey = pub
			p.AttestationResult.BinaryHash = strings.Repeat("a", 64)
			tc.change(p)
			for _, allowOffline := range []bool{false, true} {
				if allowOffline && p.Status == registry.StatusOnline {
					p.Status = registry.StatusOffline
				}
				if _, ok := srv.CodeCoverageObservation(p, allowOffline); ok {
					t.Fatalf("unproven binding advanced coverage (allowOffline=%v)", allowOffline)
				}
			}
		})
	}
}

func TestCodeCoverageSweepDisconnectAndClose(t *testing.T) {
	st := memory.NewMemory(store.Config{})
	srv := newTrustFixture(t, production.Dependencies{Registry: registry.New(quietLogger()), Store: st, Logger: quietLogger()}, production.Config{})
	now := time.Date(2026, 9, 8, 0, 0, 0, 0, time.UTC)
	srv.codeAttestThrottle.Now = func() time.Time { return now }
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
	srv.codeAttestThrottle.RecordAttestedForProcess("coverage-se", p.Version, p.APNsDeviceToken, p.PublicKey, p.AttestationResult.BinaryHash)
	proof, _ := srv.codeAttestThrottle.ProofForIdentity("coverage-se", p.Version, p.APNsDeviceToken, p.PublicKey, p.AttestationResult.BinaryHash)
	if proof.SEPubKey != "coverage-se" {
		t.Fatal("exact-bound proof missing from coverage cache")
	}
	if err := st.UpsertCodeAttestation(context.Background(), proof); err != nil {
		t.Fatal(err)
	}
	check := func(want time.Time) {
		t.Helper()
		rows, _ := st.ListCodeAttestations(context.Background())
		if len(rows) != 1 || rows[0].ContinuousCoverageUntil == nil || !rows[0].ContinuousCoverageUntil.Equal(want) {
			t.Fatalf("coverage=%+v want=%s", rows, want)
		}
	}
	now = now.Add(time.Hour)
	srv.SweepCodeAttestCoverage()
	check(now)
	lastSweep := now
	now = now.Add(25 * time.Second)
	// providerReadLoop marks the dead socket offline before deferred cleanup.
	p.Mu().Lock()
	p.Status = registry.StatusOffline
	p.Mu().Unlock()
	srv.SweepCodeAttestCoverage()
	check(lastSweep) // periodic sweeps must never keep offline evidence alive
	srv.StopCodeAttestCoverageForProvider(p.ID)
	check(now)
	disconnectedAt := now
	rows, err := st.ListCodeAttestations(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	for _, gap := range []time.Duration{100 * time.Second, 120 * time.Second, 121 * time.Second} {
		th := newThrottleFixture()
		th.Now = func() time.Time { return disconnectedAt.Add(gap) }
		th.Seed(rows)
		if got := th.reuseAttestation("coverage-se", p.Version, p.APNsDeviceToken, p.PublicKey); got != (gap <= identitystate.ContinuityGap) {
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
