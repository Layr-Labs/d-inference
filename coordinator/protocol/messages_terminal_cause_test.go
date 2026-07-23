package protocol

import (
	"encoding/json"
	"strings"
	"testing"
)

// Typed error-terminal wire contract (deadline incident fix): the Swift
// provider attaches an optional terminal_cause (closed vocabulary) and an
// optional attempt_usage (engine-reconciled partial usage) to the existing
// inference_error message. These tests pin the exact JSON names and the
// legacy-compatibility behavior at the decode boundary.

// Both optional fields present, decoded through the ProviderMessage envelope —
// the production single-parse ingress path (type_scan fast path + concrete
// struct unmarshal).
func TestInferenceErrorTypedTerminalEnvelopeDecode(t *testing.T) {
	raw := `{
		"type": "inference_error",
		"request_id": "req-typed-1",
		"error": "request exceeded safety deadline",
		"status_code": 504,
		"error_reason": "provider_error",
		"terminal_cause": "safety_deadline",
		"attempt_usage": {
			"prompt_tokens": 123,
			"completion_tokens": 456,
			"reasoning_tokens": 7
		}
	}`

	var pm ProviderMessage
	if err := json.Unmarshal([]byte(raw), &pm); err != nil {
		t.Fatalf("envelope unmarshal: %v", err)
	}
	if pm.Type != TypeInferenceError {
		t.Fatalf("type = %q, want %q", pm.Type, TypeInferenceError)
	}
	msg, ok := pm.Payload.(*InferenceErrorMessage)
	if !ok {
		t.Fatalf("payload type = %T, want *InferenceErrorMessage", pm.Payload)
	}
	if msg.TerminalCause != "safety_deadline" {
		t.Errorf("terminal_cause = %q, want safety_deadline", msg.TerminalCause)
	}
	if msg.AttemptUsage == nil {
		t.Fatal("attempt_usage = nil, want decoded usage")
	}
	if msg.AttemptUsage.PromptTokens != 123 {
		t.Errorf("attempt_usage.prompt_tokens = %d, want 123", msg.AttemptUsage.PromptTokens)
	}
	if msg.AttemptUsage.CompletionTokens != 456 {
		t.Errorf("attempt_usage.completion_tokens = %d, want 456", msg.AttemptUsage.CompletionTokens)
	}
	if msg.AttemptUsage.ReasoningTokens != 7 {
		t.Errorf("attempt_usage.reasoning_tokens = %d, want 7", msg.AttemptUsage.ReasoningTokens)
	}
	// The legacy fields must be untouched by the additions.
	if msg.RequestID != "req-typed-1" || msg.StatusCode != 504 || msg.ErrorReason != "provider_error" {
		t.Errorf("legacy fields mismatch: %+v", msg)
	}
}

// A legacy provider frame (no new fields) decodes with zero values: empty
// cause, nil usage. This is the absent = legacy contract.
func TestInferenceErrorLegacyFrameDecode(t *testing.T) {
	raw := `{"type":"inference_error","request_id":"req-legacy","error":"boom","status_code":500}`

	var pm ProviderMessage
	if err := json.Unmarshal([]byte(raw), &pm); err != nil {
		t.Fatalf("envelope unmarshal: %v", err)
	}
	msg, ok := pm.Payload.(*InferenceErrorMessage)
	if !ok {
		t.Fatalf("payload type = %T, want *InferenceErrorMessage", pm.Payload)
	}
	if msg.TerminalCause != "" {
		t.Errorf("terminal_cause = %q, want empty (legacy)", msg.TerminalCause)
	}
	if msg.AttemptUsage != nil {
		t.Errorf("attempt_usage = %+v, want nil (legacy)", msg.AttemptUsage)
	}
}

// An unknown terminal_cause value decodes verbatim — the protocol layer never
// classifies; treating unknown-as-legacy (plus the drift metric) is the api
// layer's job (api/terminal_cause.go).
func TestInferenceErrorUnknownCauseDecodesVerbatim(t *testing.T) {
	raw := `{"type":"inference_error","request_id":"req-drift","error":"x","status_code":500,"terminal_cause":"lease_reaped"}`

	var pm ProviderMessage
	if err := json.Unmarshal([]byte(raw), &pm); err != nil {
		t.Fatalf("envelope unmarshal: %v", err)
	}
	msg, ok := pm.Payload.(*InferenceErrorMessage)
	if !ok {
		t.Fatalf("payload type = %T, want *InferenceErrorMessage", pm.Payload)
	}
	if msg.TerminalCause != "lease_reaped" {
		t.Errorf("terminal_cause = %q, want lease_reaped (verbatim)", msg.TerminalCause)
	}
	if msg.AttemptUsage != nil {
		t.Errorf("attempt_usage = %+v, want nil", msg.AttemptUsage)
	}
}

// Marshaling a message without the new fields must keep the legacy wire shape
// byte-compatible: omitempty must suppress both keys (mixed-fleet safety —
// old coordinators/providers never see phantom keys).
func TestInferenceErrorLegacyWireShapeUnchanged(t *testing.T) {
	msg := InferenceErrorMessage{
		Type:       TypeInferenceError,
		RequestID:  "req-wire",
		Error:      "boom",
		StatusCode: 500,
	}
	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if strings.Contains(string(data), "terminal_cause") {
		t.Errorf("unset terminal_cause leaked into wire JSON: %s", data)
	}
	if strings.Contains(string(data), "attempt_usage") {
		t.Errorf("unset attempt_usage leaked into wire JSON: %s", data)
	}
}

// Round-trip with both fields set: exact wire key names are load-bearing (the
// Swift provider mirrors them; renaming either silently reverts the fleet to
// legacy semantics).
func TestInferenceErrorTypedTerminalRoundTrip(t *testing.T) {
	msg := InferenceErrorMessage{
		Type:          TypeInferenceError,
		RequestID:     "req-rt",
		Error:         "deadline",
		StatusCode:    504,
		TerminalCause: "admission_timeout",
		AttemptUsage:  &UsageInfo{PromptTokens: 9, CompletionTokens: 3, ReasoningTokens: 1},
	}
	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	for _, key := range []string{`"terminal_cause":"admission_timeout"`, `"attempt_usage"`, `"prompt_tokens":9`, `"completion_tokens":3`, `"reasoning_tokens":1`} {
		if !strings.Contains(string(data), key) {
			t.Errorf("wire JSON missing %s: %s", key, data)
		}
	}
	var decoded InferenceErrorMessage
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if decoded.TerminalCause != msg.TerminalCause {
		t.Errorf("terminal_cause round-trip = %q, want %q", decoded.TerminalCause, msg.TerminalCause)
	}
	if decoded.AttemptUsage == nil || *decoded.AttemptUsage != *msg.AttemptUsage {
		t.Errorf("attempt_usage round-trip = %+v, want %+v", decoded.AttemptUsage, msg.AttemptUsage)
	}
}
