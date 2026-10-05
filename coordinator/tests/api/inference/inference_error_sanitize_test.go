package inference_test

import (
	"net/http"
	"testing"

	failure "github.com/eigeninference/d-inference/coordinator/internal/inference/failure"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestQueueFull429RemainsTransientAndHealthNeutral(t *testing.T) {
	safe, _, _ := failure.SanitizeProviderError(&protocol.InferenceErrorMessage{
		FailureCode: protocol.FailureCodeCapacity,
		ErrorReason: failure.ErrorReasonQueueFull,
		StatusCode:  http.StatusTooManyRequests,
	})

	dispatch := newAttemptFailureCase(t, "test-model", 0)
	dispatch.providerError(nil, safe)
	if dispatch.stopFailover() {
		t.Fatal("queue-full 429 must remain transient below the bounded capacity retry limit")
	}
	if dispatch.decision.CapacityRetries != 1 || dispatch.decision.ClientStatusCode != 0 {
		t.Fatalf("queue-full 429 failover state = retries:%d terminalClientError:%v",
			dispatch.decision.CapacityRetries, dispatch.decision.ClientStatusCode != 0)
	}

	srv, reg, provider, pr := newBreakerExemptionHarness(t, "queue-full-429")
	effects := srv.NewAttemptEffects()
	for range breakerStrikeRounds {
		effects.ProviderError(provider, pr,
			safe.StatusCode, safe.Error, safe.ErrorReason, safe.TerminalCause, nil)
	}
	assertBreakerStates(t, reg, provider, pr, false)
	if !reg.CapacityCooldownActive(provider.ID, pr.Model) {
		t.Fatal("repeated queue-full sheds must feed only the capacity cooldown")
	}
}
