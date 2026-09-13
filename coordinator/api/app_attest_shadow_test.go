package api

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

func TestAppAttestShadowCannotChangeRoutingOrTrust(t *testing.T) {
	reg, st, ts := setupFailoverServer(t)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	model := "shadow-coexistence-model"
	fp := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{Name: "shadow-provider", Version: "0.9.0", DecodeTPS: 50, Models: []failoverModelSpec{{ID: model}}, Script: fullServeScript(model)})
	p := reg.GetProvider(fp.registryID)
	if c, _, _ := reg.QuickCapacityCheck(model, 10, 64, registry.RequestTraits{}); c != 1 {
		t.Fatalf("positive control: provider not eligible: %d", c)
	}
	s := &Server{registry: reg, store: st, logger: slog.New(slog.NewTextHandler(io.Discard, nil)), appAttestShadow: AppAttestShadowConfig{Enabled: true, AppID: "TEST.app", Environment: "production"}}
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	public := elliptic.Marshal(key.Curve, key.X, key.Y)
	record := &store.AppAttestShadowKey{KeyID: "test-key", Owner: "test-owner", PublicKey: public, AppID: "TEST.app", Environment: "production"}
	_, err := st.InsertAppAttestShadowKey(ctx, *record)
	if err != nil {
		t.Fatal(err)
	}
	x := &appAttestShadowSession{s: s, provider: p, in: make(chan protocol.AppAttestShadowPayload, 2), id: "test-session", owner: "test-owner", publicKey: p.PublicKey, version: "0.9.0", key: record, challenge: "fresh", expected: "assertion", store: st, verifier: appattest.New(appattest.Policy{AppID: "TEST.app", Environment: "production"})}
	snapshot := func() []any {
		p.Mu().Lock()
		defer p.Mu().Unlock()
		return []any{p.Status, p.TrustLevel, p.CodeAttested, p.FreshCodeAttested, p.MDAVerified, p.RuntimeVerified, p.AccountID, p.PublicKey}
	}
	before := snapshot()
	for _, failure := range []string{"unsupported", "not_configured", "apple_unavailable", "apple_invalid_key", "anything-untrusted"} {
		if next := x.handle(ctx, protocol.AppAttestShadowPayload{Result: failure}); next != "stop" {
			t.Fatal(next)
		}
	}
	x.observe("assertion", "timeout", nil)
	if next := x.handle(ctx, protocol.AppAttestShadowPayload{Result: "ok", KeyID: record.KeyID, Challenge: x.challenge, Proof: "malformed"}); next != "stop" {
		t.Fatal(next)
	}
	// A valid assertion updates ONLY its shadow counter. The seeded public key
	// is test evidence; production enrolls it through Apple's certificate verifier.
	rp := sha256.Sum256([]byte("TEST.app"))
	auth := append(append([]byte{}, rp[:]...), 0, 0, 0, 0, 1)
	hash := protocol.AppAttestShadowHash("assert", x.id, "production", record.KeyID, x.challenge, x.publicKey)
	signed := sha256.Sum256(append(auth, hash[:]...))
	signature, _ := ecdsa.SignASN1(rand.Reader, key, signed[:])
	proof, _ := cbor.Marshal(map[string]any{"signature": signature, "authenticatorData": auth})
	if next := x.handle(ctx, protocol.AppAttestShadowPayload{Result: "ok", KeyID: record.KeyID, Challenge: x.challenge, Proof: base64.StdEncoding.EncodeToString(proof)}); next != "wait" {
		t.Fatalf("valid assertion: %s", next)
	}
	stored, _ := st.GetAppAttestShadowKey(ctx, record.KeyID)
	if stored.Counter != 1 {
		t.Fatal("shadow counter not persisted")
	}
	if !reflect.DeepEqual(before, snapshot()) {
		t.Fatal("shadow mutated authoritative provider state")
	}
	if c, _, _ := reg.QuickCapacityCheck(model, 10, 64, registry.RequestTraits{}); c != 1 {
		t.Fatalf("shadow changed routing: %d", c)
	}
	status, body, err := postChat(ctx, ts.URL, "test-key", buildChatBody(t, model, true, nil))
	if err != nil {
		t.Fatal(err)
	}
	assertCleanFailoverStream(t, status, body, markerFor("shadow-provider"))

	// A shadow pass also cannot promote a provider that lacks the legacy floor.
	reg.SetTrustLevel(p.ID, registry.TrustNone)
	before = snapshot()
	x.challenge = "another-fresh-challenge"
	auth[len(auth)-1] = 2
	hash = protocol.AppAttestShadowHash("assert", x.id, "production", record.KeyID, x.challenge, x.publicKey)
	signed = sha256.Sum256(append(auth, hash[:]...))
	signature, _ = ecdsa.SignASN1(rand.Reader, key, signed[:])
	proof, _ = cbor.Marshal(map[string]any{"signature": signature, "authenticatorData": auth})
	if next := x.handle(ctx, protocol.AppAttestShadowPayload{Result: "ok", KeyID: record.KeyID, Challenge: x.challenge, Proof: base64.StdEncoding.EncodeToString(proof)}); next != "wait" {
		t.Fatal(next)
	}
	if !reflect.DeepEqual(before, snapshot()) {
		t.Fatal("shadow pass promoted legacy trust")
	}
	if c, _, _ := reg.QuickCapacityCheck(model, 10, 64, registry.RequestTraits{}); c != 0 {
		t.Fatal("shadow pass bypassed legacy floor")
	}
}

func TestAppAttestShadowOldProvidersAndOffMode(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	st := store.NewMemory(store.Config{})
	reg := registry.New(logger)
	s := NewServer(reg, st, ServerConfig{}, logger)
	t.Cleanup(s.Close)
	p := newCodeAttestProvider("key", "se")
	if x := s.startAppAttestShadow(context.Background(), p, &protocol.RegisterMessage{AppAttestProtocol: 1}); x != nil {
		t.Fatal("off mode started shadow")
	}
	s.appAttestShadow = AppAttestShadowConfig{Enabled: true, AppID: "TEST.app", Environment: "production"}
	if x := s.startAppAttestShadow(context.Background(), p, &protocol.RegisterMessage{}); x != nil {
		t.Fatal("sent unknown frames to legacy client")
	}
	if got := shadowClientResult("provider-controlled secret"); got != "client_error" {
		t.Fatal("raw error escaped allowlist")
	}
}

func TestAppAttestShadowInboxBounded(t *testing.T) {
	x := &appAttestShadowSession{in: make(chan protocol.AppAttestShadowPayload, 2)}
	for i := 0; i < 10000; i++ {
		x.offer(protocol.AppAttestShadowPayload{Action: "assertion"})
	}
	if len(x.in) != 2 {
		t.Fatal("unbounded inbox")
	}
}

func TestAppAttestShadowLateProofCannotWinTimerRace(t *testing.T) {
	p := newCodeAttestProvider("key", "se")
	x := &appAttestShadowSession{s: &Server{}, provider: p, expected: "assertion", started: time.Now().Add(-shadowResponseTimeout - time.Second)}
	if got := x.handle(context.Background(), protocol.AppAttestShadowPayload{Result: "ok"}); got != "stop" {
		t.Fatalf("late proof handled: %s", got)
	}
}
