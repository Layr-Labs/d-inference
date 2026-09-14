package api

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func queuedDispatchRequest(model string, rp *registry.RequestProfile, deadline time.Duration) dispatch.Request {
	return dispatch.Request{
		Model:                  model,
		PublicModel:            model,
		RawBody:                []byte(`{"model":"` + model + `","messages":[]}`),
		ConsumerEndpoint:       completionsEndpoint,
		Timing:                 &registry.RequestTiming{ReceivedAt: time.Now()},
		Deadline:               deadline,
		SpeculativeAt:          deadline / 2,
		RefundReservation:      func() {},
		RequestedMaxTokens:     16,
		EstimatedPromptTokens:  1,
		ParallelToolCalls:      true,
		RequestedStopSequences: []string{"stop"},
		Profile:                rp,
	}
}
