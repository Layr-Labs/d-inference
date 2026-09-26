package service

import (
	"bytes"
	"context"
	"encoding/base64"
	"io"
	"log/slog"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func rotationKeyID(fill byte) string {
	return base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{fill}, 32))
}

type rotationHarness struct {
	s      *Service
	mem    *store.MemoryStore
	events []map[string]any
}

func newRotationHarness(t *testing.T, percent int) *rotationHarness {
	t.Helper()
	h := &rotationHarness{mem: store.NewMemory(store.Config{})}
	h.s = &Service{store: h.mem, logger: slog.New(slog.NewTextHandler(io.Discard, nil)),
		config: Config{AppID: "TEST.app", Environment: "production", KeyRotationPercent: percent}}
	h.s.emitEvent = func(fields map[string]any) { h.events = append(h.events, fields) }
	return h
}

func (h *rotationHarness) enroll(t *testing.T, keyID, machine string) {
	t.Helper()
	if _, err := h.mem.InsertAppAttestShadowKey(context.Background(), store.AppAttestShadowKey{KeyID: keyID, Owner: "owner", AccountID: "account",
		MachineID: machine, AppID: "TEST.app", Environment: "production", PublicKey: []byte{1}}); err != nil {
		t.Fatal(err)
	}
}

func (h *rotationHarness) session(protocolVersion int) *Session {
	return &Session{s: h.s, provider: newSessionProvider("endpoint", "se"), protocolVersion: protocolVersion, account: "account",
		owner: "owner", id: "session", store: h.mem, archive: h.mem}
}

// assertionFailure drives a client failure through the real archive path.
func (h *rotationHarness) assertionFailure(t *testing.T, x *Session, keyID, result string, appleError *protocol.AppAttestAppleError) {
	t.Helper()
	// The live worker holds the stored key (with its machine and last
	// verified assertion) after ready; mirror that here.
	x.key, _ = h.mem.GetAppAttestShadowKey(context.Background(), keyID)
	if x.key == nil {
		x.key = &store.AppAttestShadowKey{KeyID: keyID}
	}
	x.expected, x.challenge, x.started = "assertion", "challenge", time.Time{}
	if next := x.handle(context.Background(), protocol.AppAttestShadowPayload{Session: x.id, Action: "assertion", KeyID: keyID, Result: result, AppleError: appleError}); next != "stop" {
		t.Fatalf("failure continued the exchange: %s", next)
	}
}

func (h *rotationHarness) ready(t *testing.T, x *Session, keyID string) string {
	t.Helper()
	x.key, x.expected, x.started, x.rotationRequested = nil, "ready", time.Time{}, false
	return x.handleExchange(context.Background(), protocol.AppAttestShadowPayload{Session: x.id, Action: "ready", Result: "ok", KeyID: keyID}, nil)
}

func (h *rotationHarness) rotationOutcomes() []string {
	var outcomes []string
	for _, e := range h.events {
		if e["stage"] == "rotation" {
			outcomes = append(outcomes, e["outcome"].(string))
		}
	}
	h.events = nil
	return outcomes
}

var deadKeyError = &protocol.AppAttestAppleError{Domain: "devicecheck", Code: 0}

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
	if !x.rotationRequested || x.key.KeyID != dead {
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
	if next := h.ready(t, x, second); next != "assert" || x.rotationRequested {
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
	for i := 0; i < keyRotationDailyLimit; i++ {
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

func TestKeyRotationRequiresProtocolCohortAndDeadKeySignals(t *testing.T) {
	t.Run("protocol 1", func(t *testing.T) {
		h := newRotationHarness(t, 100)
		key := rotationKeyID(1)
		h.enroll(t, key, "machine")
		x := h.session(1)
		h.assertionFailure(t, x, key, "apple_error", deadKeyError)
		h.assertionFailure(t, x, key, "apple_error", deadKeyError)
		if next := h.ready(t, x, key); next != "assert" || len(h.rotationOutcomes()) != 0 {
			t.Fatalf("protocol 1 rotated: %s", next)
		}
	})
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
		x.key, x.expected, x.started = &store.AppAttestShadowKey{KeyID: key}, "assertion", time.Now().Add(-shadowResponseTimeout-time.Second)
		x.handle(context.Background(), protocol.AppAttestShadowPayload{Session: x.id, Action: "assertion", KeyID: key, Result: "apple_error", AppleError: deadKeyError})
		x.handle(context.Background(), protocol.AppAttestShadowPayload{Session: x.id, Action: "assertion", KeyID: key, Result: "apple_error", AppleError: deadKeyError})
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

func TestKeyRotationPercentConfiguration(t *testing.T) {
	for raw, want := range map[string]int{"": 100, "0": 0, "37": 37, "abc": -1, "150": 150} {
		t.Setenv("EIGENINFERENCE_APP_ATTEST_KEY_ROTATION_PERCENT", raw)
		if got := ConfigFromEnvironment().KeyRotationPercent; got != want {
			t.Fatalf("%q: %d, want %d", raw, got, want)
		}
	}
	included, excluded := false, false
	for i := 0; i < 200; i++ {
		account := string(rune('a'+i%26)) + string(rune('a'+i/26))
		switch appAttestKeyRotationCohortDecision(account, 50) {
		case "enabled":
			included = true
			if appAttestKeyRotationCohortDecision(account, 60) != "enabled" {
				t.Fatal("cohort shrank when percentage increased")
			}
		case "cohort_excluded":
			excluded = true
		}
	}
	if !included || !excluded {
		t.Fatal("partial cohort did not split accounts")
	}
	if appAttestKeyRotationCohortDecision("", 100) == "enabled" {
		t.Fatal("anonymous account rotated")
	}
}
