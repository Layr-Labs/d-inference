package api

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"math/big"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/apns"
	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// fakeCodeAttestor simulates APNs in-process — no real Apple push. onSend is
// invoked synchronously by sendCodeIdentityChallenge with the SAME args the
// production APNsPushAttestor would receive; a test supplies an onSend that either
// drops the challenge (to model a lost/late push) or completes the round-trip by
// feeding a code_attestation_response into the coordinator's read-loop delivery
// path (handleCodeAttestationResponse), exactly as a real WebSocket reply would.
//
// mode lets a test exercise the loop's mode-aware budget selection (Fix 3): the
// loop type-asserts Mode() on the attestor to choose the alert vs background push
// cooldown.
type fakeCodeAttestor struct {
	onSend func(deviceToken, env, pubKeyB64, nonceB64 string) error
	mode   apns.Mode
}

func (f *fakeCodeAttestor) SendCodeChallenge(_ context.Context, deviceToken, env, pubKeyB64, nonceB64 string) error {
	return f.onSend(deviceToken, env, pubKeyB64, nonceB64)
}

func (f *fakeCodeAttestor) Mode() apns.Mode { return f.mode }

func quietLogger() *slog.Logger { return slog.New(slog.NewTextHandler(io.Discard, nil)) }

// marshalP256 returns the uncompressed (0x04||X||Y) encoding ParseP256PublicKey expects.
func marshalP256(pub *ecdsa.PublicKey) []byte {
	out := make([]byte, 65)
	out[0] = 0x04
	pub.X.FillBytes(out[1:33])
	pub.Y.FillBytes(out[33:65])
	return out
}

// signSEOverString produces base64(DER ECDSA) over SHA-256(data) — the exact
// shape attestation.VerifyChallengeSignature verifies (and the Swift SE signer
// produces). This stands in for the provider's Sign_SE.
func signSEOverString(t *testing.T, key *ecdsa.PrivateKey, data string) string {
	t.Helper()
	h := sha256.Sum256([]byte(data))
	r, s, err := ecdsa.Sign(rand.Reader, key, h[:])
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	der, err := asn1.Marshal(struct{ R, S *big.Int }{r, s})
	if err != nil {
		t.Fatalf("marshal sig: %v", err)
	}
	return base64.StdEncoding.EncodeToString(der)
}

// providerKeyMaterial generates the two distinct provider keys: the X25519 K
// (encrypt/decrypt only) and the Secure-Enclave P-256 signing key.
func providerKeyMaterial(t *testing.T) (kPubB64 string, kPriv [32]byte, seKey *ecdsa.PrivateKey, sePubB64 string) {
	t.Helper()
	k, err := e2e.GenerateSessionKeys()
	if err != nil {
		t.Fatalf("gen K: %v", err)
	}
	se, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("gen SE: %v", err)
	}
	return base64.StdEncoding.EncodeToString(k.PublicKey[:]), k.PrivateKey, se,
		base64.StdEncoding.EncodeToString(marshalP256(&se.PublicKey))
}

func newCodeAttestProvider(kPubB64, sePubB64 string) *registry.Provider {
	return &registry.Provider{
		ID:                "p1",
		PublicKey:         kPubB64,
		APNsDeviceToken:   "devtok",
		APNsEnvironment:   "production",
		AttestationResult: &attestation.VerificationResult{Valid: true, PublicKey: sePubB64},
	}
}

// completeRoundTrip performs the REAL coordinator-side encrypt + genuine-provider
// decrypt + SE-sign for a pushed nonce, then feeds the reply into the read-loop
// delivery path exactly as a WebSocket code_attestation_response would arrive.
// signKey is the SE key the provider signs with (the genuine key for a passing
// round-trip; a different key to model a fork). deliverTo is the connection that
// the reply lands on (the same provider normally, a DIFFERENT one for reconnect).
func completeRoundTrip(t *testing.T, srv *Server, deliverTo *registry.Provider, deliverID string, kPriv [32]byte, signKey *ecdsa.PrivateKey, pubKeyB64, nonceB64 string) error {
	t.Helper()
	payload, err := apns.BuildCodeChallengePayload(nonceB64, pubKeyB64, apns.ModeBackground)
	if err != nil {
		return err
	}
	var body struct {
		CodeChallenge e2e.EncryptedPayload `json:"code_challenge"`
	}
	if err := json.Unmarshal(payload, &body); err != nil {
		return err
	}
	recovered, err := e2e.DecryptWithPrivateKey(&body.CodeChallenge, kPriv)
	if err != nil {
		return err
	}
	srv.handleCodeAttestationResponse(deliverID, deliverTo, &protocol.CodeAttestationResponseMessage{
		Type:      protocol.TypeCodeAttestationResponse,
		Nonce:     string(recovered),
		Signature: signSEOverString(t, signKey, string(recovered)),
	})
	return nil
}

