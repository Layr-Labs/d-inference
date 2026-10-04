package exchange_test

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/evidence"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/exchange"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/observation"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/storage"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/transcript"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
	memorystore "github.com/eigeninference/d-inference/coordinator/store/memory"
	"github.com/fxamacker/cbor/v2"
)

type lifecycleArchive struct {
	*memorystore.MemoryStore
	context json.RawMessage
	readErr error
}

func (a *lifecycleArchive) BeginAppAttestEvidence(ctx context.Context, e store.AppAttestEvidence) error {
	a.context = e.Context
	return a.MemoryStore.BeginAppAttestEvidence(ctx, e)
}

func (a *lifecycleArchive) GetAppAttestAssertionDiagnostics(ctx context.Context, keyID string) (*store.AppAttestAssertionDiagnostics, error) {
	if a.readErr != nil {
		return nil, a.readErr
	}
	return a.MemoryStore.GetAppAttestAssertionDiagnostics(ctx, keyID)
}

type lifecycleHarness struct {
	mem    *memorystore.MemoryStore
	events []map[string]any
}

type lifecycleExchange struct {
	attempt   exchange.Attempt
	deps      exchange.PipelineDependencies
	integrity evidence.Integrity
	last      exchange.ReplyResult
}

func (x *lifecycleExchange) accept(ctx context.Context, reply protocol.AppAttestShadowPayload) string {
	x.last = exchange.NewPipeline(x.deps).Handle(ctx, x.attempt, reply)
	if x.last.ReadyObserved {
		x.attempt.ReadyContext = x.last.ReadyContext
	}
	if x.last.Credential != nil {
		x.attempt.Challenge.Credential = x.last.Credential
	}
	return x.last.Next
}

func newLifecycleSession(t *testing.T) (*lifecycleHarness, *lifecycleExchange, *lifecycleArchive, *ecdsa.PrivateKey) {
	t.Helper()
	h := &lifecycleHarness{mem: memorystore.NewMemory(store.Config{})}
	private, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	record := store.AppAttestShadowKey{KeyID: base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{4}, 32)), Owner: "owner", AppID: "TEST.app", Environment: "production",
		PublicKey: elliptic.Marshal(private.Curve, private.X, private.Y)}
	if _, err := h.mem.InsertAppAttestShadowKey(t.Context(), record); err != nil {
		t.Fatal(err)
	}
	a := &lifecycleArchive{MemoryStore: h.mem}
	x := &lifecycleExchange{attempt: exchange.Attempt{Challenge: exchange.Challenge{Binding: transcript.Binding{Session: "session", Owner: "owner", Account: "account", PublicKey: "endpoint", AppID: "TEST.app", Environment: "production", ProtocolVersion: 3}, Credential: &record}}}
	budget := &storage.Budget{}
	x.deps = exchange.PipelineDependencies{Verification: exchange.Dependencies{Keys: h.mem,
		Verifier:     appattest.New(appattest.Policy{AppID: "TEST.app", Environment: "production"}),
		OwnerMatches: func(_ context.Context, key *store.AppAttestShadowKey) bool { return key.Owner == "owner" },
		Observe: func(stage, outcome string, metadata *appattest.Key, reply protocol.AppAttestShadowPayload) {
			event := observation.Format(observation.Event{Provider: newSessionProvider("endpoint", "se"), Session: "session", Account: "account", Stage: stage, Outcome: outcome,
				Metadata: metadata, ReadyContext: x.attempt.ReadyContext, Reply: reply})
			h.events = append(h.events, event.Fields)
		}}, Archive: a, Enrollments: h.mem, Provider: newSessionProvider("endpoint", "se"), Budget: budget, Scope: storage.NewScope(budget), Integrity: &x.integrity}
	return h, x, a, private
}

func lifecycleReady(t *testing.T, x *lifecycleExchange, boot, process int64) {
	t.Helper()
	x.attempt.Challenge.Expected = "ready"
	ready := protocol.AppAttestShadowPayload{Session: x.attempt.Challenge.Binding.Session, Action: "ready", Result: "ok", KeyID: x.attempt.Challenge.Credential.KeyID,
		BootTime: boot, ProcessStartedAt: process, PreviousExit: "clean", StartReason: "update",
		ConsoleUserActive: diagnosticBool(true), SIPEnabled: diagnosticBool(true),
		Preflight:   &protocol.AppAttestPreflight{BundlePathClass: "user_install"},
		PushHistory: &protocol.AppAttestPushHistory{DeviceTokenPresent: diagnosticBool(true)}}
	if next := x.accept(t.Context(), ready); next != "assert" {
		t.Fatalf("ready for known key: %s", next)
	}
}

