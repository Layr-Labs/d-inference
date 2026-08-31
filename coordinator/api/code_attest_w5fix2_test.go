package api

import (
	"context"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// waitForCond polls cond up to d, returning its final value. Used to observe a
// goroutine-driven re-arm/attestation outcome without a fixed sleep.
func waitForCond(d time.Duration, cond func() bool) bool {
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		if cond() {
			return true
		}
		time.Sleep(time.Millisecond)
	}
	return cond()
}

func fastBudgets(srv *Server) {
	srv.codeAttestThrottle.backgroundPushCooldown = time.Millisecond
	srv.codeAttestThrottle.alertPushCooldown = time.Millisecond
	srv.codeAttestThrottle.budgetClearCooldown = time.Millisecond
	srv.codeAttestThrottle.retrySpacing = time.Millisecond
	srv.codeAttestThrottle.retryJitter = 0
}

func providerToken(p *registry.Provider) string {
	p.Mu().Lock()
	defer p.Mu().Unlock()
	return p.APNsDeviceToken
}

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
	srv.maybeRearmCodeAttest(context.Background(), "p1", provider, &protocol.HeartbeatMessage{
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

	srv.maybeRearmCodeAttest(context.Background(), "p1", provider, &protocol.HeartbeatMessage{
		Type:            protocol.TypeHeartbeat,
		Status:          "idle",
		APNsDeviceToken: "tok",
	})

	// Let the re-arm loop run to exhaustion (maxAttempts pushes, no reply).
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
	srv.maybeRearmCodeAttest(context.Background(), "p1", p, &protocol.HeartbeatMessage{
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
	srv.maybeRearmCodeAttest(context.Background(), "p1", p, &protocol.HeartbeatMessage{
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
	srv.maybeRearmCodeAttest(context.Background(), "kick-provider", p, &protocol.HeartbeatMessage{
		Type: protocol.TypeHeartbeat, Status: "idle", APNsDeviceToken: "tok1",
	})
	select {
	case <-p.ImmediateChallengeChan():
		t.Fatal("unchanged token must not kick the ordinary challenge loop")
	default:
	}

	// Rotation: evidence is cleared AND the ordinary challenge loop is kicked.
	srv.maybeRearmCodeAttest(context.Background(), "kick-provider", p, &protocol.HeartbeatMessage{
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
	srv.maybeRearmCodeAttest(context.Background(), "late-provider", late, &protocol.HeartbeatMessage{
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

// TestSeededReuseSkipsRePush proves a persisted attestation seeded after deploy
// avoids another APNs push, while the fresh connection still proves possession
// of the persisted row's exact process private key over the live WebSocket.
func TestSeededReuseSkipsRePush(t *testing.T) {
	logger := quietLogger()
	st := store.NewMemory(store.Config{})
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)
	fastBudgets(srv)

	kPubB64, kPriv, seKey, sePubB64 := providerKeyMaterial(t)

	// A genuine attestation persisted before the (simulated) deploy.
	if err := st.UpsertCodeAttestation(context.Background(), store.CodeAttestation{
		SEPubKey: sePubB64, Version: "0.6.0", AttestedAt: time.Now(),
		APNsToken: "devtok", NodePublicKey: kPubB64,
	}); err != nil {
		t.Fatalf("seed store: %v", err)
	}

	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, _, _ string) error {
		t.Fatal("seeded reuse must NOT push (would be the post-deploy storm this fix prevents)")
		return nil
	}})
	provider := newCodeAttestProvider(kPubB64, sePubB64)
	provider.Version = "0.6.0"
	srv.codeResumeSender = func(
		_ string, message protocol.CodeAttestationResumeChallenge,
	) error {
		return completeResumeRoundTrip(
			t, srv, provider, "p1", kPriv, seKey, message,
		)
	}
	srv.SeedCodeAttestCache(context.Background())

	// Provider is constructed before seeding so the live resume handler can
	// prove its exact node private key without spending APNs budget.
	srv.codeAttestLoop(context.Background(), "p1", provider)

	if !provider.GetCodeAttested() || !provider.GetFreshCodeAttested() {
		t.Fatal("seeded proof did not complete the live process-key resume")
	}
}

// TestSeededRowWithRotatedTokenForcesRealChallenge proves Codex #7: a persisted
// reuse row is bound to the APNs token, so a provider that rotated its token while
// DISCONNECTED (the heartbeat re-arm path never saw the change to delete the row)
// does NOT inherit the pre-rotation proof after a restart reseed — it runs a real
// challenge against the new token.
func TestSeededRowWithRotatedTokenForcesRealChallenge(t *testing.T) {
	logger := quietLogger()
	st := store.NewMemory(store.Config{})
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)
	fastBudgets(srv)

	kPubB64, kPriv, seKey, sePubB64 := providerKeyMaterial(t)

	// A genuine attestation persisted under the OLD token, before the restart.
	if err := st.UpsertCodeAttestation(context.Background(), store.CodeAttestation{
		SEPubKey: sePubB64, Version: "0.6.0", AttestedAt: time.Now(), APNsToken: "old-tok",
	}); err != nil {
		t.Fatalf("seed store: %v", err)
	}
	srv.SeedCodeAttestCache(context.Background())

	// The device reconnects with a NEW token (rotated while offline).
	var pushes int32
	provider := newCodeAttestProvider(kPubB64, sePubB64)
	provider.Version = "0.6.0"
	provider.APNsDeviceToken = "new-tok"
	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, pubKeyB64, nonceB64 string) error {
		atomic.AddInt32(&pushes, 1)
		return completeRoundTrip(t, srv, provider, "p1", kPriv, seKey, pubKeyB64, nonceB64)
	}})
	srv.codeAttestLoop(context.Background(), "p1", provider)

	if atomic.LoadInt32(&pushes) == 0 {
		t.Fatal("a seeded row bound to the OLD token must force a REAL challenge for the new token (Codex #7)")
	}
	if !provider.GetCodeAttested() {
		t.Fatal("the real challenge round-trip should attest")
	}
}

// TestSeededStalePersistedRowForcesRealChallenge proves the persisted-reuse
// fail-closed property: a seeded row that has aged past the reuse window does NOT
// grant CodeAttested — it falls through to a REAL challenge round-trip.
func TestSeededStalePersistedRowForcesRealChallenge(t *testing.T) {
	logger := quietLogger()
	st := store.NewMemory(store.Config{})
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)
	fastBudgets(srv)

	cur := time.Unix(1_700_000_000, 0)
	srv.codeAttestThrottle.now = func() time.Time { return cur }

	kPubB64, kPriv, seKey, sePubB64 := providerKeyMaterial(t)

	// Seed a row that is fresh at seed time (20m < 30m window) so it IS loaded...
	if err := st.UpsertCodeAttestation(context.Background(), store.CodeAttestation{
		SEPubKey: sePubB64, Version: "0.6.0", AttestedAt: cur.Add(-20 * time.Minute),
	}); err != nil {
		t.Fatalf("seed store: %v", err)
	}
	srv.SeedCodeAttestCache(context.Background())

	// ...then advance the clock so the seeded row is now PAST the reuse window.
	cur = cur.Add(15 * time.Minute) // row is now 35m old > 30m window
	if srv.codeAttestThrottle.reuseAttestation(
		sePubB64, "0.6.0", "devtok", kPubB64,
	) {
		t.Fatal("an aged-out seeded row must not be reusable (fail-closed staleness)")
	}

	var pushes int32
	provider := newCodeAttestProvider(kPubB64, sePubB64)
	provider.Version = "0.6.0"
	// Deliver the reply onto THIS provider (the live connection).
	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, pubKeyB64, nonceB64 string) error {
		atomic.AddInt32(&pushes, 1)
		return completeRoundTrip(t, srv, provider, "p1", kPriv, seKey, pubKeyB64, nonceB64)
	}})
	srv.codeAttestLoop(context.Background(), "p1", provider)

	if atomic.LoadInt32(&pushes) == 0 {
		t.Fatal("a stale seeded row must fall through to a REAL challenge (a push), not be reused")
	}
	if !provider.GetCodeAttested() {
		t.Fatal("the real challenge round-trip should attest")
	}
}