// TestCodeIdentityRoundTripEndToEnd is the correctness gate: the full crypto
// round-trip — coordinator generates a nonce → real E_K(nonce) encrypt → genuine-
// provider decrypt with K → Sign_SE over the recovered nonce → WS reply verified
// in the read-loop delivery path → CodeAttested flips true.
func TestCodeIdentityRoundTripEndToEnd(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)

	kPubB64, kPriv, seKey, sePubB64 := providerKeyMaterial(t)
	provider := newCodeAttestProvider(kPubB64, sePubB64)

	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, pubKeyB64, nonceB64 string) error {
		return completeRoundTrip(t, srv, provider, "p1", kPriv, seKey, pubKeyB64, nonceB64)
	}})

	srv.sendCodeIdentityChallenge(context.Background(), "p1", provider)

	if !provider.GetCodeAttested() {
		t.Fatal("expected CodeAttested=true after a valid end-to-end round-trip")
	}
}

// TestCodeIdentityRejectsWrongSEKey proves fail-closed: a response whose nonce
// decrypts correctly (proving K) but is signed by a DIFFERENT SE key (not the one
// bound at registration) must NOT attest — defending against a fork that received
// a relayed challenge but holds its own SE key.
func TestCodeIdentityRejectsWrongSEKey(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)

	kPubB64, kPriv, _, sePubB64 := providerKeyMaterial(t)
	wrongSE, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("gen wrong SE: %v", err)
	}
	provider := newCodeAttestProvider(kPubB64, sePubB64) // bound to the REAL SE key

	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, pubKeyB64, nonceB64 string) error {
		// Decrypts fine (proves K), but signs with the WRONG SE key.
		return completeRoundTrip(t, srv, provider, "p1", kPriv, wrongSE, pubKeyB64, nonceB64)
	}})

	srv.sendCodeIdentityChallenge(context.Background(), "p1", provider)

	if provider.GetCodeAttested() {
		t.Fatal("CodeAttested must stay false when the SE signature is from the wrong key")
	}
}

// TestCodeAttestLoopHealsDroppedPushWithBoundedRetry proves a single dropped push
// doesn't strand a capable provider: the first push fails and the loop retries
// (spaced by the per-device budget — NOT a fixed ticker) and attests, staying
// within the push budget (bounded by maxAttempts).
func TestCodeAttestLoopHealsDroppedPushWithBoundedRetry(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	srv.codeAttestThrottle.backgroundPushCooldown = time.Millisecond // fast budget for the test
	srv.codeAttestThrottle.retrySpacing = time.Millisecond           // fast poll cadence
	srv.codeAttestThrottle.retryJitter = 0

	kPubB64, kPriv, seKey, sePubB64 := providerKeyMaterial(t)
	provider := newCodeAttestProvider(kPubB64, sePubB64)

	var pushes int32
	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, pubKeyB64, nonceB64 string) error {
		if atomic.AddInt32(&pushes, 1) == 1 {
			return errors.New("transient push send failure") // first push fails
		}
		return completeRoundTrip(t, srv, provider, "p1", kPriv, seKey, pubKeyB64, nonceB64)
	}})

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	srv.codeAttestLoop(ctx, "p1", provider)

	if !provider.GetCodeAttested() {
		t.Fatal("expected CodeAttested=true after a bounded retry healed the dropped first push")
	}
	if got := atomic.LoadInt32(&pushes); got < 2 || got > int32(srv.codeAttestThrottle.maxAttempts) {
		t.Fatalf("expected 2..%d pushes, got %d", srv.codeAttestThrottle.maxAttempts, got)
	}
}

