package protocol

import (
	"encoding/json"
	"testing"
)

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
