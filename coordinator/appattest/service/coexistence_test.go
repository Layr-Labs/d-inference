package service

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"io"
	"log/slog"
	"reflect"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/fxamacker/cbor/v2"
)

func TestShadowProofsNeverMutateLegacyTrust(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	st := store.NewMemory(store.Config{})
	p := newSessionProvider(base64.StdEncoding.EncodeToString(make([]byte, 32)), "se")
	p.Status, p.TrustLevel, p.CodeAttested, p.RuntimeVerified = registry.StatusOnline, registry.TrustHardware, true, true
	s := &Service{store: st, logger: slog.New(slog.NewTextHandler(io.Discard, nil)), config: Config{Enabled: true, AppID: "TEST.app", Environment: "production"}}
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	public := elliptic.Marshal(key.Curve, key.X, key.Y)
	record := &store.AppAttestShadowKey{KeyID: "test-key", Owner: "test-owner", PublicKey: public, AppID: "TEST.app", Environment: "production"}
	_, err := st.InsertAppAttestShadowKey(ctx, *record)
	if err != nil {
		t.Fatal(err)
	}
	x := &Session{s: s, provider: p, in: make(chan protocol.AppAttestShadowPayload, 2), id: "test-session", owner: "test-owner", publicKey: p.PublicKey, version: "0.9.0", key: record, challenge: "fresh", expected: "assertion", store: st, verifier: appattest.New(appattest.Policy{AppID: "TEST.app", Environment: "production"})}
	snapshot := func() []any {
		p.Mu().Lock()
		defer p.Mu().Unlock()
		return []any{p.Status, p.TrustLevel, p.CodeAttested, p.FreshCodeAttested, p.MDAVerified, p.RuntimeVerified, p.AccountID, p.PublicKey}
	}
	before := snapshot()
	for _, failure := range []string{"unsupported", "not_configured", "apple_unavailable", "apple_error", "apple_invalid_key", "anything-untrusted"} {
		if next := x.handle(ctx, protocol.AppAttestShadowPayload{Action: x.expected, Session: x.id, Result: failure}); next != "stop" {
			t.Fatal(next)
		}
	}
	x.archive = failedEvidenceArchive{}
	if next := x.handle(ctx, protocol.AppAttestShadowPayload{Action: x.expected, Session: x.id, Result: "ok", Proof: "unavailable archive"}); next != "stop" {
		t.Fatal(next)
	}
	x.archive = st
	x.observe("assertion", "timeout", nil)
	if next := x.handle(ctx, protocol.AppAttestShadowPayload{Action: x.expected, Session: x.id, Result: "ok", KeyID: record.KeyID, Challenge: x.challenge, Proof: "malformed"}); next != "stop" {
		t.Fatal(next)
	}
	// A valid assertion updates ONLY its shadow counter. The seeded public key
	// is test evidence; production enrolls it through Apple's certificate verifier.
	rp := sha256.Sum256([]byte("TEST.app"))
	auth := append(append([]byte{}, rp[:]...), 0, 0, 0, 0, 1)
	hash := protocol.AppAttestShadowHash("assert", x.id, "production", record.KeyID, x.challenge, x.publicKey)
	signed := sha256.Sum256(append(auth, hash[:]...))
	signed = sha256.Sum256(signed[:])
	signature, _ := ecdsa.SignASN1(rand.Reader, key, signed[:])
	proof, _ := cbor.Marshal(map[string]any{"signature": signature, "authenticatorData": auth})
	if next := x.handle(ctx, protocol.AppAttestShadowPayload{Action: x.expected, Session: x.id, Result: "ok", KeyID: record.KeyID, Challenge: x.challenge, Proof: base64.StdEncoding.EncodeToString(proof)}); next != "wait" {
		t.Fatalf("valid assertion: %s", next)
	}
	stored, _ := st.GetAppAttestShadowKey(ctx, record.KeyID)
	if stored.Counter != 1 {
		t.Fatal("shadow counter not persisted")
	}
	if !reflect.DeepEqual(before, snapshot()) {
		t.Fatal("shadow mutated authoritative provider state")
	}

	// A shadow pass also cannot promote a provider that lacks the legacy floor.
	p.SetAttested(true, registry.TrustNone)
	before = snapshot()
	x.challenge = "another-fresh-challenge"
	auth[len(auth)-1] = 2
	hash = protocol.AppAttestShadowHash("assert", x.id, "production", record.KeyID, x.challenge, x.publicKey)
	signed = sha256.Sum256(append(auth, hash[:]...))
	signed = sha256.Sum256(signed[:])
	signature, _ = ecdsa.SignASN1(rand.Reader, key, signed[:])
	proof, _ = cbor.Marshal(map[string]any{"signature": signature, "authenticatorData": auth})
	if next := x.handle(ctx, protocol.AppAttestShadowPayload{Action: x.expected, Session: x.id, Result: "ok", KeyID: record.KeyID, Challenge: x.challenge, Proof: base64.StdEncoding.EncodeToString(proof)}); next != "wait" {
		t.Fatal(next)
	}
	if !reflect.DeepEqual(before, snapshot()) {
		t.Fatal("shadow pass promoted legacy trust")
	}

}

