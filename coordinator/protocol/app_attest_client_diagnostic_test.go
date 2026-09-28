package protocol

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestAppAttestClientDiagnosticsAreClosedAndOptional(t *testing.T) {
	valid := []AppAttestShadowPayload{
		{Action: "ready", Result: "unsupported", AvailabilityReason: "is_supported_false"},
		{Action: "ready", Result: "not_configured", AvailabilityReason: "opt_in_missing"},
		{Action: "assertion", Result: "apple_error", AppleErrorSource: "callback_without_nserror"},
		{Action: "attestation", Result: "apple_error", AppleErrorSource: "proof_oversize"},
	}
	for _, p := range valid {
		if !p.ValidClientDiagnostics() {
			t.Fatalf("valid closed diagnostic rejected: %+v", p)
		}
	}
	invalid := []AppAttestShadowPayload{
		{Action: "ready", Result: "unsupported", AvailabilityReason: "private/path"},
		{Action: "assertion", Result: "unsupported", AvailabilityReason: "is_supported_false"},
		{Action: "ready", Result: "ok", AvailabilityReason: "is_supported_false"},
		{Action: "ready", Result: "apple_error", AvailabilityReason: "is_supported_false"},
		{Action: "assertion", Result: "apple_error", AppleErrorSource: "arbitrary-message"},
		{Action: "assertion", Result: "ok", AppleErrorSource: "proof_oversize"},
		{Action: "assertion", Result: "apple_error", AppleErrorSource: "proof_oversize", AppleError: &AppAttestAppleError{Domain: "devicecheck", Code: 0}},
		{Action: "ready", Result: "apple_error", AvailabilityReason: "is_supported_false", AppleErrorSource: "callback_without_nserror"},
	}
	for _, p := range invalid {
		if p.ValidClientDiagnostics() {
			t.Fatalf("unbounded or misplaced client diagnostic accepted: %+v", p)
		}
	}
	body, err := json.Marshal(AppAttestShadowPayload{Action: "ready", Session: "session"})
	if err != nil || strings.Contains(string(body), "availability_reason") || strings.Contains(string(body), "apple_error_source") {
		t.Fatalf("optional diagnostics changed old wire encoding: %s, %v", body, err)
	}
	body, err = json.Marshal(valid[0])
	if err != nil || !strings.Contains(string(body), `"availability_reason":"is_supported_false"`) {
		t.Fatalf("availability reason lost on wire: %s, %v", body, err)
	}
	body, err = json.Marshal(valid[2])
	if err != nil || !strings.Contains(string(body), `"apple_error_source":"callback_without_nserror"`) {
		t.Fatalf("synthetic Apple error source lost on wire: %s, %v", body, err)
	}
}