// TestSeededWrongVersionRowForcesRealChallenge proves the SAME-VERSION reuse gate
// survives persistence AND that an unfenced cross-version reconnect still forces a
// real challenge: a seeded row for a DIFFERENT binary version is not reusable via
// reuseAttestation, and codeAttestLoop falls through to a push because this
// provider does not satisfy the cross-version fences (RuntimeVerified /
// RuntimeManifestChecked / ChallengeVerifiedSIP are unset). The fenced
// cross-version reuse path is covered by TestCrossVersionReuse* below.
func TestSeededWrongVersionRowForcesRealChallenge(t *testing.T) {
	logger := quietLogger()
	st := store.NewMemory(store.Config{})
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)
	fastBudgets(srv)

	kPubB64, kPriv, seKey, sePubB64 := providerKeyMaterial(t)

	// Persisted under an OLD binary version.
	if err := st.UpsertCodeAttestation(context.Background(), store.CodeAttestation{
		SEPubKey: sePubB64, Version: "0.5.0", AttestedAt: time.Now(),
	}); err != nil {
		t.Fatalf("seed store: %v", err)
	}
	srv.SeedCodeAttestCache(context.Background())

	if srv.codeAttestThrottle.reuseAttestation(
		sePubB64, "0.6.0", "devtok", kPubB64,
	) {
		t.Fatal("a seeded row for a different version must not be reusable")
	}

	var pushes int32
	provider := newCodeAttestProvider(kPubB64, sePubB64)
	provider.Version = "0.6.0" // running a NEWER binary than the persisted row
	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, pubKeyB64, nonceB64 string) error {
		atomic.AddInt32(&pushes, 1)
		return completeRoundTrip(t, srv, provider, "p1", kPriv, seKey, pubKeyB64, nonceB64)
	}})
	srv.codeAttestLoop(context.Background(), "p1", provider)

	if atomic.LoadInt32(&pushes) == 0 {
		t.Fatal("a wrong-version seeded row must force a REAL challenge (a push)")
	}
	if !provider.GetCodeAttested() {
		t.Fatal("the real challenge round-trip should attest")
	}
}

