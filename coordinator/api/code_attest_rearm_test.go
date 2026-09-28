package api

import (
	"context"
	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// TestRearmOnHeartbeatTokenArrivalTriggersChallenge proves W5 Fix 2 (2a): a
// provider that registered WITHOUT an APNs device token (headless/late-token Mac)
// and later reports one in a HEARTBEAT is re-armed and attests via the full
// round-trip — no reconnect required.
func TestRearmOnHeartbeatTokenArrivalTriggersChallenge(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	fastBudgets(srv)

	kPubB64, kPriv, seKey, sePubB64 := providerKeyMaterial(t)
	provider := newCodeAttestProvider(kPubB64, sePubB64)
	provider.APNsDeviceToken = "" // registered token-less
	provider.Version = "0.6.0"

	var pushes int32
	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, pubKeyB64, nonceB64 string) error {
		atomic.AddInt32(&pushes, 1)
		return completeRoundTrip(t, srv, provider, "p1", kPriv, seKey, pubKeyB64, nonceB64)
	}})

	// A heartbeat now carries the token that arrived after registration.
	srv.maybeRearmCodeAttest(t.Context(), "p1", provider, &protocol.HeartbeatMessage{
		Type:            protocol.TypeHeartbeat,
		Status:          "idle",
		APNsDeviceToken: "late-tok",
		APNsEnvironment: "production",
	})

	if got := providerToken(provider); got != "late-tok" {
		t.Fatalf("heartbeat token not recorded on provider: %q", got)
	}
	if !waitForCond(2*time.Second, provider.GetCodeAttested) {
		t.Fatal("late heartbeat token must re-arm and attest via the round-trip (no reconnect)")
	}
	if atomic.LoadInt32(&pushes) == 0 {
		t.Fatal("re-arm must SEND a code-identity challenge")
	}
}

// TestHeartbeatTokenAloneNeverGrantsAttestation is the core security invariant:
// the heartbeat token only lets the coordinator SEND a challenge — it never by
// itself grants CodeAttested. With the push delivered but never answered, the
// connection stays un-attested (fail-closed).
func TestHeartbeatTokenAloneNeverGrantsAttestation(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	fastBudgets(srv)
	srv.codeAttestThrottle.maxAttempts = 2

	kPubB64, _, _, sePubB64 := providerKeyMaterial(t)
	provider := newCodeAttestProvider(kPubB64, sePubB64)
	provider.APNsDeviceToken = ""
	provider.Version = "0.6.0"

	var pushes int32
	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, _, _ string) error {
		atomic.AddInt32(&pushes, 1) // delivered, but the provider never replies
		return nil
	}})

	srv.maybeRearmCodeAttest(t.Context(), "p1", provider, &protocol.HeartbeatMessage{
		Type:            protocol.TypeHeartbeat,
		Status:          "idle",
		APNsDeviceToken: "tok",
	})

	// Let the re-arm loop spend its fast attempts (maxAttempts pushes, no reply).
	waitForCond(2*time.Second, func() bool { return atomic.LoadInt32(&pushes) >= 2 })
	if provider.GetCodeAttested() {
		t.Fatal("a heartbeat token without a verified round-trip must NEVER attest (fail-closed)")
	}
}

