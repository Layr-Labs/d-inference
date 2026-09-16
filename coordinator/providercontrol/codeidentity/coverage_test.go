package codeidentity

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestCodeContinuityResumeStillRequiresLiveProcessProof(t *testing.T) {
	ctx := context.Background()
	st := store.NewCached(store.NewMemory(store.Config{}), store.DefaultCacheConfig())
	old := newTestManager(registry.New(quietLogger()), st, testServerConfig{}, quietLogger())
	t.Cleanup(old.Close)
	now := time.Date(2026, 9, 8, 0, 0, 0, 0, time.UTC)
	old.state.now = func() time.Time { return now }
	old.Seed(ctx)
	old.state.retrySpacing = time.Millisecond
	old.state.retryJitter = 0
	pub, priv, seKey, sePub := providerKeyMaterial(t)
	p := newCodeAttestProvider(pub, sePub)
	p.Version = "0.9.0"
	p.Status = registry.StatusOnline
	p.TrustLevel = registry.TrustHardware
	p.AttestationResult.BinaryHash = strings.Repeat("a", 64)
	old.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, key, nonce string) error {
		return completeRoundTrip(t, old, p, p.ID, priv, seKey, key, nonce)
	}})
	old.Loop(ctx, p.ID, p)
	if !p.GetFreshCodeAttested() {
		t.Fatal("real initial process proof failed")
	}
	proofAt := now
	// Persist deterministically; the production asynchronous write is identical.
	old.state.mu.Lock()
	proof := old.state.attested[sePub].persisted(sePub)
	old.state.mu.Unlock()
	if err := st.UpsertCodeAttestation(ctx, proof); err != nil {
		t.Fatal(err)
	}
	now = now.Add(2 * time.Hour)
	observation, ok := old.codeCoverageObservation(p, false)
	if !ok {
		t.Fatal("verified live process did not produce coverage")
	}
	old.persistCodeCoverage([]store.CodeAttestation{observation})
	rows, err := st.ListCodeAttestations(ctx)
	if err != nil || len(rows) != 1 || !rows[0].AttestedAt.Equal(proofAt) {
		t.Fatal("coverage changed original APNs proof time")
	}
	now = now.Add(60 * time.Second)
	next := newTestManager(registry.New(quietLogger()), st, testServerConfig{}, quietLogger())
	t.Cleanup(next.Close)
	next.state.now = func() time.Time { return now }
	next.Seed(ctx)
	reconnect := newCodeAttestProvider(pub, sePub)
	reconnect.Version = p.Version
	reconnect.AttestationResult.BinaryHash = p.AttestationResult.BinaryHash
	pushes, resumes := 0, 0
	next.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, _, _ string) error { pushes++; return nil }})
	next.codeResumeSender = func(_ string, m protocol.CodeAttestationResumeChallenge) error {
		resumes++
		return completeResumeRoundTrip(t, next, reconnect, reconnect.ID, priv, seKey, m)
	}
	next.Loop(ctx, reconnect.ID, reconnect)
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
			th := newDeviceState()
			th.now = func() time.Time { return now }
			r := base
			tc.modify(&r)
			th.seed([]store.CodeAttestation{r})
			got := th.reuseAttestation(tc.se, tc.version, tc.token, tc.node)
			if got != (tc.name == "same process") {
				t.Fatalf("reuse=%v", got)
			}
			if _, ok := th.reuseAttestationForTransition("se", "token"); ok {
				t.Fatal("old proof must never authorize a process/release transition")
			}
			th.invalidateReuse("se")
			if th.reuseAttestation("se", "0.9.0", "token", "process") {
				t.Fatal("invalidation bypassed")
			}
		})
	}
}

func TestCodeCoverageRequiresVerifiedCurrentBinding(t *testing.T) {
	srv := newTestManager(registry.New(quietLogger()), store.NewMemory(store.Config{}), testServerConfig{}, quietLogger())
	t.Cleanup(srv.Close)
	now := time.Unix(1_800_000_000, 0)
	srv.state.now = func() time.Time { return now }
	pub, _, _, se := providerKeyMaterial(t)
	p := newCodeAttestProvider(pub, se)
	p.Version = "0.9.0"
	p.Status = registry.StatusOnline
	p.TrustLevel = registry.TrustHardware
	p.AttestationResult.BinaryHash = strings.Repeat("a", 64)
	srv.state.recordAttestedForProcess(se, p.Version, p.APNsDeviceToken, p.PublicKey, p.AttestationResult.BinaryHash)
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
				if _, ok := srv.codeCoverageObservation(p, allowOffline); ok {
					t.Fatalf("unproven binding advanced coverage (allowOffline=%v)", allowOffline)
				}
			}
		})
	}
}
