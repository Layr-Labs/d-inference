package service

import (
	"context"
	"encoding/base64"
	"errors"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type failingShadowKeyRead struct{ *store.MemoryStore }

func (*failingShadowKeyRead) GetAppAttestShadowKey(context.Context, string) (*store.AppAttestShadowKey, error) {
	return nil, errors.New("database unavailable")
}

func TestReadyReplyStopsOnKeyLookupFailure(t *testing.T) {
	h := newRotationHarness(t, 100)
	x := h.session(3)
	x.store = &failingShadowKeyRead{h.mem}
	if next := h.ready(t, x, rotationKeyID(1)); next != "stop" || x.lastOutcome != "storage_error" {
		t.Fatalf("next=%q outcome=%q", next, x.lastOutcome)
	}
	if x.key != nil {
		t.Fatal("failed lookup selected a key")
	}
}

func TestReadyReplyRejectsKeyOfAnotherOwnerOrPolicy(t *testing.T) {
	for _, tc := range []struct {
		name string
		key  store.AppAttestShadowKey
	}{
		{"other owner and account", store.AppAttestShadowKey{Owner: "someone", AccountID: "other-account", MachineID: "machine", AppID: "TEST.app", Environment: "production"}},
		{"other environment", store.AppAttestShadowKey{Owner: "owner", AccountID: "account", AppID: "TEST.app", Environment: "development"}},
		{"other app", store.AppAttestShadowKey{Owner: "owner", AccountID: "account", AppID: "OTHER.app", Environment: "production"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := newRotationHarness(t, 100)
			tc.key.KeyID, tc.key.PublicKey = rotationKeyID(2), []byte{1}
			if _, err := h.mem.InsertAppAttestShadowKey(context.Background(), tc.key); err != nil {
				t.Fatal(err)
			}
			x := h.session(3)
			if next := h.ready(t, x, tc.key.KeyID); next != "stop" || x.lastOutcome != "key_owner_or_policy" {
				t.Fatalf("next=%q outcome=%q", next, x.lastOutcome)
			}
			if x.owner != "owner" {
				t.Fatal("rejected key replaced the session owner")
			}
		})
	}
}

func TestKeyOwnerMatchesOnlyOwnerOrAuthenticatedAccount(t *testing.T) {
	h := newRotationHarness(t, 100)
	x := h.session(3)
	ctx := context.Background()
	if !x.keyOwnerMatches(ctx, &store.AppAttestShadowKey{Owner: "owner", AccountID: "other"}) {
		t.Fatal("same owner rejected")
	}
	if !x.keyOwnerMatches(ctx, &store.AppAttestShadowKey{Owner: "previous-machine-owner", AccountID: "account"}) {
		t.Fatal("same authenticated account rejected")
	}
	if x.keyOwnerMatches(ctx, &store.AppAttestShadowKey{Owner: "someone", AccountID: "other", MachineID: "machine"}) {
		t.Fatal("another account's key accepted")
	}
	x.account = ""
	if x.keyOwnerMatches(ctx, &store.AppAttestShadowKey{Owner: "someone", AccountID: "", MachineID: "machine"}) {
		t.Fatal("anonymous session matched an unowned key by empty account")
	}
}

func TestProofReplyWithoutPreparedContextStops(t *testing.T) {
	h := newRotationHarness(t, 100)
	x := h.session(3)
	key := rotationKeyID(3)
	x.key, x.expected, x.challenge = &store.AppAttestShadowKey{KeyID: key}, "assertion", "challenge"
	reply := protocol.AppAttestShadowPayload{Session: x.id, Action: "assertion", Result: "ok", KeyID: key, Challenge: "challenge", Proof: base64.StdEncoding.EncodeToString([]byte("proof"))}
	if next := x.handleExchange(context.Background(), reply, nil); next != "stop" || x.lastOutcome != "enrollment_context" {
		t.Fatalf("next=%q outcome=%q", next, x.lastOutcome)
	}
}

func TestInvalidAttestationIsRejectedWithoutStoringKey(t *testing.T) {
	h := newRotationHarness(t, 100)
	x := h.session(3)
	x.verifier = appattest.New(appattest.Policy{AppID: "TEST.app", Environment: "production"})
	key := rotationKeyID(4)
	x.key, x.expected, x.challenge = &store.AppAttestShadowKey{KeyID: key}, "attestation", "challenge"
	reply := protocol.AppAttestShadowPayload{Session: x.id, Action: "attestation", Result: "ok", KeyID: key, Challenge: "challenge", Proof: base64.StdEncoding.EncodeToString([]byte("not an attestation"))}
	next := x.handleExchange(context.Background(), reply, &shadowProofContext{})
	if next != "stop" || x.lastOutcome == "" || x.lastOutcome == "verified" {
		t.Fatalf("next=%q outcome=%q", next, x.lastOutcome)
	}
	if stored, _ := h.mem.GetAppAttestShadowKey(context.Background(), key); stored != nil {
		t.Fatal("rejected attestation stored a credential")
	}
	var saw bool
	for _, e := range h.events {
		if e["stage"] == "attestation" && e["outcome"] == x.lastOutcome {
			saw = true
		}
	}
	if !saw {
		t.Fatalf("rejection not observed: %v", h.events)
	}
}
