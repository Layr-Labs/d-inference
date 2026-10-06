package inference

import (
	"net/http"

	providerdispatch "github.com/eigeninference/d-inference/coordinator/internal/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/retry"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// WithBodyOverflow replaces stale provider-fault evidence with the failure of
// this concrete preparation, without excluding compatible protocol-0 peers.
func (h PrimaryHistory) WithBodyOverflow(text string, bytes int) PrimaryHistory {
	h.Overflow = ProviderBodyOverflow{Message: text, Bytes: bytes}
	h.Failure, h.DeadlineFailure = retry.CoordinatorFailure(text, http.StatusRequestEntityTooLarge), false
	return h
}

func (h PrimaryHistory) ProviderBodyRejected(body []byte, provider *registry.Provider, text string, exclusions providerdispatch.Exclusions) PrimaryHistory {
	if provider == nil {
		return h
	}
	exclusions.Exclude(provider.ID)
	bytes, _ := providerBodySizeError(body, provider)
	return h.WithBodyOverflow(text, bytes)
}

// RejectBodyOverflow is used only after compatible candidates are exhausted.
func (h PrimaryHistory) RejectBodyOverflow(text string) PrimaryHistory {
	h = h.WithBodyOverflow(text, h.Overflow.Bytes)
	h.Terminal.ClientStatus = http.StatusRequestEntityTooLarge
	h.Terminal.ClientReason, h.Terminal.ClientMessage = "payload_too_large", text
	return h
}

func (h PrimaryHistory) QueueCompatible(decision registry.RoutingDecision) bool {
	return h.Overflow.Message != "" && h.Failure.Message.StatusCode == http.StatusRequestEntityTooLarge && decision.CapacityRejections > 0
}
