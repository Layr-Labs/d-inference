package dispatch

import (
	"net/http"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestLegacyBare429RemainsTransientAndHealthNeutral(t *testing.T) {
	safe, _, _ := attempt.SanitizeProviderInferenceError(&protocol.InferenceErrorMessage{
		StatusCode: http.StatusTooManyRequests,
	})

	dispatch := &execution{s: newTestController(t), model: "test-model"}
	dispatch.setLastInferenceError(nil, safe)
	if dispatch.shouldStopFailover() {
		t.Fatal("legacy bare 429 must remain transient below the bounded capacity retry limit")
	}
	if dispatch.capacityRetries != 1 || dispatch.terminalClientError {
		t.Fatalf("legacy bare 429 failover state = retries:%d terminalClientError:%v",
			dispatch.capacityRetries, dispatch.terminalClientError)
	}

	srv, reg, provider, pr := newBreakerExemptionHarness(t, "legacy-bare-429")
	dispatch = &execution{s: srv, model: pr.Model}
	for range breakerStrikeRounds {
		dispatch.noteProviderError(provider, pr,
			safe.StatusCode, safe.Error, safe.ErrorReason, safe.TerminalCause, nil)
	}
	assertBreakerStates(t, reg, provider, pr, false)
	if !reg.CapacityCooldownActive(provider.ID, pr.Model) {
		t.Fatal("repeated legacy queue-full sheds must feed only the capacity cooldown")
	}
}