// crossVersionProvider builds a fully-fenced provider running newVersion: valid
// attestation, runtime+manifest verified, SIP-verified challenge, same SE key +
// APNs token. Transition reuse additionally requires current generation-bound
// application evidence attesting this provider's exact process key.
func crossVersionProvider(kPubB64, sePubB64, newVersion string) *registry.Provider {
	p := newCodeAttestProvider(kPubB64, sePubB64)
	p.Version = newVersion
	p.Backend = "mlx-swift"
	p.RuntimeVerified = true
	p.RuntimeManifestChecked = true
	p.MetallibVerified = true
	p.ChallengeVerifiedSIP = true
	p.AttestationResult.SerialNumber = "SERIAL"
	p.AttestationResult.BinaryHash = strings.Repeat("a", 64)
	return p
}

func seedFreshProcessAttestation(
	srv *Server, seKey, oldVersion, token, nodeKey, binaryHash string,
) {
	srv.codeAttestThrottle.recordAttestedForProcess(
		seKey, oldVersion, token, nodeKey, binaryHash)
}

// armCrossVersionApplicationEvidence publishes a release policy whose ACTIVE
// inventory holds the current release (trHashA, p.Version) and its approved
// predecessor release (trHashB, 0.6.13), then grants current generation-bound
// application evidence for the provider's exact process key.
func armCrossVersionApplicationEvidence(
	t *testing.T, srv *Server, p *registry.Provider, sePubB64 string,
) {
	t.Helper()
	armCrossVersionApplicationEvidenceWithPolicy(t, srv, p, sePubB64,
		map[string][]approvedReleasePolicy{
			trHashA: {{Version: p.Version, Platform: "macos-arm64", Backend: p.Backend}},
			trHashB: {{Version: "0.6.13", Platform: "macos-arm64", Backend: p.Backend}},
		})
}

func armCrossVersionApplicationEvidenceWithPolicy(
	t *testing.T, srv *Server, p *registry.Provider, sePubB64 string,
	byBinaryHash map[string][]approvedReleasePolicy,
) {
	t.Helper()
	const policyGeneration = 1
	srv.releaseTrustPolicy.Store(&releaseTrustPolicySnapshot{
		Generation:   policyGeneration,
		Required:     true,
		ByBinaryHash: byBinaryHash,
	})
	if !p.GrantApplicationEvidenceIfNotUntrusted(registry.ApplicationEvidence{
		SEPublicKey:      sePubB64,
		Serial:           "SERIAL",
		ProcessPublicKey: p.PublicKey,
		APNsToken:        p.APNsDeviceToken,
		BinaryHash:       strings.Repeat("a", 64),
		Version:          p.Version,
		Platform:         "macos-arm64",
		Backend:          p.Backend,
		VerifiedAt:       time.Now(),
		PolicyGeneration: policyGeneration,
	}) {
		t.Fatal("precondition: current generation-bound application evidence was rejected")
	}
}

// TestCrossVersionReuseAboveFloorSameProcessKeyReuses: a healthy update
// (version bump, same SE key + token + process node key, all binary-identity
// fences satisfied, at/above the min-version floor) may ride the recent proof
// across the version change with no new push. A restarted process with a FRESH
// node key is covered separately and transitions via the live resume proof.
func TestCrossVersionReuseAboveFloorSameProcessKeyReuses(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	fastBudgets(srv)
	srv.minProviderVersion = "0.6.0"

	kPubB64, kPriv, seKey, sePubB64 := providerKeyMaterial(t)
	provider := crossVersionProvider(kPubB64, sePubB64, "0.6.14") // bumped, above floor
	seedFreshProcessAttestation(
		srv, sePubB64, "0.6.13", provider.APNsDeviceToken, provider.PublicKey,
		trHashB)
	armCrossVersionApplicationEvidence(t, srv, provider, sePubB64)

	var pushes int32
	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, _, _ string) error {
		atomic.AddInt32(&pushes, 1)
		return nil
	}})
	srv.codeResumeSender = func(
		_ string, message protocol.CodeAttestationResumeChallenge,
	) error {
		return completeResumeRoundTrip(
			t, srv, provider, "p1", kPriv, seKey, message,
		)
	}
	srv.codeAttestLoop(context.Background(), "p1", provider)

	if atomic.LoadInt32(&pushes) != 0 {
		t.Fatal("an exact-process-key version bump must reuse without a new push")
	}
	if !provider.GetCodeAttested() || !provider.GetFreshCodeAttested() {
		t.Fatal("exact-process-key transition reuse must restore fresh code trust")
	}
}

