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

// fakeCodeAttestor simulates the FULL APNs round-trip in-process — no real APNs.
// On SendCodeChallenge it (1) builds the REAL E_K(nonce) payload exactly as the
// production APNsPushAttestor would (exercising the coordinator encrypt path),
// then (2) simulates the genuine provider: decrypts with K, signs the recovered
// nonce with the SE key, and delivers a code_attestation_response into the
// tracker exactly as the WebSocket read loop does on a real reply.
type fakeCodeAttestor struct {
	onSend func(deviceToken, env, pubKeyB64, nonceB64 string) error
}

func (f *fakeCodeAttestor) SendCodeChallenge(_ context.Context, deviceToken, env, pubKeyB64, nonceB64 string) error {
	return f.onSend(deviceToken, env, pubKeyB64, nonceB64)
}

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

// TestCodeIdentityRoundTripEndToEnd is the Phase 3 correctness gate: the full
// crypto round-trip — coordinator generates a nonce → real E_K(nonce) encrypt →
// genuine-provider decrypt with K → Sign_SE over the recovered nonce → WS reply →
// coordinator verifies (nonce match + SE signature) → CodeAttested flips true.
func TestCodeIdentityRoundTripEndToEnd(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)

	kPubB64, kPriv, seKey, sePubB64 := providerKeyMaterial(t)
	ct := newCodeAttestTracker()

	fake := &fakeCodeAttestor{onSend: func(_, _, pubKeyB64, nonceB64 string) error {
		// (1) Real coordinator-side build: E_K(nonce) via the inference E2E path.
		payload, err := apns.BuildCodeChallengePayload(nonceB64, pubKeyB64, apns.ModeBackground)
		if err != nil {
			return err
		}
		// (2) Genuine provider sim: decrypt code_challenge with K's private key.
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
		// Sign the recovered nonce with the SE key and reply over the WS (tracker).
		sig := signSEOverString(t, seKey, string(recovered))
		go ct.deliver(&protocol.CodeAttestationResponseMessage{
			Type:      protocol.TypeCodeAttestationResponse,
			Nonce:     string(recovered),
			Signature: sig,
		})
		return nil
	}}
	srv.SetCodeAttestor(fake)

	provider := newCodeAttestProvider(kPubB64, sePubB64)
	srv.sendCodeIdentityChallenge(context.Background(), "p1", provider, ct)

	if !provider.GetCodeAttested() {
		t.Fatal("expected CodeAttested=true after a valid end-to-end round-trip")
	}
}

// TestCodeIdentityRejectsWrongSEKey proves fail-closed: a response whose nonce
// decrypts correctly (proving K) but is signed by a DIFFERENT SE key (not the
// one bound at registration) must NOT attest — defending against a fork that
// received a relayed challenge but holds its own SE key.
func TestCodeIdentityRejectsWrongSEKey(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)

	kPubB64, kPriv, _, sePubB64 := providerKeyMaterial(t)
	wrongSE, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("gen wrong SE: %v", err)
	}
	ct := newCodeAttestTracker()

	fake := &fakeCodeAttestor{onSend: func(_, _, pubKeyB64, nonceB64 string) error {
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
		// Signed by the WRONG SE key — must fail verification.
		sig := signSEOverString(t, wrongSE, string(recovered))
		go ct.deliver(&protocol.CodeAttestationResponseMessage{
			Type:      protocol.TypeCodeAttestationResponse,
			Nonce:     string(recovered),
			Signature: sig,
		})
		return nil
	}}
	srv.SetCodeAttestor(fake)

	provider := newCodeAttestProvider(kPubB64, sePubB64) // bound to the REAL SE key
	srv.sendCodeIdentityChallenge(context.Background(), "p1", provider, ct)

	if provider.GetCodeAttested() {
		t.Fatal("CodeAttested must stay false when the SE signature is from the wrong key")
	}
}

// fullCodeAttestRoundTrip returns an onSend that completes a valid challenge
// round-trip (decrypt the nonce, SE-sign it, deliver the response), counting the
// pushes it actually sends into `pushes`.
func fullCodeAttestRoundTrip(t *testing.T, kPriv [32]byte, seKey *ecdsa.PrivateKey, ct *codeAttestTracker, pushes *int32) func(_, _, _, _ string) error {
	return func(_, _, pubKeyB64, nonceB64 string) error {
		atomic.AddInt32(pushes, 1)
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
		sig := signSEOverString(t, seKey, string(recovered))
		go ct.deliver(&protocol.CodeAttestationResponseMessage{
			Type:      protocol.TypeCodeAttestationResponse,
			Nonce:     string(recovered),
			Signature: sig,
		})
		return nil
	}
}

