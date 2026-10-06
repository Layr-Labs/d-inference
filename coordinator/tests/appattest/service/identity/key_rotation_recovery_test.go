package identity_test

import (
	"context"
	"reflect"
	"testing"
	"testing/synctest"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/authorization"
	eligibility "github.com/eigeninference/d-inference/coordinator/internal/appattest/eligibility"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/recovery"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
	memorystore "github.com/eigeninference/d-inference/coordinator/store/memory"
)

// A dead Secure Enclave key is retired through the released client's
// attest → key_unregistered path, quickly, and the replacement key earns
// serving only through fresh verified evidence bound to the same machine.
func TestDeadKeyRotationRecoversServingOnSameCanonicalMachine(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		s, p, _, state := newAuthorizationFixture(t)
		mem := memorystore.NewMemory(store.Config{})
		s.store = &statusReadinessStore{MemoryStore: mem, state: state}
		old, replacement := rotationKeyID(1), rotationKeyID(2)
		evidence := s.evidence
		evidence.Binding.Credential, evidence.Expected.Credential = old, old
		record := authorization.NewRecord(evidence, s.status, "proof", nil, 0)
		enroll := func(keyID string) {
			t.Helper()
			id := "enroll-" + keyID
			if err := mem.BeginAppAttestEvidence(context.Background(), store.AppAttestEvidence{ID: id, SessionID: p.ID, KeyID: keyID, ReceivedAt: time.Now(), Action: "attestation", Context: []byte(`{}`)}); err != nil {
				t.Fatal(err)
			}
			key := store.AppAttestShadowKey{KeyID: keyID, Owner: "owner", AccountID: "account", MachineID: "machine", AppID: "TEST.app", Environment: "production", PublicKey: []byte{1}}
			if outcome, err := mem.CompleteAppAttestEvidence(context.Background(), id, store.AppAttestDecision{Outcome: "verified", Key: &key}); err != nil || outcome != "verified" {
				t.Fatalf("enroll %v %v", outcome, err)
			}
		}
		enroll(old)
		a := s.authorizer
		a.Remember(p, record)
		if !a.Apply(p, record, state, time.Now()) {
			t.Fatal("initial grant")
		}
		before, _ := s.registry.GetProviderRewardSnapshot(p.ID)

		h := &rotationHarness{mem: mem, percent: 100}
		x := h.exchange(3, p)
		x.deps.Authorization = a
		identity := identityForAuthorization(s, p, nil)
		ready := func(keyID string) string {
			x.attempt.Challenge.Expected, x.attempt.Challenge.Started = "ready", time.Time{}
			return x.accept(context.Background(), protocol.AppAttestShadowPayload{Session: x.attempt.Challenge.Binding.Session, Action: "ready", Result: "ok", KeyID: keyID})
		}
		fail := func(action, result string, appleError *protocol.AppAttestAppleError) {
			t.Helper()
			x.attempt.Challenge.Expected = action
			if next := x.accept(context.Background(), protocol.AppAttestShadowPayload{Session: x.attempt.Challenge.Binding.Session, Action: action, KeyID: x.attempt.Challenge.Credential.KeyID, Result: result, AppleError: appleError}); next != "stop" {
				t.Fatalf("%s failure continued: %s", action, next)
			}
		}
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		attempts := 0
		var delays []time.Duration
		x.drive(ctx, func(_ context.Context, binding recovery.Binding) recovery.Outcome {
			attempts++
			switch attempts {
			case 1, 2:
				if next := ready(old); next != "assert" {
					t.Fatalf("attempt %d: %s", attempts, next)
				}
				fail("assertion", "apple_error", deadKeyError)
			case 3:
				if next := ready(old); next != "attest" {
					t.Fatalf("dead key asked to assert: %s", next)
				}
				fail("attestation", "key_unregistered", nil)
			case 4:
				// The replacement is unknown and must enroll like any new key.
				if next := ready(replacement); next != "attest" {
					t.Fatalf("replacement skipped attestation: %s", next)
				}
				enroll(replacement) // stands in for a fully verified attestation commit
				x.attempt.Challenge.Credential, _ = mem.GetAppAttestShadowKey(context.Background(), replacement)
				e := evidence
				e.Binding.Credential, e.Expected.Credential = replacement, replacement
				e.Binding.Connection, e.Expected.Connection = binding.Session, binding.Session
				e.AssertionAt = time.Now()
				eligibility.ApplyReadiness(&e, state)
				if err := s.RefreshBuildQualifications(ctx); err != nil {
					t.Fatal(err)
				}
				identity.Update(authorization.NewVerifiedProof(e, &s.status, binding.Session, nil, 0), appattest.EvaluateAuthorization(e, time.Now()))
				cancel()
				return recovery.Outcome{AssertionAt: e.AssertionAt}
			}
			return recovery.Outcome{Reason: x.last.Outcome, AssertionAt: x.last.AssertionAt}
		}, func(_ context.Context, delay time.Duration) bool {
			delays = append(delays, delay)
			time.Sleep(delay)
			return true
		}, func(reason string) { a.RejectProof(p, reason) })
		if attempts != 4 || len(delays) != 3 || delays[0] != time.Minute {
			t.Fatalf("attempts=%d delays=%v", attempts, delays)
		}
		for _, d := range delays[1:] {
			if d < recovery.RotationRetryMin || d >= time.Minute {
				t.Fatalf("rotation retry not short: %v", delays)
			}
		}
		lease, ok := s.registry.ProviderServingAuthorization(p)
		if !ok || lease.CredentialID != replacement || lease.MachineID != "machine" || lease.AccountID != "account" {
			t.Fatalf("replacement lease %+v %v", lease, ok)
		}
		after, _ := s.registry.GetProviderRewardSnapshot(p.ID)
		if !reflect.DeepEqual(before, after) || !after.AppAttestAuthorized || after.MachineID != "machine" {
			t.Fatalf("rotation changed reward identity or eligibility:\nbefore %+v\nafter  %+v", before, after)
		}

		// The retired key cannot come back through rotation: it is only ever
		// asked to attest again, which a dead key cannot satisfy.
		if next := ready(old); next != "attest" {
			t.Fatalf("retired key offered an assertion: %s", next)
		}
		x.attempt.Challenge.Expected = "attestation"
		if next := x.accept(context.Background(), protocol.AppAttestShadowPayload{Session: x.attempt.Challenge.Binding.Session, Action: "attestation", KeyID: old, Challenge: x.attempt.Challenge.Binding.Challenge, Result: "ok", Proof: "AAAA"}); next != "stop" {
			t.Fatalf("forged attestation for retired key: %s", next)
		}
		if lease, _ := s.registry.ProviderServingAuthorization(p); lease.CredentialID != replacement {
			t.Fatal("retired key displaced the replacement grant")
		}

		// Rotation is not revocation, but revoking the replacement still fences.
		s.RevokeCredential(replacement)
		if _, ok := s.registry.ProviderServingAuthorization(p); ok || s.registry.ProviderServingDenialReason(p) == "" {
			t.Fatal("revoked replacement key kept serving")
		}
	})
}