// TestCrossVersionReuseBelowFloorForcesChallenge: a version BELOW the min-provider
// -version floor (a downgrade / disallowed build) must NOT ride the proof — the
// fence closes the downgrade-attestation hole and forces a real challenge.
func TestCrossVersionReuseBelowFloorForcesChallenge(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	fastBudgets(srv)
	srv.minProviderVersion = "0.6.10"

	kPubB64, kPriv, seKey, sePubB64 := providerKeyMaterial(t)

	var pushes int32
	provider := crossVersionProvider(kPubB64, sePubB64, "0.6.0") // DOWNGRADE, below floor
	seedFreshProcessAttestation(
		srv, sePubB64, "0.6.13", provider.APNsDeviceToken, provider.PublicKey,
		trHashB)
	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, pubKeyB64, nonceB64 string) error {
		atomic.AddInt32(&pushes, 1)
		return completeRoundTrip(t, srv, provider, "p1", kPriv, seKey, pubKeyB64, nonceB64)
	}})
	srv.codeAttestLoop(context.Background(), "p1", provider)

	if atomic.LoadInt32(&pushes) == 0 {
		t.Fatal("a below-min-version (downgrade) build must NOT reuse across versions; it must force a real challenge")
	}
}

// TestCrossVersionReuseTokenChangeForcesChallenge: even fully fenced and above the
// floor, a CHANGED APNs token must fail closed (the recorded proof was bound to the
// old token) and force a real challenge.
func TestCrossVersionReuseTokenChangeForcesChallenge(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	fastBudgets(srv)
	srv.minProviderVersion = "0.6.0"

	kPubB64, kPriv, seKey, sePubB64 := providerKeyMaterial(t)
	// Proof bound to the OLD token; the reconnect carries a DIFFERENT token.

	var pushes int32
	provider := crossVersionProvider(kPubB64, sePubB64, "0.6.14")
	provider.APNsDeviceToken = "newtok" // rotated token
	seedFreshProcessAttestation(
		srv, sePubB64, "0.6.13", "oldtok", provider.PublicKey, trHashB)
	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, pubKeyB64, nonceB64 string) error {
		atomic.AddInt32(&pushes, 1)
		return completeRoundTrip(t, srv, provider, "p1", kPriv, seKey, pubKeyB64, nonceB64)
	}})
	srv.codeAttestLoop(context.Background(), "p1", provider)

	if atomic.LoadInt32(&pushes) == 0 {
		t.Fatal("a rotated APNs token must fail closed across versions and force a real challenge")
	}
}

// TestCrossVersionReuseUnfencedForcesChallenge: a version bump WITHOUT the binary
// -identity fences (runtime/manifest/SIP unset) must NOT ride the proof — the SE
// key + token alone are too weak (NodeKeyPair rotates per startup).
func TestCrossVersionReuseUnfencedForcesChallenge(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	fastBudgets(srv)
	srv.minProviderVersion = "0.6.0"

	kPubB64, kPriv, seKey, sePubB64 := providerKeyMaterial(t)

	var pushes int32
	// newCodeAttestProvider sets AttestationResult.Valid but leaves
	// RuntimeVerified / RuntimeManifestChecked / ChallengeVerifiedSIP false.
	provider := newCodeAttestProvider(kPubB64, sePubB64)
	seedFreshProcessAttestation(
		srv, sePubB64, "0.6.13", provider.APNsDeviceToken, provider.PublicKey,
		trHashB)
	provider.Version = "0.6.14"
	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, pubKeyB64, nonceB64 string) error {
		atomic.AddInt32(&pushes, 1)
		return completeRoundTrip(t, srv, provider, "p1", kPriv, seKey, pubKeyB64, nonceB64)
	}})
	srv.codeAttestLoop(context.Background(), "p1", provider)

	if atomic.LoadInt32(&pushes) == 0 {
		t.Fatal("an unfenced (runtime/SIP unverified) version bump must NOT cross-version reuse; it must force a real challenge")
	}
}

