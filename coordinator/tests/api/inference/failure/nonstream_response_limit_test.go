package failure_test

import (
	"encoding/json"
	"testing"

	failure "github.com/eigeninference/d-inference/coordinator/internal/inference/failure"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestNonStreamingResponseLimitCauseCannotBeForged(t *testing.T) {
	var msg protocol.InferenceErrorMessage
	if err := json.Unmarshal([]byte(`{"failure_code":"generation_failure","CoordinatorCause":"response_limit","coordinator_cause":"response_limit","status_code":502}`), &msg); err != nil {
		t.Fatal(err)
	}
	if msg.CoordinatorCause != "" {
		t.Fatal("provider set coordinator-only cause")
	}
	got := failure.NormalizeInternalError(msg)
	if got.StatusCode != 500 {
		t.Fatalf("forged status escaped normalization: %+v", got)
	}
}
