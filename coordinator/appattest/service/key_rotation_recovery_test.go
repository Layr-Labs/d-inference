package service

import (
	"context"
	"reflect"
	"testing"
	"testing/synctest"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// A dead Secure Enclave key is retired through the released client's
// attest → key_unregistered path, quickly, and the replacement key earns
// serving only through fresh verified evidence bound to the same machine.
func TestDeadKeyRotationRecoversServingOnSameCanonicalMachine(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		s, p, record, state := newAuthorizationFixture(t)
		mem := store.NewMemory(store.Config{})
		s.store = &statusReadinessStore{MemoryStore: mem, state: state}
		s.config.AppID, s.config.KeyRotationPercent = "TEST.app", 100
		old, replacement := rotationKeyID(1), rotationKeyID(2)
		record.evidence.Binding.Credential, record.evidence.Expected.Credential = old, old
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
		a.remember(p, record)
		if !a.apply(p, record, state, time.Now()) {
			t.Fatal("initial grant")
		}
		before, _ := s.registry.GetProviderRewardSnapshot(p.ID)

		x := sessionForAuthorization(s, p, record)
		x.store, x.archive, x.owner = mem, mem, "owner"
		ready := func(keyID string) string {
			x.expected, x.started = "ready", time.Time{}
			return x.handle(context.Background(), protocol.AppAttestShadowPayload{Session: x.id, Action: "ready", Result: "ok", KeyID: keyID})
		}
		fail := func(action, result string, appleError *protocol.AppAttestAppleError) {
			t.Helper()
			x.expected = action
			if next := x.handle(context.Background(), protocol.AppAttestShadowPayload{Session: x.id, Action: action, KeyID: x.key.KeyID, Result: result, AppleError: appleError}); next != "stop" {
				t.Fatalf("%s failure continued: %s", action, next)
			}
		}
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		attempts := 0
		var delays []time.Duration
		x.runRecovering(ctx, func(context.Context) {
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
				x.key, _ = mem.GetAppAttestShadowKey(context.Background(), replacement)
				e := record.evidence
				e.Binding.Credential, e.Expected.Credential = replacement, replacement
				e.Binding.Connection, e.Expected.Connection = x.id, x.id
				e.AssertionAt = time.Now()
				applyAppAttestReadiness(&e, state)
				if err := s.RefreshBuildQualifications(ctx); err != nil {
					t.Fatal(err)
				}
				x.updateServingAuthorization(&record.status, e, appattest.EvaluateAuthorization(e, time.Now()))
				cancel()
			}
		}, func(_ context.Context, delay time.Duration) bool {
			delays = append(delays, delay)
			time.Sleep(delay)
			return true
		})
		if attempts != 4 || len(delays) != 3 || delays[0] != time.Minute {
			t.Fatalf("attempts=%d delays=%v", attempts, delays)
		}
		for _, d := range delays[1:] {
			if d < keyRotationRetryMin || d >= time.Minute {
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
		x.expected = "attestation"
		if next := x.handle(context.Background(), protocol.AppAttestShadowPayload{Session: x.id, Action: "attestation", KeyID: old, Challenge: x.challenge, Result: "ok", Proof: "AAAA"}); next != "stop" {
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
	if x.rotationRetryDue("apple_error") {
		t.Fatal("first failure scheduled a rotation retry")
	}
	h.assertionFailure(t, x, key, "apple_error", deadKeyError)
	if !x.rotationRetryDue("apple_error") {
		t.Fatal("threshold failure kept the slow backoff")
	}
	if x.rotationRetryDue("key_unregistered") {
		t.Fatal("key_unregistered without a requested rotation was accelerated")
	}
	for _, other := range []string{"apple_unavailable", "busy", "timeout", "operation_timeout", "storage_error"} {
		if x.rotationRetryDue(other) {
			t.Fatalf("%s accelerated", other)
		}
	}
	// Rate-limited machines keep the normal bounded backoff.
	if _, err := h.mem.RecordAppAttestKeyRotation(context.Background(), store.AppAttestKeyRotation{KeyID: rotationKeyID(9), MachineID: "machine", AccountID: "account", RequestedAt: time.Now().UTC(), Failures: 2, Reason: "assertion_apple_error"}); err != nil {
		t.Fatal(err)
	}
	if x.rotationRetryDue("apple_error") {
		t.Fatal("rate-limited machine scheduled a fast retry")
	}
	x.rotationRequested = true
	if !x.rotationRetryDue("key_unregistered") {
		t.Fatal("client acknowledgement of a requested rotation kept the slow backoff")
	}
	for i := 0; i < 64; i++ {
		if d := keyRotationRetryDelay(); d < 15*time.Second || d > 45*time.Second {
			t.Fatalf("delay %v outside 15-45 s", d)
		}
	}
}