func TestRotationRetryIsShortOnlyAtThresholdAndForRequestedRotation(t *testing.T) {
	h := newRotationHarness(t, 100)
	key := rotationKeyID(1)
	h.enroll(t, key, "machine")
	x := h.session(3)
	h.assertionFailure(t, x, key, "apple_error", deadKeyError)
	if x.rotation.RetryDue("apple_error", x.attempt.Challenge.Expected, x.attempt.Challenge.Credential) {
		t.Fatal("first failure scheduled a rotation retry")
	}
	h.assertionFailure(t, x, key, "apple_error", deadKeyError)
	if !x.rotation.RetryDue("apple_error", x.attempt.Challenge.Expected, x.attempt.Challenge.Credential) {
		t.Fatal("threshold failure kept the slow backoff")
	}
	if x.rotation.RetryDue("key_unregistered", x.attempt.Challenge.Expected, x.attempt.Challenge.Credential) {
		t.Fatal("key_unregistered without a requested rotation was accelerated")
	}
	for _, other := range []string{"apple_unavailable", "busy", "timeout", "operation_timeout", "storage_error"} {
		if x.rotation.RetryDue(other, x.attempt.Challenge.Expected, x.attempt.Challenge.Credential) {
			t.Fatalf("%s accelerated", other)
		}
	}
	// Rate-limited machines keep the normal bounded backoff.
	if _, err := h.mem.RecordAppAttestKeyRotation(context.Background(), store.AppAttestKeyRotation{KeyID: rotationKeyID(9), MachineID: "machine", AccountID: "account", RequestedAt: time.Now().UTC(), Failures: 2, Reason: "assertion_apple_error"}); err != nil {
		t.Fatal(err)
	}
	if x.rotation.RetryDue("apple_error", x.attempt.Challenge.Expected, x.attempt.Challenge.Credential) {
		t.Fatal("rate-limited machine scheduled a fast retry")
	}
	// Produce a real admitted request rather than setting a worker flag.
	requested := rotationKeyID(8)
	h.enroll(t, requested, "requested-machine")
	h.assertionFailure(t, x, requested, "apple_error", deadKeyError)
	h.assertionFailure(t, x, requested, "apple_error", deadKeyError)
	if h.ready(t, x, requested) != "attest" {
		t.Fatal("eligible rotation request was not admitted")
	}
	if !x.rotation.RetryDue("key_unregistered", x.attempt.Challenge.Expected, x.attempt.Challenge.Credential) {
		t.Fatal("client acknowledgement of a requested rotation kept the slow backoff")
	}
	for i := 0; i < 64; i++ {
		if d := recovery.RotationRetryDelay(); d < 15*time.Second || d > 45*time.Second {
			t.Fatalf("delay %v outside 15-45 s", d)
		}
	}
}
