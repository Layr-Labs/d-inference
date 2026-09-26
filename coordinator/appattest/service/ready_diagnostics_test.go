package service

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func diagnosticBool(v bool) *bool { return &v }

func TestDeepReadyDiagnosticsReachProofEventAndEvidenceWithDerivedLifecycle(t *testing.T) {
	h := newRotationHarness(t, 0)
	keyID := rotationKeyID(4)
	h.enroll(t, keyID, "machine")
	stored, _ := h.mem.GetAppAttestShadowKey(context.Background(), keyID)
	lastSuccess := stored.UpdatedAt
	x := h.session(3)
	x.key, x.expected, x.started = nil, "ready", time.Time{}
	ready := protocol.AppAttestShadowPayload{Session: x.id, Action: "ready", Result: "ok", KeyID: keyID,
		BootTime: lastSuccess.Add(-time.Hour).Unix(), ProcessStartedAt: lastSuccess.Add(time.Minute).Unix(),
		PreviousExit: "clean", StartReason: "update", ConsoleUserActive: diagnosticBool(true), SIPEnabled: diagnosticBool(true),
		Preflight: &protocol.AppAttestPreflight{BundlePathClass: "user_install"}, PushHistory: &protocol.AppAttestPushHistory{DeviceTokenPresent: diagnosticBool(true)}}
	if next := x.handleExchange(context.Background(), ready, nil); next != "assert" {
		t.Fatalf("ready for a known key: %s", next)
	}
	archive := &capturedProofArchive{}
	x.archive, x.expected, x.challenge = archive, "assertion", "challenge"
	chain := []protocol.AppAttestNativeError{{Domain: "devicecheck", Code: 0}, {Domain: "cryptotokenkit", Code: -3}, {Domain: "aks", Code: -536362989}}
	x.handle(context.Background(), protocol.AppAttestShadowPayload{Session: x.id, Action: "assertion", KeyID: keyID, Result: "apple_error",
		AppleError: &protocol.AppAttestAppleError{Domain: "devicecheck", Code: 0}, NativeErrorChain: chain})

	var event map[string]any
	for _, e := range h.events {
		if e["stage"] == "assertion" {
			event = e
		}
	}
	var archived map[string]any
	if err := json.Unmarshal(archive.evidence.Context, &archived); err != nil {
		t.Fatal(err)
	}
	for name, fields := range map[string]map[string]any{"event": event, "evidence": archived} {
		raw, _ := json.Marshal(fields)
		var got map[string]any
		_ = json.Unmarshal(raw, &got)
		if got["rebooted_since_last_success"] != false || got["process_restarted_since_last_success"] != true {
			t.Fatalf("%s: derived lifecycle wrong: %v", name, got)
		}
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

func TestDerivedLifecycleNeedsBothInstants(t *testing.T) {
	last := time.Unix(1_780_000_000, 0)
	key := &store.AppAttestShadowKey{UpdatedAt: last}
	fields := map[string]any{"boot_time": last.Unix() + 1}
	deriveKeyLifecycleDiagnostics(fields, key)
	if fields["rebooted_since_last_success"] != true {
		t.Fatalf("reboot after last success not derived: %v", fields)
	}
	if _, ok := fields["process_restarted_since_last_success"]; ok {
		t.Fatal("derived without process_started_at")
	}
	fields = map[string]any{"boot_time": last.Unix(), "process_started_at": last.Unix()}
	deriveKeyLifecycleDiagnostics(fields, key)
	if fields["rebooted_since_last_success"] != false || fields["process_restarted_since_last_success"] != false {
		t.Fatalf("equal instants are not after the last success: %v", fields)
	}
	fields = map[string]any{"boot_time": last.Unix() + 1}
	deriveKeyLifecycleDiagnostics(fields, &store.AppAttestShadowKey{})
	if len(fields) != 1 {
		t.Fatalf("derived without a last-success time: %v", fields)
	}
}

func TestDeepDiagnosticsNeverAuthorize(t *testing.T) {
	s, p, record, _ := newAuthorizationFixture(t)
	x := sessionForAuthorization(s, p, record)
	x.expected = "ready"
	ready := protocol.AppAttestShadowPayload{Action: "ready", Result: "unsupported", AvailabilityReason: "is_supported_false",
		ProcessStartedAt: time.Now().Unix(), PreviousExit: "clean", StartReason: "launchd", ConsoleUserActive: diagnosticBool(true),
		SIPEnabled: diagnosticBool(true), AuthenticatedRoot: diagnosticBool(true),
		Preflight:  &protocol.AppAttestPreflight{OptInEntitlement: diagnosticBool(true), EnvironmentEntitlement: "production", ProfilePresent: diagnosticBool(true), ProfileExpired: diagnosticBool(false), BundlePathClass: "applications"},
		KeyHistory: &protocol.AppAttestKeyHistory{CreatedBootMatches: diagnosticBool(true), CreatedAppVersion: "0.9.10"}}
	if next := x.handleExchange(context.Background(), ready, nil); next != "stop" {
		t.Fatalf("unsupported ready continued: %s", next)
	}
	x.expected = "assertion"
	x.handleExchange(context.Background(), protocol.AppAttestShadowPayload{Action: "assertion", Result: "apple_error",
		NativeErrorChain: []protocol.AppAttestNativeError{{Domain: "devicecheck", Code: 0}}}, nil)
	if _, ok := s.registry.ProviderServingAuthorization(p); ok {
		t.Fatal("deep diagnostics authorized a provider")
	}
}

func TestAppAttestShadowInboxStripsInvalidDeepDiagnosticsWithoutDropping(t *testing.T) {
	x := &Session{in: make(chan protocol.AppAttestShadowPayload, 3)}
	bad := -1
	x.offer(protocol.AppAttestShadowPayload{Action: "ready", Result: "ok", PreviousExit: "/Users/private", StartReason: "reboot", ProcessStartedAt: 1,
		Preflight: &protocol.AppAttestPreflight{BundlePathClass: "/Applications"}, KeyHistory: &protocol.AppAttestKeyHistory{GenerationsLast24h: &bad}})
	x.offer(protocol.AppAttestShadowPayload{Action: "assertion", Result: "apple_error", NativeErrorChain: make([]protocol.AppAttestNativeError, 5)})
	x.offer(protocol.AppAttestShadowPayload{Action: "assertion", Result: "ok", SIPEnabled: diagnosticBool(true), NativeErrorChain: []protocol.AppAttestNativeError{{Domain: "aks"}}})
	if len(x.in) != 3 || x.dropped.Load() != 0 {
		t.Fatalf("deep diagnostics dropped a frame: queued=%d dropped=%d", len(x.in), x.dropped.Load())
	}
	ready, oversized, misplaced := <-x.in, <-x.in, <-x.in
	if ready.PreviousExit != "" || ready.StartReason != "" || ready.ProcessStartedAt != 0 || ready.Preflight != nil || ready.KeyHistory != nil {
		t.Fatalf("invalid ready diagnostics admitted: %+v", ready)
	}
	if oversized.NativeErrorChain != nil || misplaced.NativeErrorChain != nil || misplaced.SIPEnabled != nil {
		t.Fatalf("invalid or misplaced diagnostics admitted: %+v %+v", oversized, misplaced)
	}
}