// TestCodeAttestLoopReusesRecentAttestation proves a reconnect from the same
// device (same SE key + binary version) within the reuse window inherits the proof
// with NO additional push — respecting Apple's ~3/hour background-push budget.
func TestCodeAttestLoopReusesRecentAttestation(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	srv.codeAttestThrottle.retrySpacing = time.Millisecond
	srv.codeAttestThrottle.retryJitter = 0

	kPubB64, kPriv, seKey, sePubB64 := providerKeyMaterial(t)

	var pushes int32
	// onSend completes the round-trip for whichever provider is currently attesting.
	var current *registry.Provider
	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, pubKeyB64, nonceB64 string) error {
		atomic.AddInt32(&pushes, 1)
		return completeRoundTrip(t, srv, current, "p1", kPriv, seKey, pubKeyB64, nonceB64)
	}})

	// Connection 1: a real round-trip → exactly one push, attested.
	p1 := newCodeAttestProvider(kPubB64, sePubB64)
	p1.Version = "0.6.0"
	current = p1
	srv.codeAttestLoop(context.Background(), "p1", p1)
	if !p1.GetCodeAttested() {
		t.Fatal("connection 1 should attest")
	}
	if got := atomic.LoadInt32(&pushes); got != 1 {
		t.Fatalf("connection 1 should send exactly 1 push, got %d", got)
	}

	// Connection 2: same device + version, fresh Provider (CodeAttested=false). It
	// must REUSE the recent attestation — attested without another push.
	p2 := newCodeAttestProvider(kPubB64, sePubB64)
	p2.Version = "0.6.0"
	current = p2
	srv.codeAttestLoop(context.Background(), "p1", p2)
	if !p2.GetCodeAttested() {
		t.Fatal("connection 2 should inherit the recent attestation (reuse)")
	}
	if got := atomic.LoadInt32(&pushes); got != 1 {
		t.Fatalf("connection 2 must NOT send another push (reuse); total pushes=%d", got)
	}
}

// TestCodeAttestLateReplyOnLiveConnectionStillAttests proves Fix 1 + Fix 5: a
// reply arriving long after the old 90s blocking wait — but on a live connection
// and within the (widened) challenge validity window — still attests, because
// verification now happens in the read-loop delivery path rather than a goroutine
// that times out at 90s. The complementary case proves the validity bound stays
// fail-closed: a reply past the window is rejected.
func TestCodeAttestLateReplyOnLiveConnectionStillAttests(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)

	cur := time.Unix(1_700_000_000, 0)
	srv.codeAttestThrottle.now = func() time.Time { return cur }

	kPubB64, _, seKey, sePubB64 := providerKeyMaterial(t)

	// Capture the pushed nonce; do NOT deliver during the push (model a sleepy
	// device that answers later).
	var pushedNonce string
	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, _, nonceB64 string) error {
		pushedNonce = nonceB64
		return nil
	}})

	// Case A: reply 91s later (was > the old 90s wait) but inside the 300s window.
	provider := newCodeAttestProvider(kPubB64, sePubB64)
	srv.sendCodeIdentityChallenge(context.Background(), "p1", provider)
	if provider.GetCodeAttested() {
		t.Fatal("must not attest before any reply arrives")
	}
	cur = cur.Add(91 * time.Second)
	srv.handleCodeAttestationResponse("p1", provider, &protocol.CodeAttestationResponseMessage{
		Type:      protocol.TypeCodeAttestationResponse,
		Nonce:     pushedNonce,
		Signature: signSEOverString(t, seKey, pushedNonce),
	})
	if !provider.GetCodeAttested() {
		t.Fatal("a reply 91s later on a live connection must still attest (Fix 1 + Fix 5)")
	}

	// Case B: a reply past the validity window must be rejected (fail-closed).
	cur = cur.Add(time.Hour)
	late := newCodeAttestProvider(kPubB64, sePubB64)
	srv.sendCodeIdentityChallenge(context.Background(), "p1", late)
	cur = cur.Add(srv.codeAttestThrottle.challengeValidity + time.Second)
	srv.handleCodeAttestationResponse("p1", late, &protocol.CodeAttestationResponseMessage{
		Type:      protocol.TypeCodeAttestationResponse,
		Nonce:     pushedNonce,
		Signature: signSEOverString(t, seKey, pushedNonce),
	})
	if late.GetCodeAttested() {
		t.Fatal("a reply past the challenge validity window must not attest (fail-closed staleness)")
	}
}

