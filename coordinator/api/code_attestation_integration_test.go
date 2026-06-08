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
	"io"
	"log/slog"
	"math/big"
	"testing"

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
