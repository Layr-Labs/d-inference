package api

import (
	"context"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"sync/atomic"
	"testing"
)

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
	srvControls := fastBudgets(srv)
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
	if _, ok := srv.codeIdentity.TransitionBinaryHash(
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
	srvControls.resumeSender = func(
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
	srvControls := fastBudgets(srv)
	srv.minProviderVersion = "0.6.0"

	kPub, _, _, sePub := providerKeyMaterial(t)
	provider := crossVersionProvider(kPub, sePub, "0.6.14")
	provider.APNsDeviceToken = "newtok"
	// Cached genuine proof was earned under the OLD token (by some process key).
	seedFreshProcessAttestation(t, srv, sePub, "0.6.13", "oldtok", "old-process-key", trHashB)
	armCrossVersionApplicationEvidence(t, srv, provider, sePub)
	srvControls.resumeSender = func(string, protocol.CodeAttestationResumeChallenge) error {
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
	srvControls := fastBudgets(srv)
	srv.minProviderVersion = "0.6.0"
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	kPub, kPriv, _, sePub := providerKeyMaterial(t)
	_, _, wrongSE, _ := providerKeyMaterial(t)
	provider := crossVersionProvider(kPub, sePub, "0.6.14")
	seedFreshProcessAttestation(t,
		srv, sePub, "0.6.13", provider.APNsDeviceToken, "old-process-key",
		trHashB)
	armCrossVersionApplicationEvidence(t, srv, provider, sePub)
	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, _, _ string) error {
		return nil
	}})
	srvControls.resumeSender = func(
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
	srvControls := fastBudgets(srv)
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
	srvControls.resumeSender = func(string, protocol.CodeAttestationResumeChallenge) error {
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
	srvControls := fastBudgets(srv)
	srv.minProviderVersion = "0.6.0"

	kPub, kPriv, seKey, sePub := providerKeyMaterial(t)
	provider := crossVersionProvider(kPub, sePub, "0.6.14")
	// Cached genuine proof earned under a PRIOR process key by the SAME binary.
	seedFreshProcessAttestation(t,
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
	srvControls.resumeSender = func(
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
