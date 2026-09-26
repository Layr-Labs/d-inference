package service

import (
	"context"
	"reflect"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

// enrollmentBackoffSession attributes this connection to a canonical machine
// in durable inventory, as the live session does after registration.
func enrollmentBackoffSession(t *testing.T, h *rotationHarness, sessionID string) (*Session, string) {
	t.Helper()
	identity, err := h.mem.ObserveMachine(context.Background(), store.MachineObservation{SessionID: sessionID, AccountID: "account", SEKey: "se", At: time.Now().UTC()})
	if err != nil {
		t.Fatal(err)
	}
	x := h.session(3)
	x.provider.ID = sessionID
	x.inventory = &machineInventorySession{s: h.s, p: x.provider, store: h.mem, identity: identity}
	return x, identity.ID
}

func archiveEnrollmentOutcome(t *testing.T, mem *store.MemoryStore, session, outcome string, at time.Time) {
	t.Helper()
	id := uuid.NewString()
	if err := mem.BeginAppAttestEvidence(context.Background(), store.AppAttestEvidence{ID: id, SessionID: session, KeyID: id, ReceivedAt: at, Action: "attestation", Context: []byte(`{}`)}); err != nil {
		t.Fatal(err)
	}
	if _, err := mem.CompleteAppAttestEvidence(context.Background(), id, store.AppAttestDecision{Outcome: outcome}); err != nil {
		t.Fatal(err)
	}
}

func runInvalidKeyEnrollments(t *testing.T, x *Session, failures int) []time.Duration {
	t.Helper()
	attempts := 0
	var delays []time.Duration
	x.runRecovering(context.Background(), func(ctx context.Context) {
		attempts++
		if attempts > failures {
			x.lastOutcome = "unsupported" // ends the loop
			return
		}
		x.key, x.expected, x.challenge = &store.AppAttestShadowKey{KeyID: rotationKeyID(byte(attempts))}, "attestation", "challenge"
		if next := x.handle(ctx, protocol.AppAttestShadowPayload{Session: x.id, Action: "attestation", KeyID: x.key.KeyID, Result: "apple_invalid_key"}); next != "stop" {
			t.Fatalf("invalid-key enrollment continued: %s", next)
		}
	}, func(_ context.Context, delay time.Duration) bool {
		delays = append(delays, delay)
		return true
	})
	return delays
}

func TestRepeatedFreshKeyInvalidKeyEnrollmentBacksOffSixHours(t *testing.T) {
	h := newRotationHarness(t, 100)
	x, _ := enrollmentBackoffSession(t, h, "connection")
	delays := runInvalidKeyEnrollments(t, x, 4)
	want := []time.Duration{time.Minute, 5 * time.Minute, enrollmentInvalidKeyBackoff, enrollmentInvalidKeyBackoff}
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
			x.runRecovering(context.Background(), func(context.Context) {
				attempts++
				x.lastOutcome = "unsupported" // ends the loop
			}, func(_ context.Context, delay time.Duration) bool {
				delays = append(delays, delay)
				return true
			})
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
		x.runRecovering(context.Background(), func(context.Context) { attempts++ },
			func(context.Context, time.Duration) bool { return false })
		if attempts != 0 {
			t.Fatal("a session that ended during the backoff still enrolled")
		}
	})
}

func TestEnrollmentBackoffLeftMirrorsTheDecisionAtTheLatestFailure(t *testing.T) {
	now := time.Date(2026, 9, 26, 12, 0, 0, 0, time.UTC)
	ago := func(durations ...time.Duration) []time.Time {
		times := make([]time.Time, len(durations))
		for i, d := range durations {
			times[i] = now.Add(-d)
		}
		return times
	}
	for name, tc := range map[string]struct {
		times []time.Time
		want  time.Duration
	}{
		"no failures":                     {nil, 0},
		"two failures":                    {ago(time.Hour, 2*time.Hour), 0},
		"three within a day":              {ago(time.Hour, 2*time.Hour, 23*time.Hour), 5 * time.Hour},
		"oldest outside the latest's day": {ago(time.Hour, 2*time.Hour, 25*time.Hour+time.Second), 0},
		"backoff served":                  {ago(6*time.Hour, 7*time.Hour, 8*time.Hour), 0},
		"clock ahead is capped":           {ago(-time.Hour, time.Hour, 2*time.Hour), enrollmentInvalidKeyBackoff},
	} {
		if got := enrollmentBackoffLeft(tc.times, now); got != tc.want {
			t.Errorf("%s: left = %v, want %v", name, got, tc.want)
		}
	}
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
		if delays := runInvalidKeyEnrollments(t, x, 1); !reflect.DeepEqual(delays, []time.Duration{enrollmentInvalidKeyBackoff}) {
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
		x.inventory = &machineInventorySession{s: h.s, p: x.provider, store: h.mem, identity: identity}
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
		x.expected = "assertion"
		if x.enrollmentBackoffDue("apple_invalid_key") {
			t.Fatal("assertion invalid-key failure used the enrollment backoff")
		}
		x.expected = "attestation"
		for _, other := range []string{"apple_error", "key_unregistered", "timeout", "storage_error"} {
			if x.enrollmentBackoffDue(other) {
				t.Fatalf("%s used the enrollment backoff", other)
			}
		}
	})
}
