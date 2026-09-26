package service

import (
	"context"
	"encoding/json"
	"testing"

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