// TestCrossVersionReuseEmptyVersionForcesChallenge: an UNVERSIONED provider
// (version optional on the wire) must NOT satisfy a configured MIN_PROVIDER_VERSION
// floor — empty version is treated as below-floor, forcing a real challenge.
func TestCrossVersionReuseEmptyVersionForcesChallenge(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	fastBudgets(srv)
	srv.minProviderVersion = "0.6.0"

	kPubB64, kPriv, seKey, sePubB64 := providerKeyMaterial(t)

	var pushes int32
	provider := crossVersionProvider(kPubB64, sePubB64, "") // NO version reported
	seedFreshProcessAttestation(
		srv, sePubB64, "0.6.13", provider.APNsDeviceToken, provider.PublicKey,
		trHashB)
	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, pubKeyB64, nonceB64 string) error {
		atomic.AddInt32(&pushes, 1)
		return completeRoundTrip(t, srv, provider, "p1", kPriv, seKey, pubKeyB64, nonceB64)
	}})
	srv.codeAttestLoop(context.Background(), "p1", provider)

	if atomic.LoadInt32(&pushes) == 0 {
		t.Fatal("an unversioned provider must NOT satisfy a configured min-version floor; it must force a real challenge")
	}
}

// TestCrossVersionReuseCurrentApplicationEvidenceSameProcessReuses proves that
// current generation-bound application evidence composes with a genuine APNs
// proof from the prior version to authorize a live resume proof of this exact
// process key — never a direct grant.
func TestCrossVersionReuseCurrentApplicationEvidenceSameProcessReuses(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	fastBudgets(srv)
	srv.minProviderVersion = "0.6.0"

	kPubB64, kPriv, seKey, sePubB64 := providerKeyMaterial(t)
	provider := crossVersionProvider(kPubB64, sePubB64, "0.6.14")
	seedFreshProcessAttestation(
		srv, sePubB64, "0.6.13", provider.APNsDeviceToken, provider.PublicKey,
		trHashB)
	armCrossVersionApplicationEvidence(t, srv, provider, sePubB64)
	var pushes int32
	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, _, _ string) error {
		atomic.AddInt32(&pushes, 1)
		return nil
	}})
	srv.codeResumeSender = func(
		_ string, message protocol.CodeAttestationResumeChallenge,
	) error {
		return completeResumeRoundTrip(
			t, srv, provider, "p1", kPriv, seKey, message,
		)
	}

	srv.codeAttestLoop(context.Background(), "p1", provider)

	if !provider.GetCodeAttested() || !provider.GetFreshCodeAttested() {
		t.Fatal("exact-key application evidence did not complete live resume proof")
	}
	if got := atomic.LoadInt32(&pushes); got != 0 {
		t.Fatalf("exact-key transition reuse sent %d new APNs pushes, want 0", got)
	}
}

// TestRestartFreshProcessKeyTransitionsViaResumeWithoutPush reproduces the
// routine upgrade/restart (Codex 05:33Z #1): the provider mints a fresh
// ephemeral NodeKeyPair every process start, so K2 reconnects with the same SE
// identity + APNs token, current generation-bound application evidence
// attesting K2, and a cached genuine proof recorded under K1. That must
// authorize a live encrypted resume challenge to K2 — decrypting it is the
// possession proof for the new key — and re-attest with ZERO new APNs pushes,
// so the device never sits behind the durable 20-minute push floor while
// queued requests expire at 120s.
func TestRestartFreshProcessKeyTransitionsViaResumeWithoutPush(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	fastBudgets(srv)
	srv.minProviderVersion = "0.6.0"

	k1Pub, k1Priv, seKey, sePub := providerKeyMaterial(t)
	k1 := newCodeAttestProvider(k1Pub, sePub)
	k1.Version = "0.6.13"
	// Release A's binary earns the genuine APNs proof; the policy armed below
	// lists release A (trHashB) as an ACTIVE approved predecessor.
	k1.AttestationResult.BinaryHash = trHashB
	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, pubKeyB64, nonceB64 string) error {
		return completeRoundTrip(t, srv, k1, "k1", k1Priv, seKey, pubKeyB64, nonceB64)
	}})
	srv.codeAttestLoop(context.Background(), "k1", k1)
	if !k1.GetFreshCodeAttested() {
		t.Fatal("precondition: K1 did not complete a genuine APNs proof")
	}
	if _, ok := srv.codeAttestThrottle.reuseAttestationForTransition(
		sePub, k1.APNsDeviceToken,
	); !ok {
		t.Fatal("precondition: K1 proof was not cached for this SE identity + token")
	}

	// Restart: fresh X25519 process key, same SE identity + token, fresh
	// SE-signed application evidence for the NEW process key.
	k2Pub, k2Priv, _, _ := providerKeyMaterial(t)
	k2 := crossVersionProvider(k2Pub, sePub, "0.6.14")
	armCrossVersionApplicationEvidence(t, srv, k2, sePub)

	var pushes int32
	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, _, _ string) error {
		atomic.AddInt32(&pushes, 1)
		return nil
	}})
	srv.codeResumeSender = func(
		_ string, message protocol.CodeAttestationResumeChallenge,
	) error {
		// completeResumeRoundTrip asserts no code trust was granted before the
		// live possession proof.
		return completeResumeRoundTrip(t, srv, k2, "k2", k2Priv, seKey, message)
	}
	srv.codeAttestLoop(context.Background(), "k2", k2)

	if got := atomic.LoadInt32(&pushes); got != 0 {
		t.Fatalf("restart transition sent %d APNs pushes, want 0 (resume path)", got)
	}
	if !k2.GetCodeAttested() || !k2.GetFreshCodeAttested() {
		t.Fatal("restarted process did not re-attest via the live resume proof")
	}
}

