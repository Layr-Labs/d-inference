package identity_test

import (
	"context"
	"testing"
	"time"

	recovery "github.com/eigeninference/d-inference/coordinator/internal/appattest/recovery"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestKnownKeyWithRepeatedDeadKeyFailuresIsSentAttest(t *testing.T) {
	h := newRotationHarness(t, 100)
	dead := rotationKeyID(1)
	h.enroll(t, dead, "machine")
	x := h.session(3)
	h.assertionFailure(t, x, dead, "apple_error", deadKeyError)
	if next := h.ready(t, x, dead); next != "assert" || len(h.rotationOutcomes()) != 0 {
		t.Fatal("one Apple error rotated an accepted key")
	}
	h.assertionFailure(t, x, dead, "apple_error", nil) // 0.9.8 clients send no code
	if next := h.ready(t, x, dead); next != "attest" {
		t.Fatalf("dead key was asked to assert again: %s", next)
	}
	if got := h.rotationOutcomes(); len(got) != 1 || got[0] != "requested" {
		t.Fatalf("rotation observation %v", got)
	}
	rotation, err := h.mem.GetAppAttestKeyRotation(context.Background(), dead)
	if err != nil || rotation == nil || rotation.MachineID != "machine" || rotation.Failures != 2 || rotation.AccountID != "account" {
		t.Fatalf("rotation not durably recorded: %+v %v", rotation, err)
	}
	if !x.rotation.RetryDue("key_unregistered", "attestation", x.attempt.Challenge.Credential) || x.attempt.Challenge.Credential.KeyID != dead {
		t.Fatal("attest must name the dead key so released clients retire it")
	}
	if state, _ := h.mem.GetAppAttestReadiness(context.Background(), dead); state.Revoked {
		t.Fatal("rotation revoked the machine's key")
	}
}

func TestKeyRotationIsRateLimitedPerMachine(t *testing.T) {
	h := newRotationHarness(t, 100)
	first, second, other := rotationKeyID(1), rotationKeyID(2), rotationKeyID(3)
	for _, key := range []string{first, second} {
		h.enroll(t, key, "machine")
	}
	h.enroll(t, other, "other-machine")
	x := h.session(3)
	for _, key := range []string{first, second, other} {
		h.assertionFailure(t, x, key, "apple_error", deadKeyError)
		h.assertionFailure(t, x, key, "apple_error", deadKeyError)
	}
	if h.ready(t, x, first) != "attest" {
		t.Fatal("first rotation not requested")
	}
	h.rotationOutcomes()
	if next := h.ready(t, x, second); next != "assert" || x.rotation.RetryDue("key_unregistered", "attestation", x.attempt.Challenge.Credential) {
		t.Fatalf("second rotation on one machine within an hour: %s", next)
	}
	if got := h.rotationOutcomes(); len(got) != 1 || got[0] != "rate_limited" {
		t.Fatalf("rate limit observation %v", got)
	}
	if h.ready(t, x, other) != "attest" {
		t.Fatal("another machine was rate limited by this one")
	}
	// Four rotations in the trailing day also block, even outside the hour.
	h2 := newRotationHarness(t, 100)
	key := rotationKeyID(4)
	h2.enroll(t, key, "busy-machine")
	for i := 0; i < recovery.RotationDailyLimit; i++ {
		if _, err := h2.mem.RecordAppAttestKeyRotation(context.Background(), store.AppAttestKeyRotation{KeyID: rotationKeyID(byte(10 + i)), MachineID: "busy-machine",
			AccountID: "account", RequestedAt: time.Now().UTC().Add(-time.Duration(2+i) * time.Hour), Failures: 2, Reason: "assertion_apple_error"}); err != nil {
			t.Fatal(err)
		}
	}
	y := h2.session(3)
	h2.assertionFailure(t, y, key, "apple_error", deadKeyError)
	h2.assertionFailure(t, y, key, "apple_error", deadKeyError)
	if next := h2.ready(t, y, key); next != "assert" {
		t.Fatalf("daily rotation limit ignored: %s", next)
	}
}

func TestKeyRotationRequiresCohortAndDeadKeySignals(t *testing.T) {
	for _, tc := range []struct {
		percent int
		want    string
	}{{0, "cohort_excluded"}, {-1, "configuration_error"}, {101, "configuration_error"}} {
		t.Run(tc.want, func(t *testing.T) {
			h := newRotationHarness(t, tc.percent)
			key := rotationKeyID(1)
			h.enroll(t, key, "machine")
			x := h.session(3)
			h.assertionFailure(t, x, key, "apple_error", deadKeyError)
			h.assertionFailure(t, x, key, "apple_error", deadKeyError)
			if next := h.ready(t, x, key); next != "assert" {
				t.Fatalf("excluded account rotated: %s", next)
			}
			if got := h.rotationOutcomes(); len(got) != 1 || got[0] != tc.want {
				t.Fatalf("cohort observation %v", got)
			}
		})
	}
	t.Run("transient failures never count", func(t *testing.T) {
		h := newRotationHarness(t, 100)
		key := rotationKeyID(1)
		h.enroll(t, key, "machine")
		x := h.session(3)
		for _, result := range []string{"apple_unavailable", "busy", "operation_timeout", "unsupported", "apple_unavailable", "busy"} {
			h.assertionFailure(t, x, key, result, nil)
		}
		h.assertionFailure(t, x, key, "apple_error", &protocol.AppAttestAppleError{Domain: "devicecheck", Code: 4})
		// A coordinator-side timeout records the late reply as a timeout.
		x.attempt.Challenge.Credential, x.attempt.Challenge.Expected, x.attempt.Challenge.Started = &store.AppAttestShadowKey{KeyID: key}, "assertion", time.Now().Add(-recovery.ResponseTimeout-time.Second)
		x.accept(context.Background(), protocol.AppAttestShadowPayload{Session: x.attempt.Challenge.Binding.Session, Action: "assertion", KeyID: key, Result: "apple_error", AppleError: deadKeyError})
		x.accept(context.Background(), protocol.AppAttestShadowPayload{Session: x.attempt.Challenge.Binding.Session, Action: "assertion", KeyID: key, Result: "apple_error", AppleError: deadKeyError})
		h.assertionFailure(t, x, key, "apple_error", deadKeyError) // one real signal
		if next := h.ready(t, x, key); next != "assert" || len(h.rotationOutcomes()) != 0 {
			t.Fatalf("transient failures rotated a key: %s", next)
		}
	})
	t.Run("verified assertion restarts the count", func(t *testing.T) {
		h := newRotationHarness(t, 100)
		key := rotationKeyID(1)
		h.enroll(t, key, "machine")
		x := h.session(3)
		h.assertionFailure(t, x, key, "apple_error", deadKeyError)
		time.Sleep(time.Millisecond)
		if ok, _ := h.mem.AdvanceAppAttestShadowCounter(context.Background(), key, "owner", 1); !ok {
			t.Fatal("counter")
		}
		h.assertionFailure(t, x, key, "apple_error", deadKeyError)
		if next := h.ready(t, x, key); next != "assert" {
			t.Fatal("a failure before the last verified assertion counted")
		}
	})
}
