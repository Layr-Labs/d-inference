package inference_test

import (
	"net/http"
	"testing"

	failure "github.com/eigeninference/d-inference/coordinator/internal/inference/failure"
	retry "github.com/eigeninference/d-inference/coordinator/internal/inference/retry"
)

func TestClassifyExhaustedStatus_ReclassifiesSyntheticTimeout(t *testing.T) {
	code, reason, reclassified := retry.ClassifyExhaustedStatus(http.StatusGatewayTimeout, "")
	if code != http.StatusTooManyRequests || reason != "first_chunk_timeout" || !reclassified {
		t.Fatalf("synthetic timeout = (%d, %q, %v), want (429, first_chunk_timeout, true)",
			code, reason, reclassified)
	}
}

func TestClassifyExhaustedStatus_PreservesTypedProviderTimeouts(t *testing.T) {
	for _, cause := range []string{failure.TerminalCauseSafetyDeadline, failure.TerminalCauseBackpressureTimeout} {
		code, reason, reclassified := retry.ClassifyExhaustedStatus(http.StatusGatewayTimeout, cause)
		if code != http.StatusGatewayTimeout || reason != "dispatch_exhausted" || reclassified {
			t.Fatalf("typed timeout %q = (%d, %q, %v), want (504, dispatch_exhausted, false)",
				cause, code, reason, reclassified)
		}
	}
}

func TestClassifyExhaustedStatus_PreservesNonTimeoutFailure(t *testing.T) {
	code, reason, reclassified := retry.ClassifyExhaustedStatus(http.StatusBadGateway, "")
	if code != http.StatusBadGateway || reason != "dispatch_exhausted" || reclassified {
		t.Fatalf("provider failure = (%d, %q, %v), want (502, dispatch_exhausted, false)",
			code, reason, reclassified)
	}
}
