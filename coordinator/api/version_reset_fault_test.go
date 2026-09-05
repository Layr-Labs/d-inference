package api

import (
	"fmt"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestProviderEncryption502SurvivesVersionReset(t *testing.T) {
	srv, reg, provider, pr := newBreakerExemptionHarness(t, "genuine-502")
	provider.SetVersion("0.9.0")
	for i := range breakerStrikeRounds {
		deliverTypedError(t, srv, provider, pr.Model, fmt.Sprintf("encryption-%d", i), protocol.InferenceErrorMessage{
			FailureCode: protocol.FailureCodeEncryptionFailure, StatusCode: 502,
		})
	}
	assertBreakerStates(t, reg, provider, pr, true)
	provider.SetVersion("0.9.1")
	assertBreakerStates(t, reg, provider, pr, true)
	// A genuine fault delivered late after an actual disconnect also must not
	// be discarded by the early API-side superseded-flush optimization.
	reg.Disconnect(provider.ID)
	provider2 := makeRoutableProvider(t, reg, "new-encryption-session", pr.Model)
	provider2.Mu().Lock()
	provider2.AccountID = "acct-genuine-502"
	provider2.Mu().Unlock()
	provider2.RebindStableFaultKey()
	provider2.SetVersion("0.9.1")
	reg.RecordInferenceSuccess(provider2.ID, pr.Model, "base")
	reg.RecordProviderOutcome(provider2.ID, true, 200, "")
	reg.RecordProviderSessionServeOutcome(provider2.ID, true, 200, "")
	for range breakerStrikeRounds {
		srv.noteInferenceError(provider.ID, &registry.PendingRequest{Model: pr.Model}, 502, "encryption failure", "", "")
	}
	assertBreakerStates(t, reg, provider2, pr, true)
}