// TestRestartTransitionWithoutCurrentEvidenceForcesFreshAPNsChallenge preserves
// the transferable-proof defense in its remaining form: a process with the same
// SE identity + token but NO current generation-bound application evidence (an
// unapproved binary cannot earn one) must not ride K1's cached proof — it must
// answer a fresh APNs challenge, and gains no code trust before doing so.
func TestRestartTransitionWithoutCurrentEvidenceForcesFreshAPNsChallenge(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	fastBudgets(srv)
	srv.minProviderVersion = "0.6.0"

	k1Pub, k1Priv, seKey, sePub := providerKeyMaterial(t)
	k1 := newCodeAttestProvider(k1Pub, sePub)
	k1.Version = "0.6.13"
	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, pubKeyB64, nonceB64 string) error {
		return completeRoundTrip(t, srv, k1, "k1", k1Priv, seKey, pubKeyB64, nonceB64)
	}})
	srv.codeAttestLoop(context.Background(), "k1", k1)
	if !k1.GetFreshCodeAttested() {
		t.Fatal("precondition: K1 did not complete a genuine APNs proof")
	}

	k2Pub, k2Priv, _, _ := providerKeyMaterial(t)
	k2 := crossVersionProvider(k2Pub, sePub, "0.6.14")
	// NO application evidence armed for K2.

	if srv.tryCrossVersionReuse(context.Background(), "k2", k2) {
		t.Fatal("evidence-less process rode K1's cached APNs proof")
	}
	if k2.GetCodeAttested() || k2.GetFreshCodeAttested() {
		t.Fatal("K2 gained code trust from the SE+token cache before any proof")
	}

	var k2Pushes int32
	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, pubKeyB64, nonceB64 string) error {
		atomic.AddInt32(&k2Pushes, 1)
		if k2.GetCodeAttested() || k2.GetFreshCodeAttested() {
			t.Error("K2 gained code trust before answering its fresh APNs challenge")
		}
		return completeRoundTrip(t, srv, k2, "k2", k2Priv, seKey, pubKeyB64, nonceB64)
	}})
	srv.codeAttestLoop(context.Background(), "k2", k2)

	if got := atomic.LoadInt32(&k2Pushes); got != 1 {
		t.Fatalf("evidence-less process sent %d fresh APNs challenges, want 1", got)
	}
	if !k2.GetCodeAttested() || !k2.GetFreshCodeAttested() {
		t.Fatal("K2 did not gain code trust after its own live APNs proof")
	}
}

// TestRestartTransitionRotatedTokenRefused: even with current application
// evidence armed, a cached proof bound to a DIFFERENT APNs token never
// authorizes a transition resume — the rotated token must earn a real
// challenge under its own budget/floor.
func TestRestartTransitionRotatedTokenRefused(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	fastBudgets(srv)
	srv.minProviderVersion = "0.6.0"

	kPub, _, _, sePub := providerKeyMaterial(t)
	provider := crossVersionProvider(kPub, sePub, "0.6.14")
	provider.APNsDeviceToken = "newtok"
	// Cached genuine proof was earned under the OLD token (by some process key).
	seedFreshProcessAttestation(srv, sePub, "0.6.13", "oldtok", "old-process-key", trHashB)
	armCrossVersionApplicationEvidence(t, srv, provider, sePub)
	srv.codeResumeSender = func(string, protocol.CodeAttestationResumeChallenge) error {
		t.Error("rotated token must never receive a transition resume challenge")
		return nil
	}

	if srv.tryCrossVersionReuse(context.Background(), "p1", provider) {
		t.Fatal("cached old-token proof authorized a transition for the rotated token")
	}
	if provider.GetCodeAttested() || provider.GetFreshCodeAttested() {
		t.Fatal("rotated token gained code trust without any live proof")
	}
}

// TestRestartTransitionWrongSESignatureRefused: the transition resume challenge
// fails closed when the SE signature over the recovered nonce does not verify
// against the registration-bound SE key — decrypting E_K(nonce) alone (process
// key possession) never grants code trust without the SE identity proof.
func TestRestartTransitionWrongSESignatureRefused(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	fastBudgets(srv)
	srv.minProviderVersion = "0.6.0"
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	kPub, kPriv, _, sePub := providerKeyMaterial(t)
	_, _, wrongSE, _ := providerKeyMaterial(t)
	provider := crossVersionProvider(kPub, sePub, "0.6.14")
	seedFreshProcessAttestation(
		srv, sePub, "0.6.13", provider.APNsDeviceToken, "old-process-key",
		trHashB)
	armCrossVersionApplicationEvidence(t, srv, provider, sePub)
	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, _, _ string) error {
		return nil
	}})
	srv.codeResumeSender = func(
		_ string, message protocol.CodeAttestationResumeChallenge,
	) error {
		// The genuine process key decrypts, but a WRONG SE key signs.
		return completeResumeRoundTrip(t, srv, provider, "p1", kPriv, wrongSE, message)
	}

	if !srv.tryCrossVersionReuse(ctx, "p1", provider) {
		t.Fatal("precondition: transition resume challenge was not even sent")
	}
	if provider.GetCodeAttested() || provider.GetFreshCodeAttested() {
		t.Fatal("a resume reply with an unverifiable SE signature granted code trust")
	}
}

