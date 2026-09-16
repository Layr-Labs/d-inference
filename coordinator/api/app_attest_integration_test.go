package api

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"reflect"
	"testing"
	"time"

	attestservice "github.com/eigeninference/d-inference/coordinator/appattest/service"
	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/fxamacker/cbor/v2"
)

// Exercise the feature's exported boundary and real encrypted inference. The
// service's private tests cover rejection, archive failures and replay cases.
func TestAppAttestShadowCannotChangeRoutingOrTrust(t *testing.T) {
	reg, st, ts := setupFailoverServer(t)
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	model := "shadow-coexistence-model"
	if err := st.CreateProviderToken(&store.ProviderToken{TokenHash: sha256Hash("shadow-provider-token"), AccountID: "test-account", Active: true}); err != nil {
		t.Fatal(err)
	}
	frames := make(chan protocol.AppAttestShadowPayload, 8)
	fp := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{Name: "shadow-provider", Version: "0.9.4", AuthToken: "shadow-provider-token", DecodeTPS: 50, Models: []failoverModelSpec{{ID: model}}, Script: fullServeScript(model), AppAttestFrames: frames})
	p := reg.GetProvider(fp.registryID)
	if c, _, _ := reg.QuickCapacityCheck(model, 10, 64, registry.RequestTraits{}); c != 1 {
		t.Fatalf("positive control: %d", c)
	}
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	public := elliptic.Marshal(key.Curve, key.X, key.Y)
	keyHash := sha256.Sum256(public)
	keyID := base64.StdEncoding.EncodeToString(keyHash[:])
	owner := "test-account"
	if ar := p.GetAttestationResult(); ar != nil {
		owner += ":" + ar.PublicKey
	}
	ownerHash := sha256.Sum256([]byte(owner))
	_, err := st.InsertAppAttestShadowKey(ctx, store.AppAttestShadowKey{KeyID: keyID, Owner: hex.EncodeToString(ownerHash[:]), PublicKey: public, AppID: "TEST.app", Environment: "production"})
	if err != nil {
		t.Fatal(err)
	}
	snapshot := func() []any {
		p.Mu().Lock()
		defer p.Mu().Unlock()
		return []any{p.Status, p.TrustLevel, p.CodeAttested, p.FreshCodeAttested, p.MDAVerified, p.RuntimeVerified, p.AccountID, p.PublicKey}
	}
	before := snapshot()
	feature := attestservice.New(ctx, AppAttestShadowConfig{Enabled: true, RolloutPercent: 100, AppID: "TEST.app", Environment: "production"}, attestservice.Dependencies{Store: st, Registry: reg})
	session := feature.StartSession(ctx, p, &protocol.RegisterMessage{AppAttestProtocol: 1, Version: "0.9.4", PublicKey: p.PublicKey}, "test-account")
	if session == nil {
		t.Fatal("session not started")
	}
	next := func(action string) protocol.AppAttestShadowPayload {
		t.Helper()
		select {
		case payload := <-frames:
			if payload.Action != action {
				t.Fatalf("wanted %s, got %s", action, payload.Action)
			}
			return payload
		case <-ctx.Done():
			t.Fatal("exchange timed out")
			return protocol.AppAttestShadowPayload{}
		}
	}
	prepare := next("prepare")
	session.Offer(protocol.AppAttestShadowPayload{Action: "ready", Session: prepare.Session, Result: "ok", KeyID: keyID})
	request := next("assert")
	if request.EncryptedChallenge == nil {
		t.Fatal("missing encrypted endpoint challenge")
	}
	nonce, err := e2e.DecryptWithPrivateKey(&e2e.EncryptedPayload{EphemeralPublicKey: request.EncryptedChallenge.EphemeralPublicKey, Ciphertext: request.EncryptedChallenge.Ciphertext}, fp.privKey)
	if err != nil {
		t.Fatal(err)
	}
	rp := sha256.Sum256([]byte("TEST.app"))
	auth := append(append([]byte{}, rp[:]...), 0, 0, 0, 0, 1)
	hash := protocol.AppAttestShadowHash("assert", request.Session, "production", keyID, string(nonce), p.PublicKey)
	signed := sha256.Sum256(append(auth, hash[:]...))
	signed = sha256.Sum256(signed[:])
	signature, _ := ecdsa.SignASN1(rand.Reader, key, signed[:])
	proof, _ := cbor.Marshal(map[string]any{"signature": signature, "authenticatorData": auth})
	session.Offer(protocol.AppAttestShadowPayload{Action: "assertion", Session: request.Session, Result: "ok", KeyID: keyID, Challenge: string(nonce), Proof: base64.StdEncoding.EncodeToString(proof)})
	ticker := time.NewTicker(time.Millisecond)
	defer ticker.Stop()
	for {
		stored, err := st.GetAppAttestShadowKey(ctx, keyID)
		if err != nil {
			t.Fatal(err)
		}
		if stored != nil && stored.Counter == 1 {
			break
		}
		select {
		case <-ticker.C:
		case <-ctx.Done():
			t.Fatal("assertion did not reach durable counter")
		}
	}
	if !reflect.DeepEqual(before, snapshot()) {
		t.Fatal("shadow changed legacy trust")
	}
	if c, _, _ := reg.QuickCapacityCheck(model, 10, 64, registry.RequestTraits{}); c != 1 {
		t.Fatalf("shadow changed routing: %d", c)
	}
	status, body, err := postChat(ctx, ts.URL, "test-key", buildChatBody(t, model, true, nil))
	if err != nil {
		t.Fatal(err)
	}
	assertCleanFailoverStream(t, status, body, markerFor("shadow-provider"))
	reg.SetTrustLevel(p.ID, registry.TrustNone)
	if c, _, _ := reg.QuickCapacityCheck(model, 10, 64, registry.RequestTraits{}); c != 0 {
		t.Fatal("shadow pass bypassed legacy floor")
	}
}
