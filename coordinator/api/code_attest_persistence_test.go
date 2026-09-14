package api

import (
	"context"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"sync/atomic"
	"testing"
	"time"
)

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
// cross-version reuse path is covered by TestCrossVersionReuse* in code_attest_reuse_policy_test.go.
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

// TestHashlessRegistrationPersistsApplicationEvidenceHashForRestartReuse
// models the production registration shape: the registration result carries no
// binary hash, while the current SE-signed application evidence binds the
// measured application hash to this exact SE identity and process key. A genuine
// APNs nonce/signature round-trip must cache and persist that approved hash so a
// coordinator restart can seed it and resume without another APNs push.
func TestHashlessRegistrationPersistsApplicationEvidenceHashForRestartReuse(t *testing.T) {
	logger := quietLogger()
	st := store.NewMemory(store.Config{})
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)
	fastBudgets(srv)
	srv.SeedCodeAttestCache(context.Background())

	kPubB64, kPriv, seKey, sePubB64 := providerKeyMaterial(t)
	provider := newCodeAttestProvider(kPubB64, sePubB64)
	provider.Version = "0.8.17"
	provider.AttestationResult.BinaryHash = ""
	provider.ApplicationEvidence = registry.ApplicationEvidence{
		SEPublicKey:        sePubB64,
		ProcessPublicKey:   kPubB64,
		BinaryHash:         trHashA,
		EvidenceGeneration: 1,
	}

	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, pubKeyB64, nonceB64 string) error {
		return completeRoundTrip(t, srv, provider, "p1", kPriv, seKey, pubKeyB64, nonceB64)
	}})
	srv.codeAttestLoop(context.Background(), "p1", provider)
	if !provider.GetFreshCodeAttested() {
		t.Fatal("production-shape hashless registration did not complete its genuine APNs proof")
	}
	if got, ok := srv.codeAttestThrottle.reuseAttestationForTransition(
		sePubB64, provider.APNsDeviceToken,
	); !ok || got != trHashA {
		t.Fatalf("in-memory APNs proof binary hash = %q, ok=%v; want application hash %q", got, ok, trHashA)
	}

	if !waitForCond(2*time.Second, func() bool {
		rows, err := st.ListCodeAttestations(context.Background())
		if err != nil {
			return false
		}
		for _, row := range rows {
			if row.SEPubKey == sePubB64 && row.Version == provider.Version &&
				row.APNsToken == provider.APNsDeviceToken &&
				row.NodePublicKey == kPubB64 && row.BinaryHash == trHashA {
				return true
			}
		}
		return false
	}) {
		t.Fatal("durable CodeAttestation did not retain the current application evidence hash")
	}

	restarted := NewServer(registry.New(logger), st, ServerConfig{}, logger)
	fastBudgets(restarted)
	restarted.SeedCodeAttestCache(context.Background())
	if got, ok := restarted.codeAttestThrottle.reuseAttestationForTransition(
		sePubB64, provider.APNsDeviceToken,
	); !ok || got != trHashA {
		t.Fatalf("restart-seeded APNs proof binary hash = %q, ok=%v; want %q", got, ok, trHashA)
	}

	// Restart with a fresh process key. The persisted proof must compose with
	// current generation-bound application evidence and authorize a live resume;
	// exact-key reuse would not exercise the binary identity carried by this fix.
	k2Pub, k2Priv, _, _ := providerKeyMaterial(t)
	reconnected := crossVersionProvider(k2Pub, sePubB64, provider.Version)
	reconnected.AttestationResult.BinaryHash = ""
	armCrossVersionApplicationEvidenceWithPolicy(t, restarted, reconnected, sePubB64,
		map[string][]approvedReleasePolicy{
			trHashA: {{Version: provider.Version, Platform: "macos-arm64", Backend: provider.Backend}},
		})
	var pushes int32
	restarted.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, _, _ string) error {
		atomic.AddInt32(&pushes, 1)
		return nil
	}})
	restarted.codeResumeSender = func(
		_ string, message protocol.CodeAttestationResumeChallenge,
	) error {
		return completeResumeRoundTrip(
			t, restarted, reconnected, "p1", k2Priv, seKey, message)
	}
	restarted.codeAttestLoop(context.Background(), "p1", reconnected)
	if got := atomic.LoadInt32(&pushes); got != 0 {
		t.Fatalf("restart-seeded proof sent %d APNs pushes, want 0", got)
	}
	if !reconnected.GetCodeAttested() || !reconnected.GetFreshCodeAttested() {
		t.Fatal("restart-seeded proof did not complete the live process-key resume")
	}
}

// TestHashlessRegistrationWithoutApplicationEvidenceRemainsIdentityless
// preserves the fail-closed boundary: a valid APNs proof still attests the live
// process, but without either binary-identity source it cannot become a release-
// transition proof.
func TestHashlessRegistrationWithoutApplicationEvidenceRemainsIdentityless(t *testing.T) {
	logger := quietLogger()
	st := store.NewMemory(store.Config{})
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)
	fastBudgets(srv)
	srv.SeedCodeAttestCache(context.Background())

	kPubB64, kPriv, seKey, sePubB64 := providerKeyMaterial(t)
	provider := newCodeAttestProvider(kPubB64, sePubB64)
	provider.Version = "0.8.17"
	provider.AttestationResult.BinaryHash = ""
	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, pubKeyB64, nonceB64 string) error {
		return completeRoundTrip(t, srv, provider, "p1", kPriv, seKey, pubKeyB64, nonceB64)
	}})
	srv.codeAttestLoop(context.Background(), "p1", provider)
	if !provider.GetFreshCodeAttested() {
		t.Fatal("identity-less registration did not complete its genuine APNs proof")
	}
	if hash, ok := srv.codeAttestThrottle.reuseAttestationForTransition(
		sePubB64, provider.APNsDeviceToken,
	); ok || hash != "" {
		t.Fatalf("identity-less proof authorized transition reuse: hash=%q ok=%v", hash, ok)
	}

	if !waitForCond(2*time.Second, func() bool {
		rows, err := st.ListCodeAttestations(context.Background())
		return err == nil && len(rows) == 1 && rows[0].BinaryHash == ""
	}) {
		t.Fatal("identity-less APNs proof was not persisted without manufacturing a binary hash")
	}
}