func lifecycleAssertion(t *testing.T, x *lifecycleExchange, private *ecdsa.PrivateKey, counter byte) {
	t.Helper()
	x.attempt.Challenge.Expected, x.attempt.Challenge.Binding.Challenge = "assertion", "challenge"
	x.integrity.BeginChallenge()
	rp := sha256.Sum256([]byte("TEST.app"))
	auth := append(append([]byte{}, rp[:]...), 0, 0, 0, 0, counter)
	status := &protocol.AppAttestStatus{OSVersion: "27"}
	c := x.attempt.Challenge
	hash := protocol.AppAttestShadowHashV3("assert", c.Binding.Session, c.Binding.Environment, c.Credential.KeyID, c.Binding.Challenge, c.Binding.PublicKey, transcript.AccountScope(c.Binding.Account), status)
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
	if next := x.accept(t.Context(), protocol.AppAttestShadowPayload{Session: c.Binding.Session, Action: "assertion", Result: "ok", KeyID: c.Credential.KeyID,
		Challenge: c.Binding.Challenge, Proof: base64.StdEncoding.EncodeToString(body), ProtocolVersion: 3, Status: status}); next != "wait" || !x.integrity.Complete() {
		t.Fatalf("assertion did not durably verify: next=%s outcome=%s", next, x.last.Outcome)
	}
}

func checkLifecycleOutput(t *testing.T, h *lifecycleHarness, a *lifecycleArchive, reboot, restart any) {
	t.Helper()
	var event map[string]any
	for _, e := range h.events {
		if e["stage"] == "assertion" {
			event = e
		}
	}
	var archived map[string]any
	if err := json.Unmarshal(a.context, &archived); err != nil {
		t.Fatal(err)
	}
	for name, fields := range map[string]map[string]any{"event": event, "evidence": archived} {
		for key, want := range map[string]any{"rebooted_since_last_success": reboot, "process_restarted_since_last_success": restart} {
			got, present := fields[key]
			if got != want || present != (want != nil) {
				t.Fatalf("%s %s = %v (present=%v), want %v", name, key, got, present, want)
			}
		}
	}
}

func TestLifecycleDiagnosticsUseProviderEvidenceAndAdvanceOnAssertions(t *testing.T) {
	for _, skew := range []time.Duration{-6 * time.Hour, 0, 6 * time.Hour} {
		for _, tc := range []struct {
			name          string
			boot, process int64
			reboot        bool
			restart       any
		}{
			{"unchanged", 0, 0, false, nil},
			{"boot_tolerance_forward", 60, 0, false, nil},
			{"boot_tolerance_backward", -60, 0, false, nil},
			{"process_restart", 0, 10, false, true},
			{"reboot_forward", 61, 120, true, true},
			{"reboot_backward", -61, -120, true, true},
		} {
			t.Run(skew.String()+"/"+tc.name, func(t *testing.T) {
				h, x, a, private := newLifecycleSession(t)
				boot := time.Now().Add(skew).Unix()
				process := boot + 300
				lifecycleReady(t, x, boot, process)
				lifecycleAssertion(t, x, private, 1)
				// A key insertion is not a successful assertion baseline.
				checkLifecycleOutput(t, h, a, nil, nil)
				lifecycleReady(t, x, boot+tc.boot, process+tc.process)
				lifecycleAssertion(t, x, private, 2)
				checkLifecycleOutput(t, h, a, tc.reboot, tc.restart)
				// No new prepare: the periodic assertion must compare with proof 2,
				// not keep reporting the transition first seen against proof 1.
				lifecycleAssertion(t, x, private, 3)
				checkLifecycleOutput(t, h, a, false, nil)
			})
		}
	}
}

