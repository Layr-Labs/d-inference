package identity_test

import (
	"context"
	"reflect"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/appattest/inventory"
	recovery "github.com/eigeninference/d-inference/coordinator/internal/appattest/recovery"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
	memorystore "github.com/eigeninference/d-inference/coordinator/store/memory"
	"github.com/google/uuid"
)

// enrollmentBackoffSession attributes this connection to a canonical machine
// in durable inventory, as the live session does after registration.
func enrollmentBackoffSession(t *testing.T, h *rotationHarness, sessionID string) (*rotationExchange, string) {
	t.Helper()
	identity, err := h.mem.ObserveMachine(context.Background(), store.MachineObservation{SessionID: sessionID, AccountID: "account", SEKey: "se", At: time.Now().UTC()})
	if err != nil {
		t.Fatal(err)
	}
	x := h.session(3)
	x.provider.ID = sessionID
	x.inventory = inventory.NewSession(inventory.SessionDependencies{Store: h.mem, Provider: x.provider}, store.MachineObservation{SessionID: sessionID, AccountID: "account", SEKey: "se"})
	x.inventory.Capture(false)
	return x, identity.ID
}

func archiveEnrollmentOutcome(t *testing.T, mem *memorystore.MemoryStore, session, outcome string, at time.Time) {
	t.Helper()
	id := uuid.NewString()
	if err := mem.BeginAppAttestEvidence(context.Background(), store.AppAttestEvidence{ID: id, SessionID: session, KeyID: id, ReceivedAt: at, Action: "attestation", Context: []byte(`{}`)}); err != nil {
		t.Fatal(err)
	}
	if _, err := mem.CompleteAppAttestEvidence(context.Background(), id, store.AppAttestDecision{Outcome: outcome}); err != nil {
		t.Fatal(err)
	}
}

func runInvalidKeyEnrollments(t *testing.T, x *rotationExchange, failures int) []time.Duration {
	t.Helper()
	attempts := 0
	var delays []time.Duration
	x.drive(context.Background(), func(ctx context.Context, binding recovery.Binding) recovery.Outcome {
		attempts++
		if attempts > failures {
			return recovery.Outcome{Reason: "unsupported"}
		}
		x.attempt.Challenge.Credential, x.attempt.Challenge.Expected, x.attempt.Challenge.Binding.Challenge = &store.AppAttestShadowKey{KeyID: rotationKeyID(byte(attempts))}, "attestation", "challenge"
		if next := x.accept(ctx, protocol.AppAttestShadowPayload{Session: binding.Session, Action: "attestation", KeyID: x.attempt.Challenge.Credential.KeyID, Result: "apple_invalid_key"}); next != "stop" {
			t.Fatalf("invalid-key enrollment continued: %s", next)
		}
		return recovery.Outcome{Reason: x.last.Outcome, AssertionAt: x.last.AssertionAt}
	}, func(_ context.Context, delay time.Duration) bool {
		delays = append(delays, delay)
		return true
	}, nil)
	return delays
}

func TestRepeatedFreshKeyInvalidKeyEnrollmentBacksOffSixHours(t *testing.T) {
	h := newRotationHarness(t, 100)
	x, _ := enrollmentBackoffSession(t, h, "connection")
	delays := runInvalidKeyEnrollments(t, x, 4)
	want := []time.Duration{time.Minute, 5 * time.Minute, recovery.EnrollmentInvalidKeyBackoff, recovery.EnrollmentInvalidKeyBackoff}
	if !reflect.DeepEqual(delays, want) {
		t.Fatalf("delays=%v, want %v", delays, want)
	}
	backoffs := 0
	for _, e := range h.events {
		if e["stage"] == "recovery" && e["outcome"] == "enrollment_backoff" {
			backoffs++
		}
	}
	if backoffs != 2 {
		t.Fatalf("enrollment_backoff observed %d times", backoffs)
	}
}

// A reconnect, coordinator restart or release starts a new session. It must
// re-derive a running backoff from the archive before its first exchange.
func TestEnrollmentBackoffResumesInANewSession(t *testing.T) {
	now := time.Now().UTC()
	for name, tc := range map[string]struct {
		ago  []time.Duration
		want time.Duration
	}{
		"backoff still running":                 {ago: []time.Duration{3 * time.Hour, 2 * time.Hour, time.Hour}, want: 5 * time.Hour},
		"backoff already served":                {ago: []time.Duration{9 * time.Hour, 8 * time.Hour, 7 * time.Hour}},
		"below the threshold":                   {ago: []time.Duration{2 * time.Hour, time.Hour}},
		"threshold only across more than a day": {ago: []time.Duration{27 * time.Hour, 26 * time.Hour, time.Hour}},
	} {
		t.Run(name, func(t *testing.T) {
			h := newRotationHarness(t, 100)
			previous, machine := enrollmentBackoffSession(t, h, "previous-connection")
			for _, ago := range tc.ago {
				archiveEnrollmentOutcome(t, h.mem, previous.provider.ID, "apple_invalid_key", now.Add(-ago))
			}
			x, current := enrollmentBackoffSession(t, h, "connection")
			if current != machine {
				t.Fatal("fixture connections are on different machines")
			}
			attempts := 0
			var delays []time.Duration
			x.drive(context.Background(), func(context.Context, recovery.Binding) recovery.Outcome {
				attempts++
				return recovery.Outcome{Reason: "unsupported"}
			}, func(_ context.Context, delay time.Duration) bool {
				delays = append(delays, delay)
				return true
			}, nil)
			resumed := 0
			for _, e := range h.events {
				if e["stage"] == "recovery" && e["outcome"] == "enrollment_backoff_resumed" {
					resumed++
				}
			}
			if attempts != 1 {
				t.Fatalf("attempts = %d, want 1", attempts)
			}
			if tc.want == 0 {
				if len(delays) != 0 || resumed != 0 {
					t.Fatalf("unexpected backoff: delays=%v resumed=%d", delays, resumed)
				}
				return
			}
			if len(delays) != 1 || delays[0] > tc.want || delays[0] < tc.want-time.Minute || resumed != 1 {
				t.Fatalf("delays=%v resumed=%d, want one wait of about %v", delays, resumed, tc.want)
			}
		})
	}
	t.Run("session ends during the wait", func(t *testing.T) {
		h := newRotationHarness(t, 100)
		previous, _ := enrollmentBackoffSession(t, h, "previous-connection")
		for _, ago := range []time.Duration{3 * time.Hour, 2 * time.Hour, time.Hour} {
			archiveEnrollmentOutcome(t, h.mem, previous.provider.ID, "apple_invalid_key", now.Add(-ago))
		}
		x, _ := enrollmentBackoffSession(t, h, "connection")
		attempts := 0
		x.drive(context.Background(), func(context.Context, recovery.Binding) recovery.Outcome { attempts++; return recovery.Outcome{} },
			func(context.Context, time.Duration) bool { return false }, nil)
		if attempts != 0 {
			t.Fatal("a session that ended during the backoff still enrolled")
		}
	})
}