// TestRearmChangedTokenForcesRealChallengeNoReuseBypass proves the "changed
// token forces a re-challenge (no bypass)" invariant: a provider that is already
// attested (with a live reuse record) and whose token CHANGES must (1) be reset
// to un-attested (fail-closed) and (2) run a REAL challenge push rather than
// short-circuiting on the prior proof via the reuse cache.
func TestRearmChangedTokenForcesRealChallengeNoReuseBypass(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	fastBudgets(srv)

	kPubB64, kPriv, seKey, sePubB64 := providerKeyMaterial(t)
	p := newCodeAttestProvider(kPubB64, sePubB64)
	p.APNsDeviceToken = "tok1"
	p.Version = "0.6.0"

	// Phase 1: a genuine attestation establishes a reuse record + CodeAttested.
	complete := int32(1)
	var pushes int32
	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, pubKeyB64, nonceB64 string) error {
		atomic.AddInt32(&pushes, 1)
		if atomic.LoadInt32(&complete) == 1 {
			return completeRoundTrip(t, srv, p, "p1", kPriv, seKey, pubKeyB64, nonceB64)
		}
		return nil // phase 2: deliver but drop (so we can observe a real push, no reply)
	}})
	srv.codeAttestLoop(context.Background(), "p1", p)
	if !p.GetCodeAttested() {
		t.Fatal("phase 1 should attest")
	}
	if !srv.codeAttestThrottle.reuseAttestation(
		sePubB64, "0.6.0", "tok1", kPubB64,
	) {
		t.Fatal("phase 1 should leave a reusable record")
	}
	pushesAfterP1 := atomic.LoadInt32(&pushes)
	p.Mu().Lock()
	p.DeviceEvidence = registry.DeviceEvidence{
		SEPublicKey: sePubB64, Serial: "SERIAL",
		VerifiedAt: time.Now(), EvidenceGeneration: 1,
	}
	p.ApplicationEvidence = registry.ApplicationEvidence{
		SEPublicKey: sePubB64, Serial: "SERIAL",
		ProcessPublicKey: kPubB64, APNsToken: "tok1",
		BinaryHash: strings.Repeat("a", 64), Version: "0.6.0",
		Backend: "mlx-swift", VerifiedAt: time.Now(),
		EvidenceGeneration: 1, PolicyGeneration: 1,
	}
	p.Mu().Unlock()

	// Phase 2: the APNs token changes in a heartbeat.
	atomic.StoreInt32(&complete, 0)
	srv.maybeRearmCodeAttest(t.Context(), "p1", p, &protocol.HeartbeatMessage{
		Type:            protocol.TypeHeartbeat,
		Status:          "idle",
		APNsDeviceToken: "tok2",
	})

	// Synchronous, fail-closed effects of a changed token.
	if p.GetCodeAttested() {
		t.Fatal("a changed token must reset CodeAttested (fail-closed) until re-proven")
	}
	if srv.codeAttestThrottle.reuseAttestation(
		sePubB64, "0.6.0", "tok2", kPubB64,
	) {
		t.Fatal("a changed token must invalidate the reuse record (no bypass)")
	}
	if got := providerToken(p); got != "tok2" {
		t.Fatalf("changed token not recorded: %q", got)
	}
	if _, ok := p.ApplicationEvidenceSnapshot(); ok {
		t.Fatal("token rotation retained stale application/process evidence")
	}
	p.Mu().Lock()
	deviceEvidence := p.DeviceEvidence
	p.Mu().Unlock()
	if deviceEvidence.EvidenceGeneration != 1 ||
		deviceEvidence.SEPublicKey != sePubB64 {
		t.Fatalf("token rotation cleared independent device proof: %+v", deviceEvidence)
	}

	// A REAL challenge must be pushed (proving the loop did NOT reuse). If it had
	// bypassed via reuse, pushes would not increase and CodeAttested would flip.
	if !waitForCond(2*time.Second, func() bool { return atomic.LoadInt32(&pushes) > pushesAfterP1 }) {
		t.Fatal("a changed token must force a real challenge push (no reuse bypass)")
	}
	if p.GetCodeAttested() {
		t.Fatal("the forced re-challenge was never answered, so CodeAttested must stay false")
	}
}

// TestRearmChangedTokenDeletesPersistedReuse proves the Codex #6 fix: a changed
// APNs token must delete the PERSISTED reuse row (not just the in-memory one), so
// a coordinator restart before the forced re-challenge completes cannot reseed and
// reuse the pre-rotation proof.
func TestRearmChangedTokenDeletesPersistedReuse(t *testing.T) {
	logger := quietLogger()
	st := store.NewMemory(store.Config{})
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)
	fastBudgets(srv)
	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, _, _ string) error { return nil }})

	kPubB64, _, _, sePubB64 := providerKeyMaterial(t)
	p := newCodeAttestProvider(kPubB64, sePubB64)
	p.APNsDeviceToken = "tok1"
	p.Version = "0.6.0"

	// A genuine prior attestation is persisted, and the store seam is wired.
	if err := st.UpsertCodeAttestation(context.Background(), store.CodeAttestation{
		SEPubKey:   sePubB64,
		Version:    "0.6.0",
		AttestedAt: time.Now(),
	}); err != nil {
		t.Fatal(err)
	}
	srv.SeedCodeAttestCache(context.Background())

	// Token rotation in a heartbeat.
	srv.maybeRearmCodeAttest(t.Context(), "p1", p, &protocol.HeartbeatMessage{
		Type:            protocol.TypeHeartbeat,
		Status:          "idle",
		APNsDeviceToken: "tok2",
	})

	if !waitForCond(2*time.Second, func() bool {
		rows, err := st.ListCodeAttestations(context.Background())
		if err != nil {
			return false
		}
		for _, r := range rows {
			if r.SEPubKey == sePubB64 {
				return false // persisted row still present
			}
		}
		return true // deleted
	}) {
		t.Fatal("a changed APNs token must delete the persisted reuse row so a restart cannot reseed it (Codex #6)")
	}
}