func TestUnsignedChallengeMismatchCannotRevokeIndependentLegacyTrust(t *testing.T) {
	s, p, record, _ := newAuthorizationFixture(t)
	makeLegacyAuthorized(p)
	if !s.registry.ProviderLegacyServingAuthorized(p) {
		t.Fatal("fixture lacks legacy authorization")
	}
	x := sessionForAuthorization(s, p, record)
	x.expected, x.challenge, x.publicKey = "assertion", "current-challenge", p.PublicKey
	archive := &capturedProofArchive{}
	x.archive = archive
	reply := protocol.AppAttestShadowPayload{
		Session: x.id, Action: "assertion", Result: "ok", KeyID: x.key.KeyID,
		Challenge: "unsigned-wrong-challenge", Proof: "AQID",
	}
	if next := x.handle(context.Background(), reply); next != "stop" || x.lastOutcome != "challenge_mismatch" {
		t.Fatalf("unexpected mismatch result: next=%s outcome=%s", next, x.lastOutcome)
	}
	x.observeFailedPolicy(x.lastOutcome) // Same post-attempt policy path as runRecovering.
	if archive.evidence.ProofField != reply.Proof || archive.evidence.SessionID != p.ID {
		t.Fatal("unsigned failed proof was not archived")
	}
	if confirmedAppAttestViolation("challenge_mismatch") || !s.registry.ProviderLegacyServingAuthorized(p) {
		t.Fatal("unsigned reply fields hard-denied a valid MDM/APNs provider")
	}
	if _, ok := s.registry.ProviderServingAuthorization(p); ok || s.authorizer.current[p] != nil {
		t.Fatal("unsigned mismatch created an App Attest grant")
	}
	firstSession := x.id
	attempts, retries := 0, 0
	x.runRecovering(context.Background(), func(ctx context.Context) {
		attempts++
		if attempts == 1 {
			if next := x.handle(ctx, reply); next != "stop" {
				t.Fatalf("mismatch unexpectedly advanced exchange: %s", next)
			}
		} else {
			if x.id == firstSession || x.key != nil {
				t.Fatal("retry reused the old challenge session or cached key")
			}
			x.lastOutcome = "unsupported"
		}
	}, func(_ context.Context, delay time.Duration) bool {
		retries++
		if delay != time.Minute || !s.registry.ProviderLegacyServingAuthorized(p) {
			t.Fatal("mismatch did not schedule bounded recovery while preserving legacy")
		}
		if _, ok := s.registry.ProviderServingAuthorization(p); ok {
			t.Fatal("mismatch retry granted App Attest without a fresh proof")
		}
		return true
	})
	if attempts != 2 || retries != 1 {
		t.Fatalf("mismatch retry attempts=%d waits=%d", attempts, retries)
	}
}
