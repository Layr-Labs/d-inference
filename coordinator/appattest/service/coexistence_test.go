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
	for _, failure := range []string{"unsupported", "not_configured", "apple_unavailable", "apple_invalid_key", "anything-untrusted"} {
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