// TestRearmChangedTokenKicksImmediateOrdinaryChallenge proves the Codex 05:33Z
// #2 fix: token rotation clears application evidence, and that evidence is
// regenerated ONLY by the connection's ordinary attestation challenge loop —
// so the rearm path must kick that loop immediately (RequestImmediateChallenge)
// rather than leaving the provider unroutable until the 5-minute periodic
// tick while queued requests expire at 120s. A first-token arrival clears no
// evidence and must NOT kick.
func TestRearmChangedTokenKicksImmediateOrdinaryChallenge(t *testing.T) {
	logger := quietLogger()
	reg := registry.New(logger)
	srv := NewServer(reg, store.NewMemory(store.Config{}), ServerConfig{}, logger)
	fastBudgets(srv)
	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, _, _ string) error { return nil }})

	_, _, _, sePubB64 := providerKeyMaterial(t)
	// Registry-created provider: carries the real challengeKick channel the
	// connection's challengeLoop selects on.
	p := makeRoutableProvider(t, reg, "kick-provider", "kick-model")
	p.Mu().Lock()
	p.AttestationResult = &attestation.VerificationResult{Valid: true, PublicKey: sePubB64}
	p.APNsDeviceToken = "tok1"
	p.CodeAttested = true
	p.ApplicationEvidence = registry.ApplicationEvidence{
		SEPublicKey: sePubB64, Serial: "SERIAL",
		ProcessPublicKey: p.PublicKey, APNsToken: "tok1",
		BinaryHash: strings.Repeat("a", 64), VerifiedAt: time.Now(),
		EvidenceGeneration: 1, PolicyGeneration: 1,
	}
	p.Mu().Unlock()
	select {
	case <-p.ImmediateChallengeChan():
		t.Fatal("precondition: unexpected pending challenge kick")
	default:
	}

	// Steady state: an unchanged token must not kick.
	srv.maybeRearmCodeAttest(t.Context(), "kick-provider", p, &protocol.HeartbeatMessage{
		Type: protocol.TypeHeartbeat, Status: "idle", APNsDeviceToken: "tok1",
	})
	select {
	case <-p.ImmediateChallengeChan():
		t.Fatal("unchanged token must not kick the ordinary challenge loop")
	default:
	}

	// Rotation: evidence is cleared AND the ordinary challenge loop is kicked.
	srv.maybeRearmCodeAttest(t.Context(), "kick-provider", p, &protocol.HeartbeatMessage{
		Type: protocol.TypeHeartbeat, Status: "idle", APNsDeviceToken: "tok2",
	})
	if _, ok := p.ApplicationEvidenceSnapshot(); ok {
		t.Fatal("token rotation retained stale application evidence")
	}
	if p.GetCodeAttested() {
		t.Fatal("token rotation must reset CodeAttested (fail-closed)")
	}
	select {
	case <-p.ImmediateChallengeChan():
	default:
		t.Fatal("token rotation must kick an immediate ordinary challenge, not wait for the 5-minute tick")
	}

	// First-token arrival on a token-less provider clears no evidence: no kick.
	late := makeRoutableProvider(t, reg, "late-provider", "kick-model")
	late.Mu().Lock()
	late.AttestationResult = &attestation.VerificationResult{Valid: true, PublicKey: sePubB64}
	late.APNsDeviceToken = ""
	late.Mu().Unlock()
	srv.maybeRearmCodeAttest(t.Context(), "late-provider", late, &protocol.HeartbeatMessage{
		Type: protocol.TypeHeartbeat, Status: "idle", APNsDeviceToken: "late-tok",
	})
	select {
	case <-late.ImmediateChallengeChan():
		t.Fatal("first token arrival clears no evidence and must not kick")
	default:
	}
}

// TestClearChallengeDropsOutstanding proves the Codex #1 hardening: clearing the
// outstanding challenge (done on APNs token rotation) drops it unconditionally,
// so a stale reply to the pre-rotation challenge can never complete the forced
// re-challenge — even before the fresh push records a new nonce.
func TestClearChallengeDropsOutstanding(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	fastBudgets(srv)

	const seKey = "se-key-1"
	srv.codeAttestThrottle.recordChallenge(seKey, "old-nonce")
	if _, ok := srv.codeAttestThrottle.outstandingChallenge(seKey); !ok {
		t.Fatal("precondition: a recorded challenge must be outstanding")
	}
	srv.codeAttestThrottle.clearChallenge(seKey)
	if _, ok := srv.codeAttestThrottle.outstandingChallenge(seKey); ok {
		t.Fatal("clearChallenge must drop the outstanding challenge so a stale reply can't attest")
	}
}
