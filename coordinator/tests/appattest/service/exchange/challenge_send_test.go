package exchange_test

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/appattest/evidence"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/exchange"
	storagebudget "github.com/eigeninference/d-inference/coordinator/internal/appattest/storage"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/transcript"
	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
	memorystore "github.com/eigeninference/d-inference/coordinator/store/memory"
)

var sendKey = &store.AppAttestShadowKey{KeyID: shadowKeyID(7)}

func sendBinding(endpoint string) transcript.Binding {
	return transcript.Binding{Session: "session", Owner: "owner", Account: "account", PublicKey: endpoint, AppID: "TEST.app", Environment: "production", ProtocolVersion: 3}
}

func decodeShadowFrame(t *testing.T, data []byte) protocol.AppAttestShadowPayload {
	t.Helper()
	var m protocol.AppAttestShadowMessage
	if err := json.Unmarshal(data, &m); err != nil || m.Type != protocol.TypeAppAttestShadow {
		t.Fatalf("unexpected frame %s: %v", data, err)
	}
	return m.Payload
}

// unreachableProvider fails the test if a frame reaches provider IO.
func unreachableProvider(t *testing.T) func(context.Context, []byte) error {
	return func(context.Context, []byte) error {
		t.Error("frame reached the provider")
		return nil
	}
}

// requireProofSlotsFree fails if a send kept a proof storage permit.
func requireProofSlotsFree(t *testing.T, budget *storagebudget.Budget) {
	t.Helper()
	for range 4 {
		if _, ok := budget.AcquireProof(); !ok {
			t.Fatal("send leaked its storage permit")
		}
	}
}

type failingEnrollmentSave struct{ *memorystore.MemoryStore }

func (*failingEnrollmentSave) SaveAppAttestEnrollment(context.Context, store.AppAttestEnrollment) error {
	return errors.New("write failed")
}

func TestAttestSendRecordsEnrollmentBeforeChallengeReachesProvider(t *testing.T) {
	ctx := context.Background()
	endpoint := base64.StdEncoding.EncodeToString(make([]byte, 32))
	mem := memorystore.NewMemory(store.Config{})
	budget := &storagebudget.Budget{}
	var frame protocol.AppAttestShadowPayload
	var stored *store.AppAttestEnrollment
	transport := func(_ context.Context, data []byte) error {
		stored, _ = mem.GetAppAttestEnrollment(ctx, "session")
		frame = decodeShadowFrame(t, data)
		return nil
	}
	r := exchange.Send(ctx, exchange.SendDependencies{Enrollments: mem, Scope: storagebudget.NewScope(budget), Integrity: &evidence.Integrity{}, Transport: transport},
		sendBinding(endpoint), sendKey, "attest")
	if !r.Sent || r.Expected != "attestation" || r.Outcome != "attempted" || r.Started.IsZero() {
		t.Fatalf("attest send %+v", r)
	}
	requireProofSlotsFree(t, budget)
	scope := transcript.AccountScope("account")
	if frame.Action != "attest" || frame.Session != "session" || frame.Challenge != r.Challenge || frame.KeyID != sendKey.KeyID ||
		frame.ProtocolVersion != 3 || frame.AccountScope != scope || frame.Environment != "production" || frame.EncryptedChallenge != nil {
		t.Fatalf("attest frame %+v", frame)
	}
	if stored == nil {
		t.Fatal("enrollment not stored before the challenge reached the provider")
	}
	if stored.Challenge != r.Challenge || stored.Owner != "owner" || stored.KeyID != sendKey.KeyID || stored.AppID != "TEST.app" ||
		stored.PublicKey != endpoint || stored.AccountScope != scope || stored.ProtocolVersion != 3 {
		t.Fatalf("enrollment context %+v", stored)
	}
}

