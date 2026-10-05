package inference_test

import (
	"strings"
	"testing"

	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
	providerwire "github.com/eigeninference/d-inference/coordinator/internal/inference/providerwire"
)

func TestBodyAtLimitWithoutLegacyCacheIsolationRemainsAccepted(t *testing.T) {
	const prefix = `{"payload":"`
	const suffix = `"}`
	rawBody := []byte(prefix +
		strings.Repeat("x", inreq.MaxInferenceBodyBytes-len(prefix)-len(suffix)) +
		suffix)

	sealed, err := providerwire.BodyForCacheAttempt(rawBody, "")
	if err != nil {
		t.Fatalf("bodyForCacheAttempt: %v", err)
	}
	if len(sealed) != inreq.MaxInferenceBodyBytes {
		t.Fatalf("sealed body = %d bytes, want %d", len(sealed), inreq.MaxInferenceBodyBytes)
	}
}
