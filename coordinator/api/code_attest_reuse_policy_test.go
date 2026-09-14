package api

import (
	"context"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"sync/atomic"
	"testing"
)

// TestCrossVersionReuseAboveFloorSameProcessKeyReuses: a healthy update
// (version bump, same SE key + token + process node key, all binary-identity
// fences satisfied, at/above the min-version floor) may ride the recent proof
// across the version change with no new push. A restarted process with a FRESH
// node key is covered separately and transitions via the live resume proof.
func TestCrossVersionReuseAboveFloorSameProcessKeyReuses(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	srvControls := fastBudgets(srv)
	srv.minProviderVersion = "0.6.0"

	kPubB64, kPriv, seKey, sePubB64 := providerKeyMaterial(t)
	provider := crossVersionProvider(kPubB64, sePubB64, "0.6.14") // bumped, above floor
	seedFreshProcessAttestation(t,
		srv, sePubB64, "0.6.13", provider.APNsDeviceToken, provider.PublicKey,
		trHashB)
	armCrossVersionApplicationEvidence(t, srv, provider, sePubB64)

	var pushes int32
	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, _, _ string) error {
		atomic.AddInt32(&pushes, 1)
		return nil
	}})
	srvControls.resumeSender = func(
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
	seedFreshProcessAttestation(t,
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
	seedFreshProcessAttestation(t,
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
	seedFreshProcessAttestation(t,
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
	seedFreshProcessAttestation(t,
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
	srvControls := fastBudgets(srv)
	srv.minProviderVersion = "0.6.0"

	kPubB64, kPriv, seKey, sePubB64 := providerKeyMaterial(t)
	provider := crossVersionProvider(kPubB64, sePubB64, "0.6.14")
	seedFreshProcessAttestation(t,
		srv, sePubB64, "0.6.13", provider.APNsDeviceToken, provider.PublicKey,
		trHashB)
	armCrossVersionApplicationEvidence(t, srv, provider, sePubB64)
	var pushes int32
	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, _, _ string) error {
		atomic.AddInt32(&pushes, 1)
		return nil
	}})
	srvControls.resumeSender = func(
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
	seedFreshProcessAttestation(t,
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