// TestCodeAttestLoopHealsDroppedPushWithBoundedRetry proves a single dropped
// background push doesn't strand a capable provider: the first push fails and the
// loop retries (spaced by the per-device cooldown — NOT a fixed 5-min ticker) and
// attests. It must stay within the push budget (bounded by maxAttempts).
func TestCodeAttestLoopHealsDroppedPushWithBoundedRetry(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	srv.codeAttestThrottle.pushCooldown = time.Millisecond // fast retry spacing for the test

	kPubB64, kPriv, seKey, sePubB64 := providerKeyMaterial(t)
	ct := newCodeAttestTracker()

	var attempts int32
	roundTrip := fullCodeAttestRoundTrip(t, kPriv, seKey, ct, &attempts)
	fake := &fakeCodeAttestor{onSend: func(a, b, pubKeyB64, nonceB64 string) error {
		if atomic.LoadInt32(&attempts) == 0 {
			atomic.AddInt32(&attempts, 1)
			return errors.New("transient push send failure") // first push fails
		}
		return roundTrip(a, b, pubKeyB64, nonceB64)
	}}
	srv.SetCodeAttestor(fake)

	provider := newCodeAttestProvider(kPubB64, sePubB64)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go srv.codeAttestLoop(ctx, "p1", provider, ct)

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) && !provider.GetCodeAttested() {
		time.Sleep(5 * time.Millisecond)
	}
	if !provider.GetCodeAttested() {
		t.Fatal("expected CodeAttested=true after a bounded retry healed the dropped first push")
	}
	if got := atomic.LoadInt32(&attempts); got < 2 || got > int32(srv.codeAttestThrottle.maxAttempts) {
		t.Fatalf("expected 2..%d attempts, got %d", srv.codeAttestThrottle.maxAttempts, got)
	}
}

// TestCodeAttestLoopReusesRecentAttestation proves a reconnect from the same
// device (same SE key + binary version) within the reuse window inherits the
// proof with NO additional push — respecting Apple's ~3/hour background-push
// budget instead of re-challenging on every connection.
func TestCodeAttestLoopReusesRecentAttestation(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)

	kPubB64, kPriv, seKey, sePubB64 := providerKeyMaterial(t)
	ct := newCodeAttestTracker()

	var pushes int32
	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: fullCodeAttestRoundTrip(t, kPriv, seKey, ct, &pushes)})

	// Connection 1: a real round-trip → exactly one push, attested.
	p1 := newCodeAttestProvider(kPubB64, sePubB64)
	p1.Version = "0.6.0"
	srv.codeAttestLoop(context.Background(), "p1", p1, ct)
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
	srv.codeAttestLoop(context.Background(), "p1", p2, ct)
	if !p2.GetCodeAttested() {
		t.Fatal("connection 2 should inherit the recent attestation (reuse)")
	}
	if got := atomic.LoadInt32(&pushes); got != 1 {
		t.Fatalf("connection 2 must NOT send another push (reuse); total pushes=%d", got)
	}
}

// TestCodeAttestThrottleBudgetAndReuse covers the rate-limit + reuse logic with a
// fake clock: pushes are blocked within the cooldown, and a recent attestation is
// reused only within the window and only for the same binary version.
func TestCodeAttestThrottleBudgetAndReuse(t *testing.T) {
	cur := time.Unix(1_700_000_000, 0)
	th := newCodeAttestThrottle()
	th.now = func() time.Time { return cur }
	const se = "se-key-1"

	if !th.allowPush(se) {
		t.Fatal("first push should be allowed")
	}
	if th.reuseAttestation(se, "0.6.0") {
		t.Fatal("no attestation yet → no reuse")
	}
	th.recordPush(se)

	cur = cur.Add(th.pushCooldown - time.Minute) // still inside the cooldown
	if th.allowPush(se) {
		t.Fatal("a push within the cooldown must be blocked (background-push budget)")
	}
	cur = cur.Add(2 * time.Minute) // now just past the cooldown
	if !th.allowPush(se) {
		t.Fatal("a push after the cooldown should be allowed")
	}

	th.recordAttested(se, "0.6.0")
	if !th.reuseAttestation(se, "0.6.0") {
		t.Fatal("should reuse a fresh, same-version attestation")
	}
	if th.reuseAttestation(se, "0.6.1") {
		t.Fatal("must NOT reuse across a binary version change")
	}
	cur = cur.Add(th.reuseWindow) // window elapsed
	if th.reuseAttestation(se, "0.6.0") {
		t.Fatal("reuse must expire after the window")
	}
}