func TestLifecycleDiagnosticsPreserveUnknownMembersAndIgnoreReadFailure(t *testing.T) {
	const timestamp = int64(1_780_000_000)
	for _, tc := range []struct {
		name            string
		baseline        string
		boot, process   int64
		reboot, restart any
		readErr         error
	}{
		{"legacy", `{}`, timestamp, timestamp, nil, nil, nil},
		{"invalid_boot_type", `{"boot_time":"1780000000","process_started_at":1780000000}`, timestamp, timestamp, nil, nil, nil},
		{"invalid_process_range", `{"boot_time":1780000000,"process_started_at":1}`, timestamp, timestamp, false, nil, nil},
		{"invalid_boot_future", `{"boot_time":9223372036854775807,"process_started_at":1780000000}`, timestamp, timestamp, nil, nil, nil},
		{"missing_current_boot", `{"boot_time":1780000000,"process_started_at":1780000000}`, 0, timestamp, nil, nil, nil},
		{"invalid_current_process", `{"boot_time":1780000000,"process_started_at":1780000000}`, timestamp, 1, false, nil, nil},
		{"lookup_failure", `{"boot_time":1780000000,"process_started_at":1780000000}`, timestamp, timestamp, nil, nil, errors.New("read unavailable")},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h, x, a, private := newLifecycleSession(t)
			// Retain a prior diagnostic-bearing success; a newer legacy success
			// must make the baseline unknown rather than falling back to it.
			lifecycleReady(t, x, timestamp, timestamp)
			lifecycleAssertion(t, x, private, 1)
			id := "baseline"
			if err := h.mem.BeginAppAttestEvidence(t.Context(), store.AppAttestEvidence{ID: id, KeyID: x.attempt.Challenge.Credential.KeyID, SessionID: x.attempt.Challenge.Binding.Session,
				Action: "assertion", ReceivedAt: time.Now(), Context: json.RawMessage(tc.baseline)}); err != nil {
				t.Fatal(err)
			}
			counter := uint32(2)
			if outcome, err := h.mem.CompleteAppAttestEvidence(t.Context(), id, store.AppAttestDecision{Outcome: "verified", Counter: &counter, KeyID: x.attempt.Challenge.Credential.KeyID, Owner: x.attempt.Challenge.Binding.Owner}); err != nil || outcome != "verified" {
				t.Fatalf("baseline commit: %s %v", outcome, err)
			}
			a.readErr = tc.readErr
			lifecycleReady(t, x, tc.boot, tc.process)
			lifecycleAssertion(t, x, private, 3)
			checkLifecycleOutput(t, h, a, tc.reboot, tc.restart)
			if x.integrity.Dropped() != 0 || x.attempt.Challenge.Credential.Counter != 3 {
				t.Fatal("optional diagnostics fenced or rejected a valid proof")
			}
		})
	}
}

func TestDeepReadyDiagnosticsReachProofEventAndEvidenceWithDerivedLifecycle(t *testing.T) {
	h, x, a, private := newLifecycleSession(t)
	const boot = int64(1_780_000_000)
	lifecycleReady(t, x, boot, boot+300)
	lifecycleAssertion(t, x, private, 1)
	lifecycleReady(t, x, boot, boot+600)
	x.attempt.Challenge.Expected, x.attempt.Challenge.Binding.Challenge = "assertion", "challenge"
	chain := []protocol.AppAttestNativeError{{Domain: "devicecheck", Code: 0}, {Domain: "cryptotokenkit", Code: -3}, {Domain: "aks", Code: -536362989}}
	x.accept(t.Context(), protocol.AppAttestShadowPayload{Session: x.attempt.Challenge.Binding.Session, Action: "assertion", KeyID: x.attempt.Challenge.Credential.KeyID, Result: "apple_error",
		AppleError: &protocol.AppAttestAppleError{Domain: "devicecheck", Code: 0}, NativeErrorChain: chain})
	checkLifecycleOutput(t, h, a, false, true)
	var archived map[string]any
	if err := json.Unmarshal(a.context, &archived); err != nil {
		t.Fatal(err)
	}
	var event map[string]any
	for _, e := range h.events {
		if e["stage"] == "assertion" {
			event = e
		}
	}
	for name, fields := range map[string]map[string]any{"event": event, "evidence": archived} {
		raw, _ := json.Marshal(fields)
		var got map[string]any
		_ = json.Unmarshal(raw, &got)
		if got["previous_exit"] != "clean" || got["start_reason"] != "update" || got["console_user_active"] != true || got["sip_enabled"] != true {
			t.Fatalf("%s: ready diagnostics missing: %v", name, got)
		}
		if preflight, _ := got["preflight"].(map[string]any); preflight["bundle_path_class"] != "user_install" {
			t.Fatalf("%s: preflight missing: %v", name, got["preflight"])
		}
		if pushes, _ := got["push_history"].(map[string]any); pushes["device_token_present"] != true {
			t.Fatalf("%s: push history missing: %v", name, got["push_history"])
		}
		entries, _ := got["native_error_chain"].([]any)
		if len(entries) != 3 || entries[2].(map[string]any)["domain"] != "aks" || entries[2].(map[string]any)["code"] != float64(-536362989) {
			t.Fatalf("%s: native chain missing: %v", name, got["native_error_chain"])
		}
	}
}
