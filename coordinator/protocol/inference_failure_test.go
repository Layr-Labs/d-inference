package protocol

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestInferenceFailureCodeClosedVocabulary(t *testing.T) {
	valid := []InferenceFailureCode{
		FailureCodeInvalidRequest,
		FailureCodeInvalidMedia,
		FailureCodeMediaTooLarge,
		FailureCodeUnsupportedMedia,
		FailureCodeTemplateRender,
		FailureCodeModelUnavailable,
		FailureCodeCapacity,
		FailureCodeCancelled,
		FailureCodeEncryptionFailure,
		FailureCodeGenerationFailure,
		FailureCodeInternalFailure,
	}
	for _, code := range valid {
		if !code.Valid() {
			t.Errorf("code %q must be valid", code)
		}
	}
	for _, code := range []InferenceFailureCode{"", "Generation_Failure", "raw secret", "generation_failure\nsecret"} {
		if code.Valid() {
			t.Errorf("off-vocabulary code %q must be invalid", code)
		}
	}
}

func TestInferenceFailureCodeWireAndCoordinatorCauseIsolation(t *testing.T) {
	msg := InferenceErrorMessage{
		Type:             TypeInferenceError,
		RequestID:        "req-1",
		Error:            "inference generation failed",
		StatusCode:       500,
		FailureCode:      FailureCodeGenerationFailure,
		CoordinatorCause: CoordinatorCauseProviderDisconnected,
	}
	b, err := json.Marshal(msg)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), `"failure_code":"generation_failure"`) {
		t.Fatalf("failure_code missing from wire JSON: %s", b)
	}
	if strings.Contains(string(b), "provider_disconnected") || strings.Contains(string(b), "coordinator") {
		t.Fatalf("coordinator-only cause leaked onto wire: %s", b)
	}

	var decoded InferenceErrorMessage
	if err := json.Unmarshal([]byte(`{"type":"inference_error","request_id":"req-2","error":"x","status_code":500,"failure_code":"internal_failure","CoordinatorCause":"provider_disconnected"}`), &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.FailureCode != FailureCodeInternalFailure {
		t.Fatalf("failure_code = %q", decoded.FailureCode)
	}
	if decoded.CoordinatorCause != "" {
		t.Fatalf("provider JSON set coordinator-only cause: %q", decoded.CoordinatorCause)
	}
}