// TestCrossVersionReuseUsesLiveTokenNotCaptured pins the rotation TOCTOU fix:
// cross-version reuse must evaluate the LIVE APNs token under the provider lock,
// not a value captured at loop start. Here the reuse record is bound to the OLD
// token, but the provider's live token has already rotated to a NEW one (as
// maybeRearmCodeAttest publishes under the lock). The grant must NOT fire — the
// old-token proof can't attest the rotated token — so the loop falls through to a
// real challenge. (tryCrossVersionReuse reads st.APNsDeviceToken from the locked
// snapshot, so even if an old loop still holds the stale "oldtok", the decision
// uses the live "newtok" and the reuse match fails.)
func TestCrossVersionReuseUsesLiveTokenNotCaptured(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	fastBudgets(srv)
	srv.minProviderVersion = "0.6.0"

	kPubB64, kPriv, seKey, sePubB64 := providerKeyMaterial(t)
	// Recent proof bound to the OLD token.

	var pushes int32
	provider := crossVersionProvider(kPubB64, sePubB64, "0.6.14")
	provider.APNsDeviceToken = "newtok" // live token already rotated (rotation won the lock)
	seedFreshProcessAttestation(
		srv, sePubB64, "0.6.13", "oldtok", provider.PublicKey, trHashB)
	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, pubKeyB64, nonceB64 string) error {
		atomic.AddInt32(&pushes, 1)
		return completeRoundTrip(t, srv, provider, "p1", kPriv, seKey, pubKeyB64, nonceB64)
	}})

	// Directly exercise the grant decision: it must refuse on the live (new) token.
	if srv.tryCrossVersionReuse(context.Background(), "p1", provider) {
		t.Fatal("cross-version reuse must NOT grant on a record bound to a token different from the LIVE provider token")
	}
	if provider.GetCodeAttested() {
		t.Fatal("CodeAttested must not be set when the live token does not match the reuse record")
	}

	// And the full loop must force a real challenge to attest the new token.
	srv.codeAttestLoop(context.Background(), "p1", provider)
	if atomic.LoadInt32(&pushes) == 0 {
		t.Fatal("a rotated live token must force a real challenge (no cross-version bypass on the old-token proof)")
	}
}

// TestPersistOnAttestWritesThrough proves the write-through half of 2b: a
// successful round-trip persists the reuse record to the store so it survives the
// next restart/deploy.
func TestPersistOnAttestWritesThrough(t *testing.T) {
	logger := quietLogger()
	st := store.NewMemory(store.Config{})
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)
	fastBudgets(srv)
	srv.SeedCodeAttestCache(context.Background()) // wires write-through (empty seed)

	kPubB64, kPriv, seKey, sePubB64 := providerKeyMaterial(t)
	provider := newCodeAttestProvider(kPubB64, sePubB64)
	provider.Version = "0.6.0"
	provider.AttestationResult.BinaryHash = trHashA

	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, pubKeyB64, nonceB64 string) error {
		return completeRoundTrip(t, srv, provider, "p1", kPriv, seKey, pubKeyB64, nonceB64)
	}})
	srv.codeAttestLoop(context.Background(), "p1", provider)
	if !provider.GetCodeAttested() {
		t.Fatal("round-trip should attest")
	}

	// The write-through runs off the read loop (saferun.Go); poll for it.
	ok := waitForCond(2*time.Second, func() bool {
		rows, err := st.ListCodeAttestations(context.Background())
		if err != nil {
			return false
		}
		for _, r := range rows {
			if r.SEPubKey == sePubB64 && r.Version == "0.6.0" && r.BinaryHash == trHashA {
				return true
			}
		}
		return false
	})
	if !ok {
		t.Fatal("a successful attestation must be persisted (write-through) for deploy resilience")
	}
}

