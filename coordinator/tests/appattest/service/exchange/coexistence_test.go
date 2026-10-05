package exchange_test

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"reflect"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/evidence"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/exchange"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/observation"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/storage"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/transcript"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	memorystore "github.com/eigeninference/d-inference/coordinator/store/memory"
	"github.com/fxamacker/cbor/v2"
)

func TestShadowProofsNeverMutateLegacyTrust(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	st := memorystore.NewMemory(store.Config{})
	p := newSessionProvider(base64.StdEncoding.EncodeToString(make([]byte, 32)), "se")
	p.Status, p.TrustLevel, p.CodeAttested, p.RuntimeVerified = registry.StatusOnline, registry.TrustHardware, true, true
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	public := elliptic.Marshal(key.Curve, key.X, key.Y)
	record := &store.AppAttestShadowKey{KeyID: "test-key", Owner: "test-owner", PublicKey: public, AppID: "TEST.app", Environment: "production"}
	_, err := st.InsertAppAttestShadowKey(ctx, *record)
	if err != nil {
		t.Fatal(err)
	}
	x := exchange.Attempt{Challenge: exchange.Challenge{Binding: transcript.Binding{Session: "test-session", Owner: "test-owner", PublicKey: p.PublicKey, AppID: "TEST.app", Environment: "production", ProtocolVersion: 3,
		Challenge: "fresh"}, Credential: record, Expected: "assertion"}}
	budget := &storage.Budget{}
	deps := exchange.PipelineDependencies{Verification: exchange.Dependencies{Keys: st, Verifier: appattest.New(appattest.Policy{AppID: "TEST.app", Environment: "production"})},
		Provider: p, Archive: st, Enrollments: st, Integrity: &evidence.Integrity{}, Budget: budget, Scope: storage.NewScope(budget)}
	snapshot := func() []any {
		p.Mu().Lock()
		defer p.Mu().Unlock()
		return []any{p.Status, p.TrustLevel, p.CodeAttested, p.FreshCodeAttested, p.MDAVerified, p.RuntimeVerified, p.AccountID, p.PublicKey}
	}
	before := snapshot()
	for _, failure := range []string{"unsupported", "not_configured", "apple_unavailable", "apple_error", "apple_invalid_key", "anything-untrusted"} {
		if next := exchange.NewPipeline(deps).Handle(ctx, x, protocol.AppAttestShadowPayload{Action: x.Challenge.Expected, Session: x.Challenge.Binding.Session, Result: failure}).Next; next != "stop" {
			t.Fatal(next)
		}
	}
	deps.Archive = failedEvidenceArchive{}
	if next := exchange.NewPipeline(deps).Handle(ctx, x, protocol.AppAttestShadowPayload{Action: x.Challenge.Expected, Session: x.Challenge.Binding.Session, Result: "ok", Proof: "unavailable archive"}).Next; next != "stop" {
		t.Fatal(next)
	}
	deps.Archive = st
	observation.Format(observation.Event{Provider: p, Session: "test-session", Version: "0.9.0", Stage: "assertion", Outcome: "timeout"})
	if next := exchange.NewPipeline(deps).Handle(ctx, x, protocol.AppAttestShadowPayload{Action: x.Challenge.Expected, Session: x.Challenge.Binding.Session, Result: "ok", KeyID: record.KeyID, Challenge: x.Challenge.Binding.Challenge, Proof: "malformed"}).Next; next != "stop" {
		t.Fatal(next)
	}
	rp := sha256.Sum256([]byte("TEST.app"))
	auth := append(append([]byte{}, rp[:]...), 0, 0, 0, 0, 1)
	status := &protocol.AppAttestStatus{OSVersion: "27"}
	hash := protocol.AppAttestShadowHashV3("assert", x.Challenge.Binding.Session, x.Challenge.Binding.Environment, record.KeyID, x.Challenge.Binding.Challenge, x.Challenge.Binding.PublicKey, transcript.AccountScope(x.Challenge.Binding.Account), status)
	signed := sha256.Sum256(append(auth, hash[:]...))
	signed = sha256.Sum256(signed[:])
	signature, _ := ecdsa.SignASN1(rand.Reader, key, signed[:])
	proof, _ := cbor.Marshal(map[string]any{"signature": signature, "authenticatorData": auth})
	if next := exchange.NewPipeline(deps).Handle(ctx, x, protocol.AppAttestShadowPayload{Action: x.Challenge.Expected, Session: x.Challenge.Binding.Session, Result: "ok", KeyID: record.KeyID, Challenge: x.Challenge.Binding.Challenge, Proof: base64.StdEncoding.EncodeToString(proof), ProtocolVersion: 3, Status: status}).Next; next != "wait" {
		t.Fatalf("valid assertion: %s", next)
	}
	stored, _ := st.GetAppAttestShadowKey(ctx, record.KeyID)
	if stored.Counter != 1 {
		t.Fatal("shadow counter not persisted")
	}
	if !reflect.DeepEqual(before, snapshot()) {
		t.Fatal("shadow mutated authoritative provider state")
	}
	p.SetAttested(true, registry.TrustNone)
	before = snapshot()
	x.Challenge.Binding.Challenge = "another-fresh-challenge"
	auth[len(auth)-1] = 2
	hash = protocol.AppAttestShadowHashV3("assert", x.Challenge.Binding.Session, x.Challenge.Binding.Environment, record.KeyID, x.Challenge.Binding.Challenge, x.Challenge.Binding.PublicKey, transcript.AccountScope(x.Challenge.Binding.Account), status)
	signed = sha256.Sum256(append(auth, hash[:]...))
	signed = sha256.Sum256(signed[:])
	signature, _ = ecdsa.SignASN1(rand.Reader, key, signed[:])
	proof, _ = cbor.Marshal(map[string]any{"signature": signature, "authenticatorData": auth})
	if next := exchange.NewPipeline(deps).Handle(ctx, x, protocol.AppAttestShadowPayload{Action: x.Challenge.Expected, Session: x.Challenge.Binding.Session, Result: "ok", KeyID: record.KeyID, Challenge: x.Challenge.Binding.Challenge, Proof: base64.StdEncoding.EncodeToString(proof), ProtocolVersion: 3, Status: status}).Next; next != "wait" {
		t.Fatal(next)
	}
	if !reflect.DeepEqual(before, snapshot()) {
		t.Fatal("shadow pass promoted legacy trust")
	}
}