func TestEnrollmentBackoffCountsOnlyTrailingDayOnSameMachine(t *testing.T) {
	t.Run("older than 24 hours", func(t *testing.T) {
		h := newRotationHarness(t, 100)
		x, _ := enrollmentBackoffSession(t, h, "connection")
		for i := 0; i < 5; i++ {
			archiveEnrollmentOutcome(t, h.mem, "connection", "apple_invalid_key", time.Now().UTC().Add(-25*time.Hour-time.Duration(i)*time.Minute))
		}
		if delays := runInvalidKeyEnrollments(t, x, 1); !reflect.DeepEqual(delays, []time.Duration{time.Minute}) {
			t.Fatalf("stale failures triggered backoff: %v", delays)
		}
	})
	t.Run("earlier connection of the same machine", func(t *testing.T) {
		h := newRotationHarness(t, 100)
		previous, machine := enrollmentBackoffSession(t, h, "previous-connection")
		archiveEnrollmentOutcome(t, h.mem, previous.provider.ID, "apple_invalid_key", time.Now().UTC().Add(-2*time.Hour))
		archiveEnrollmentOutcome(t, h.mem, previous.provider.ID, "apple_invalid_key", time.Now().UTC().Add(-time.Hour))
		// A verified attestation in between does not reset the window.
		archiveEnrollmentOutcome(t, h.mem, previous.provider.ID, "verified", time.Now().UTC().Add(-30*time.Minute))
		x, current := enrollmentBackoffSession(t, h, "connection")
		if current != machine {
			t.Fatal("fixture connections are on different machines")
		}
		if delays := runInvalidKeyEnrollments(t, x, 1); !reflect.DeepEqual(delays, []time.Duration{recovery.EnrollmentInvalidKeyBackoff}) {
			t.Fatalf("third failure in a day on one machine: %v", delays)
		}
	})
	t.Run("another machine", func(t *testing.T) {
		h := newRotationHarness(t, 100)
		other, _ := enrollmentBackoffSession(t, h, "other-connection")
		archiveEnrollmentOutcome(t, h.mem, other.provider.ID, "apple_invalid_key", time.Now().UTC())
		archiveEnrollmentOutcome(t, h.mem, other.provider.ID, "apple_invalid_key", time.Now().UTC())
		identity, err := h.mem.ObserveMachine(context.Background(), store.MachineObservation{SessionID: "connection", AccountID: "account", SEKey: "different-se", At: time.Now().UTC()})
		if err != nil {
			t.Fatal(err)
		}
		x := h.session(3)
		x.provider.ID = "connection"
		x.inventory = inventory.NewSession(inventory.SessionDependencies{Store: h.mem, Provider: x.provider}, store.MachineObservation{SessionID: "connection", AccountID: "account", SEKey: "different-se"})
		x.inventory.Capture(false)
		if x.inventory.Identity().ID != identity.ID {
			t.Fatal("fixture inventory changed canonical identity")
		}
		if delays := runInvalidKeyEnrollments(t, x, 1); !reflect.DeepEqual(delays, []time.Duration{time.Minute}) {
			t.Fatalf("another machine's failures delayed this one: %v", delays)
		}
	})
	t.Run("other failures keep existing backoff", func(t *testing.T) {
		h := newRotationHarness(t, 100)
		x, _ := enrollmentBackoffSession(t, h, "connection")
		for i := 0; i < 5; i++ {
			archiveEnrollmentOutcome(t, h.mem, "connection", "apple_invalid_key", time.Now().UTC())
		}
		x.attempt.Challenge.Expected = "assertion"
		if x.enrollment.Due("apple_invalid_key", x.attempt.Challenge.Expected) {
			t.Fatal("assertion invalid-key failure used the enrollment backoff")
		}
		x.attempt.Challenge.Expected = "attestation"
		for _, other := range []string{"apple_error", "key_unregistered", "timeout", "storage_error"} {
			if x.enrollment.Due(other, x.attempt.Challenge.Expected) {
				t.Fatalf("%s used the enrollment backoff", other)
			}
		}
	})
}