// TestRestartTransitionDeactivatedReleaseProofForcesFreshAPNsChallenge closes
// the Codex 05:55Z P1: a genuine APNs proof EARNED by release A must stop
// authorizing transition resumes once A is DEACTIVATED (no longer an approved
// active predecessor of the current release). A compromised process holding
// the device token + SE key that re-earns application evidence for release B
// must answer a real APNs challenge to the CURRENT binary — the cached proof
// never rides across: exactly one real push, and no code trust before its
// verified reply.
func TestRestartTransitionDeactivatedReleaseProofForcesFreshAPNsChallenge(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	fastBudgets(srv)
	srv.minProviderVersion = "0.6.0"

	// K1 earns a genuine APNs proof while running release A (trHashB).
	k1Pub, k1Priv, seKey, sePub := providerKeyMaterial(t)
	k1 := newCodeAttestProvider(k1Pub, sePub)
	k1.Version = "0.6.13"
	k1.AttestationResult.BinaryHash = trHashB
	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, pubKeyB64, nonceB64 string) error {
		return completeRoundTrip(t, srv, k1, "k1", k1Priv, seKey, pubKeyB64, nonceB64)
	}})
	srv.codeAttestLoop(context.Background(), "k1", k1)
	if !k1.GetFreshCodeAttested() {
		t.Fatal("precondition: K1 did not complete a genuine APNs proof")
	}

	// Restart onto release B with release A DEACTIVATED: the ACTIVE inventory
	// holds only the current release (trHashA); trHashB is gone, so it is not
	// an approved predecessor.
	k2Pub, k2Priv, _, _ := providerKeyMaterial(t)
	k2 := crossVersionProvider(k2Pub, sePub, "0.6.14")
	armCrossVersionApplicationEvidenceWithPolicy(t, srv, k2, sePub,
		map[string][]approvedReleasePolicy{
			trHashA: {{Version: k2.Version, Platform: "macos-arm64", Backend: k2.Backend}},
		})
	srv.codeResumeSender = func(string, protocol.CodeAttestationResumeChallenge) error {
		t.Error("a proof earned by a deactivated release must never authorize a transition resume")
		return nil
	}

	if srv.tryCrossVersionReuse(context.Background(), "k2", k2) {
		t.Fatal("deactivated-release proof authorized a transition resume")
	}
	if k2.GetCodeAttested() || k2.GetFreshCodeAttested() {
		t.Fatal("K2 gained code trust without any live proof")
	}

	// The loop must fall through to exactly ONE real APNs challenge, with no
	// code trust granted before its verified reply.
	var k2Pushes int32
	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, pubKeyB64, nonceB64 string) error {
		atomic.AddInt32(&k2Pushes, 1)
		if k2.GetCodeAttested() || k2.GetFreshCodeAttested() {
			t.Error("K2 gained code trust before answering its fresh APNs challenge")
		}
		return completeRoundTrip(t, srv, k2, "k2", k2Priv, seKey, pubKeyB64, nonceB64)
	}})
	srv.codeAttestLoop(context.Background(), "k2", k2)

	if got := atomic.LoadInt32(&k2Pushes); got != 1 {
		t.Fatalf("deactivated-release transition sent %d real APNs challenges, want exactly 1", got)
	}
	if !k2.GetCodeAttested() || !k2.GetFreshCodeAttested() {
		t.Fatal("K2 did not gain code trust after its own live APNs proof")
	}
}

// TestRestartSameBinaryTransitionsViaResumeWithoutPush: a routine process
// restart on the SAME approved binary (fresh ephemeral process key, same SE
// identity + token + binary) still rides the cached genuine proof into a live
// resume challenge — zero new APNs pushes — even when the policy lists no
// predecessor releases at all.
func TestRestartSameBinaryTransitionsViaResumeWithoutPush(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	fastBudgets(srv)
	srv.minProviderVersion = "0.6.0"

	kPub, kPriv, seKey, sePub := providerKeyMaterial(t)
	provider := crossVersionProvider(kPub, sePub, "0.6.14")
	// Cached genuine proof earned under a PRIOR process key by the SAME binary.
	seedFreshProcessAttestation(
		srv, sePub, "0.6.14", provider.APNsDeviceToken, "old-process-key", trHashA)
	armCrossVersionApplicationEvidenceWithPolicy(t, srv, provider, sePub,
		map[string][]approvedReleasePolicy{
			trHashA: {{Version: provider.Version, Platform: "macos-arm64", Backend: provider.Backend}},
		})

	var pushes int32
	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, _, _ string) error {
		atomic.AddInt32(&pushes, 1)
		return nil
	}})
	srv.codeResumeSender = func(
		_ string, message protocol.CodeAttestationResumeChallenge,
	) error {
		return completeResumeRoundTrip(t, srv, provider, "p1", kPriv, seKey, message)
	}
	srv.codeAttestLoop(context.Background(), "p1", provider)

	if got := atomic.LoadInt32(&pushes); got != 0 {
		t.Fatalf("same-binary restart sent %d APNs pushes, want 0 (resume path)", got)
	}
	if !provider.GetCodeAttested() || !provider.GetFreshCodeAttested() {
		t.Fatal("same-binary restart did not re-attest via the live resume proof")
	}
}