func TestAssertSendEncryptsChallengeToEndpointKey(t *testing.T) {
	keys, err := e2e.GenerateSessionKeys()
	if err != nil {
		t.Fatal(err)
	}
	endpoint := base64.StdEncoding.EncodeToString(keys.PublicKey[:])
	integrity := &evidence.Integrity{}
	for range 3 {
		integrity.Drop(nil, nil)
	}
	integrity.RecordCommit("assertion", "verified")
	var frame protocol.AppAttestShadowPayload
	transport := func(_ context.Context, data []byte) error { frame = decodeShadowFrame(t, data); return nil }
	r := exchange.Send(context.Background(), exchange.SendDependencies{Scope: storagebudget.NewScope(&storagebudget.Budget{}), Integrity: integrity, Transport: transport},
		sendBinding(endpoint), sendKey, "assert")
	if !r.Sent || r.Expected != "assertion" {
		t.Fatalf("assert send %+v", r)
	}
	if integrity.Baseline() != 3 || integrity.Archived() {
		t.Fatal("assert did not start a new archive baseline")
	}
	if frame.Action != "assert" || frame.Challenge != "" || frame.EncryptedChallenge == nil {
		t.Fatalf("assert frame must carry only the encrypted challenge: %+v", frame)
	}
	plain, err := e2e.Decrypt(&e2e.EncryptedPayload{EphemeralPublicKey: frame.EncryptedChallenge.EphemeralPublicKey, Ciphertext: frame.EncryptedChallenge.Ciphertext}, keys)
	if err != nil || string(plain) != r.Challenge {
		t.Fatalf("challenge not readable by the endpoint key: %q %v", plain, err)
	}
}

func TestSendFailuresStopBeforeProviderIO(t *testing.T) {
	ctx := context.Background()
	endpoint := base64.StdEncoding.EncodeToString(make([]byte, 32))
	send := func(t *testing.T, enrollments store.AppAttestEnrollmentStore, budget *storagebudget.Budget, binding transcript.Binding, action string) exchange.SentChallenge {
		return exchange.Send(ctx, exchange.SendDependencies{Enrollments: enrollments, Scope: storagebudget.NewScope(budget), Integrity: &evidence.Integrity{},
			Transport: unreachableProvider(t)}, binding, sendKey, action)
	}
	t.Run("enrollment storage missing", func(t *testing.T) {
		if r := send(t, nil, &storagebudget.Budget{}, sendBinding(endpoint), "attest"); r.Sent || r.Outcome != "storage_unavailable" {
			t.Fatalf("send %+v", r)
		}
	})
	t.Run("storage slots busy", func(t *testing.T) {
		mem := memorystore.NewMemory(store.Config{})
		budget := &storagebudget.Budget{}
		for range 4 {
			if _, ok := storagebudget.NewScope(budget).Acquire(); !ok {
				t.Fatal("proof slot")
			}
		}
		if r := send(t, mem, budget, sendBinding(endpoint), "attest"); r.Sent || r.Outcome != "storage_busy" {
			t.Fatalf("send %+v", r)
		}
		if e, _ := mem.GetAppAttestEnrollment(ctx, "session"); e != nil {
			t.Fatal("busy storage still wrote an enrollment")
		}
	})
	t.Run("enrollment write fails", func(t *testing.T) {
		budget := &storagebudget.Budget{}
		if r := send(t, &failingEnrollmentSave{memorystore.NewMemory(store.Config{})}, budget, sendBinding(endpoint), "attest"); r.Sent || r.Outcome != "storage_error" {
			t.Fatalf("send %+v", r)
		}
		requireProofSlotsFree(t, budget)
	})
	t.Run("endpoint key not 32 bytes", func(t *testing.T) {
		short := sendBinding(base64.StdEncoding.EncodeToString(make([]byte, 16)))
		if r := send(t, nil, &storagebudget.Budget{}, short, "assert"); r.Sent || r.Outcome != "encryption_key" {
			t.Fatalf("send %+v", r)
		}
	})
	t.Run("stopped writer", func(t *testing.T) {
		stopped := newSessionProvider(endpoint, "se")
		r := exchange.Send(ctx, exchange.SendDependencies{Scope: storagebudget.NewScope(&storagebudget.Budget{}), Integrity: &evidence.Integrity{}, Transport: stopped.EnqueueText},
			sendBinding(endpoint), sendKey, "prepare")
		if r.Sent || r.Outcome != "send_failed" || r.Expected != "ready" {
			t.Fatalf("send %+v", r)
		}
	})
}