// TestCodeAttestReconnectMidFlightDoesNotStrand proves Fix 1 kills the connection-
// scoped strand: a challenge pushed on connection 1 is verified when its reply
// lands on connection 2 (a reconnect from the SAME device), with NO second push —
// because the pushed nonce is tracked per-device (by SE key), not per-connection.
func TestCodeAttestReconnectMidFlightDoesNotStrand(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)

	kPubB64, _, seKey, sePubB64 := providerKeyMaterial(t)

	var pushes int32
	var pushedNonce string
	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, _, nonceB64 string) error {
		atomic.AddInt32(&pushes, 1)
		pushedNonce = nonceB64 // push goes out, but conn 1 drops before replying
		return nil
	}})

	// Connection 1 pushes a challenge, then "drops" before the reply.
	conn1 := newCodeAttestProvider(kPubB64, sePubB64)
	srv.sendCodeIdentityChallenge(context.Background(), "conn1", conn1)
	if conn1.GetCodeAttested() {
		t.Fatal("conn1 must not be attested (it dropped before replying)")
	}

	// Connection 2 is a fresh connection from the SAME device (same SE key). The
	// provider's reply to conn1's challenge now lands here.
	conn2 := newCodeAttestProvider(kPubB64, sePubB64)
	srv.handleCodeAttestationResponse("conn2", conn2, &protocol.CodeAttestationResponseMessage{
		Type:      protocol.TypeCodeAttestationResponse,
		Nonce:     pushedNonce,
		Signature: signSEOverString(t, seKey, pushedNonce),
	})

	if !conn2.GetCodeAttested() {
		t.Fatal("a reply on a reconnected socket must attest the live connection (no strand)")
	}
	if got := atomic.LoadInt32(&pushes); got != 1 {
		t.Fatalf("reconnect must NOT burn another push; pushes=%d", got)
	}
}

// TestCodeAttestNoTokenNeverAttests is the fail-closed gate for a provider with no
// APNs device token (legacy/headless): the loop exits immediately, never pushes,
// and the connection never attests.
func TestCodeAttestNoTokenNeverAttests(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)

	kPubB64, _, _, sePubB64 := providerKeyMaterial(t)
	provider := newCodeAttestProvider(kPubB64, sePubB64)
	provider.APNsDeviceToken = "" // no token → cannot be challenged

	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, _, _ string) error {
		t.Fatal("must not push when the provider has no APNs token")
		return nil
	}})

	srv.codeAttestLoop(context.Background(), "p1", provider)
	if provider.GetCodeAttested() {
		t.Fatal("a provider with no APNs token must never attest (fail-closed)")
	}
}

// TestCodeAttestTimeoutNeverAttests is the fail-closed gate for a delivered push
// that is never answered: the loop pushes up to maxAttempts and gives up without
// attesting.
func TestCodeAttestTimeoutNeverAttests(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	srv.codeAttestThrottle.maxAttempts = 2
	srv.codeAttestThrottle.backgroundPushCooldown = time.Millisecond
	srv.codeAttestThrottle.retrySpacing = time.Millisecond
	srv.codeAttestThrottle.retryJitter = 0

	kPubB64, _, _, sePubB64 := providerKeyMaterial(t)
	provider := newCodeAttestProvider(kPubB64, sePubB64)

	var pushes int32
	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, _, _ string) error {
		atomic.AddInt32(&pushes, 1) // push accepted, but the provider never replies
		return nil
	}})

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	srv.codeAttestLoop(ctx, "p1", provider)

	if provider.GetCodeAttested() {
		t.Fatal("an unanswered challenge must never attest (fail-closed)")
	}
	if got := atomic.LoadInt32(&pushes); got != int32(srv.codeAttestThrottle.maxAttempts) {
		t.Fatalf("expected exactly maxAttempts=%d pushes, got %d", srv.codeAttestThrottle.maxAttempts, got)
	}
}

// TestCodeAttestLoopAlertModeUsesShortBudget proves Fix 3: in alert mode the loop
// retries on the (short) alert push budget, not the (long) background budget. The
// background budget is set to an hour and the alert budget to ~nothing; if the loop
// used the background budget it could never heal the dropped first push within the
// test deadline.
func TestCodeAttestLoopAlertModeUsesShortBudget(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	srv.codeAttestThrottle.alertPushCooldown = time.Millisecond
	srv.codeAttestThrottle.backgroundPushCooldown = time.Hour // would strand if used
	srv.codeAttestThrottle.retrySpacing = time.Millisecond
	srv.codeAttestThrottle.retryJitter = 0

	kPubB64, kPriv, seKey, sePubB64 := providerKeyMaterial(t)
	provider := newCodeAttestProvider(kPubB64, sePubB64)

	var pushes int32
	srv.SetCodeAttestor(&fakeCodeAttestor{
		mode: apns.ModeAlert,
		onSend: func(_, _, pubKeyB64, nonceB64 string) error {
			if atomic.AddInt32(&pushes, 1) == 1 {
				return errors.New("transient push send failure") // first push fails
			}
			return completeRoundTrip(t, srv, provider, "p1", kPriv, seKey, pubKeyB64, nonceB64)
		},
	})

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	srv.codeAttestLoop(ctx, "p1", provider)

	if !provider.GetCodeAttested() {
		t.Fatal("alert mode must retry on the short alert budget and heal within the deadline")
	}
}
