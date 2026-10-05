package identity_test

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/exchange"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/recovery"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/transcript"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
	memorystore "github.com/eigeninference/d-inference/coordinator/store/memory"
	"github.com/fxamacker/cbor/v2"
)

type failingEvidenceCompletion struct{ *memorystore.MemoryStore }

func (s *failingEvidenceCompletion) CompleteAppAttestEvidence(context.Context, string, store.AppAttestDecision) (string, error) {
	return "", errors.New("temporary commit failure")
}

func TestAppAttestCompletionFailureReentersRecovery(t *testing.T) {
	h := newRotationHarness(t, 0)
	st := &failingEvidenceCompletion{MemoryStore: h.mem}
	x := h.session(3)
	x.attempt.Challenge.Binding.Session = "original"
	x.deps.Archive = st
	// Match the live observer/transition handoff: archive diagnostics do not
	// change the worker's last lifecycle outcome, but Transition still runs.
	observedOutcome, transitions := "attempted", 0
	x.attempt.PreviousOutcome = observedOutcome
	observe := x.deps.Verification.Observe
	x.deps.Verification.Observe = func(stage, outcome string, metadata *appattest.Key, reply protocol.AppAttestShadowPayload) {
		if stage != "archive" {
			observedOutcome = outcome
		}
		observe(stage, outcome, metadata, reply)
	}
	x.deps.Transition = func(exchange.Result, protocol.AppAttestShadowPayload) string {
		transitions++
		return observedOutcome
	}
	private, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	key := store.AppAttestShadowKey{KeyID: rotationKeyID(1), Owner: "owner", AccountID: "account", AppID: "TEST.app", Environment: "production", PublicKey: elliptic.Marshal(private.Curve, private.X, private.Y)}
	if _, err := h.mem.InsertAppAttestShadowKey(t.Context(), key); err != nil {
		t.Fatal(err)
	}
	attempts := 0
	x.drive(context.Background(), func(ctx context.Context, binding recovery.Binding) recovery.Outcome {
		attempts++
		if attempts == 1 {
			x.attempt.Challenge.Credential = &key
			x.attempt.Challenge.Expected, x.attempt.Challenge.Binding.Challenge = "assertion", "challenge"
			x.integrity.BeginChallenge()
			rp := sha256.Sum256([]byte("TEST.app"))
			auth := append(append([]byte{}, rp[:]...), 0, 0, 0, 0, 1)
			status := &protocol.AppAttestStatus{OSVersion: "27"}
			b := x.attempt.Challenge.Binding
			hash := protocol.AppAttestShadowHashV3("assert", binding.Session, b.Environment, key.KeyID, b.Challenge, b.PublicKey, transcript.AccountScope(b.Account), status)
			signed := sha256.Sum256(append(auth, hash[:]...))
			signed = sha256.Sum256(signed[:])
			signature, err := ecdsa.SignASN1(rand.Reader, private, signed[:])
			if err != nil {
				t.Fatal(err)
			}
			body, err := cbor.Marshal(map[string]any{"signature": signature, "authenticatorData": auth})
			if err != nil {
				t.Fatal(err)
			}
			if next := x.accept(ctx, protocol.AppAttestShadowPayload{Session: binding.Session, Action: "assertion", Result: "ok", KeyID: key.KeyID, Challenge: b.Challenge, ProtocolVersion: 3, Status: status, Proof: base64.StdEncoding.EncodeToString(body)}); next != "stop" {
				t.Fatal("failed commit accepted")
			}
			if x.last.Outcome != "storage_error" {
				t.Fatalf("lost completion failure: %s", x.last.Outcome)
			}
			return recovery.Outcome{Reason: x.last.Outcome}
		}
		return recovery.Outcome{Reason: "unsupported"}
	}, func(_ context.Context, delay time.Duration) bool {
		if delay != time.Minute {
			t.Fatalf("unexpected retry delay: %s", delay)
		}
		return true
	}, nil)
	if attempts != 2 {
		t.Fatalf("storage failure stopped recovery after %d attempts", attempts)
	}
	if transitions != 1 || observedOutcome != "attempted" {
		t.Fatalf("commit failure skipped transition or changed archive observer semantics: transitions=%d outcome=%s", transitions, observedOutcome)
	}
}
