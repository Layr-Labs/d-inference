package service

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestClientAppleFailureRetainsBoundedDiagnosticsWithoutAuthorization(t *testing.T) {
	s, p, record, _ := newAuthorizationFixture(t)
	x := sessionForAuthorization(s, p, record)
	x.expected = "attestation"
	details := &protocol.AppAttestAppleError{Domain: "devicecheck", Code: 2}
	var observed map[string]any
	s.emitEvent = func(fields map[string]any) { observed = fields }
	next := x.handleExchange(context.Background(), protocol.AppAttestShadowPayload{Result: "apple_error", AppleError: details}, nil)
	if next != "stop" || observed["apple_error"] != details || observed["outcome"] != "apple_error" {
		t.Fatalf("native failure lost its bounded cause: %s, %+v", next, observed)
	}
	if _, ok := s.registry.ProviderServingAuthorization(p); ok {
		t.Fatal("client diagnostic data authorized a provider")
	}
	// Direct callers also cannot leak arbitrary strings into event fields.
	x.handleExchange(context.Background(), protocol.AppAttestShadowPayload{Result: "apple_error", AppleError: &protocol.AppAttestAppleError{Domain: "private-data"}}, nil)
	if _, ok := observed["apple_error"]; ok {
		t.Fatal("unbounded domain entered telemetry")
	}
}

func TestClientAppleFailureArchivedWithOriginalProofContext(t *testing.T) {
	archive := &capturedProofArchive{}
	x := &Session{s: &Service{}, provider: newSessionProvider("endpoint", "se"), archive: archive, expected: "attestation", rejectReason: "verifier_busy"}
	x.handle(context.Background(), protocol.AppAttestShadowPayload{Action: "attestation", Result: "apple_error", AppleError: &protocol.AppAttestAppleError{Domain: "devicecheck", Code: 2}})
	var context map[string]json.RawMessage
	if err := json.Unmarshal(archive.evidence.Context, &context); err != nil {
		t.Fatal(err)
	}
	var details protocol.AppAttestAppleError
	if err := json.Unmarshal(context["apple_error"], &details); err != nil || details.Domain != "devicecheck" || details.Code != 2 {
		t.Fatalf("native diagnostic absent from evidence context: %+v, %v", details, err)
	}
}

func TestClientPreflightFailureRetainsClosedAvailabilityReasonWithoutAuthorization(t *testing.T) {
	s, p, record, _ := newAuthorizationFixture(t)
	x := sessionForAuthorization(s, p, record)
	x.expected = "ready"
	var observed map[string]any
	s.emitEvent = func(fields map[string]any) { observed = fields }
	reply := protocol.AppAttestShadowPayload{Action: "ready", Result: "unsupported", AvailabilityReason: "is_supported_false"}
	if next := x.handleExchange(context.Background(), reply, nil); next != "stop" || observed["availability_reason"] != "is_supported_false" {
		t.Fatalf("bounded preflight reason lost: %s, %+v", next, observed)
	}
	if _, ok := s.registry.ProviderServingAuthorization(p); ok {
		t.Fatal("client preflight diagnostic authorized a provider")
	}
	reply.AvailabilityReason = "arbitrary private text"
	x.handleExchange(context.Background(), reply, nil)
	if _, ok := observed["availability_reason"]; ok {
		t.Fatal("unbounded preflight reason entered telemetry")
	}
}

func TestSyntheticAppleErrorSourceArchivedWithoutNativeDetails(t *testing.T) {
	archive := &capturedProofArchive{}
	x := &Session{s: &Service{}, provider: newSessionProvider("endpoint", "se"), archive: archive, expected: "attestation", rejectReason: "verifier_busy"}
	x.handle(context.Background(), protocol.AppAttestShadowPayload{Action: "attestation", Result: "apple_error", AppleErrorSource: "callback_without_nserror"})
	var context map[string]json.RawMessage
	if err := json.Unmarshal(archive.evidence.Context, &context); err != nil {
		t.Fatal(err)
	}
	var source string
	if err := json.Unmarshal(context["apple_error_source"], &source); err != nil || source != "callback_without_nserror" {
		t.Fatalf("synthetic Apple error cause absent from evidence: %s, %v", source, err)
	}
	if _, ok := context["apple_error"]; ok {
		t.Fatal("synthetic failure fabricated a native NSError")
	}
}

func TestReadyRuntimeDiagnosticsReachEventAndLaterEvidenceWithoutAuthorization(t *testing.T) {
	s, p, record, _ := newAuthorizationFixture(t)
	x := sessionForAuthorization(s, p, record)
	x.expected = "ready"
	var observed map[string]any
	s.emitEvent = func(fields map[string]any) { observed = fields }
	ready := protocol.AppAttestShadowPayload{Action: "ready", Result: "busy", LaunchSession: "background", BootTime: 1_700_000_000, OperationStalledSeconds: 120}
	if next := x.handleExchange(context.Background(), ready, nil); next != "stop" || observed["launch_session"] != "background" ||
		observed["boot_time"] != int64(1_700_000_000) || observed["operation_stalled_seconds"] != 120 {
		t.Fatalf("runtime diagnostics missing from ready event: %s, %+v", next, observed)
	}
	if _, ok := s.registry.ProviderServingAuthorization(p); ok {
		t.Fatal("runtime diagnostics authorized a provider")
	}
	// Direct callers that bypass admission still cannot leak invalid values.
	x.handleExchange(context.Background(), protocol.AppAttestShadowPayload{Action: "ready", Result: "ok", LaunchSession: "private", BootTime: 5, OperationStalledSeconds: 7}, nil)
	for _, field := range []string{"launch_session", "boot_time", "operation_stalled_seconds"} {
		if _, ok := observed[field]; ok {
			t.Fatalf("invalid %s entered telemetry", field)
		}
	}
	// A proof later in the same attempt carries the ready reply's context.
	archive := &capturedProofArchive{}
	y := &Session{s: &Service{}, provider: newSessionProvider("endpoint", "se"), archive: archive, expected: "assertion", rejectReason: "verifier_busy",
		readyDiagnostics: ready.RuntimeDiagnosticFields(time.Now())}
	y.handle(context.Background(), protocol.AppAttestShadowPayload{Action: "assertion", Result: "apple_error"})
	var archived map[string]any
	if err := json.Unmarshal(archive.evidence.Context, &archived); err != nil {
		t.Fatal(err)
	}
	if archived["launch_session"] != "background" || archived["boot_time"] != float64(1_700_000_000) || archived["operation_stalled_seconds"] != float64(120) {
		t.Fatalf("runtime diagnostics absent from evidence context: %+v", archived)
	}
}
