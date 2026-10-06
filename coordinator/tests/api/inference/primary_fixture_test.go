package inference_test

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/inference"
	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
	providerdispatch "github.com/eigeninference/d-inference/coordinator/internal/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// queuePrimaryRequest builds inputs for the real primary dispatcher: with no
// routable provider, attempt 0 and an explicit prefer-owner request must queue.
func queuePrimaryRequest(model string, rp *registry.RequestProfile, r *http.Request, deadline time.Duration) inference.PrimaryRequest {
	return inference.PrimaryRequest{
		Dispatch: providerdispatch.Input{
			Request:               r,
			Scope:                 providerdispatch.Scope{PreferOwner: true, OwnerAccountID: testConsumerID},
			Model:                 model,
			PublicModel:           model,
			Body:                  []byte(`{"model":"` + model + `","messages":[]}`),
			Timing:                &registry.RequestTiming{ReceivedAt: time.Now()},
			Deadline:              deadline,
			Exclusions:            providerdispatch.NewExclusions(),
			RequestedMaxTokens:    16,
			EstimatedPromptTokens: 1,
			Traits:                registry.RequestTraits{ParallelToolCalls: true},
			Profile:               rp,
		},
		Metadata:      providerdispatch.PendingMetadata{Endpoint: inreq.CompletionsEndpoint, StopSequences: []string{"stop"}},
		Writer:        httptest.NewRecorder(),
		SpeculativeAt: deadline / 2,
		Refund:        func() {},
	}
}

// queuedPlaceholder returns the enqueued attempt rather than attempt 0's
// reserve-only profile, which has no available provider.
func queuedPlaceholder(t *testing.T, rp *registry.RequestProfile) *registry.AttemptProfile {
	t.Helper()
	for _, a := range rp.Attempts() {
		if a.Get(registry.StampQueued) != 0 {
			return a
		}
	}
	t.Fatalf("no queued placeholder attempt among %d attempts", len(rp.Attempts()))
	return nil
}
