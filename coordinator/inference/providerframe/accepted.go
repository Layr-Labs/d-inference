package providerframe

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func (s *Service) Accepted(provider *registry.Provider, msg *protocol.InferenceAcceptedMessage) {
	if provider == nil {
		return
	}
	pr := provider.GetPending(msg.RequestID)
	if pr == nil {
		return
	}
	pr.Profile.Mark(registry.StampAccepted)
	// Non-blocking signal — the dispatch loop may have already committed.
	select {
	case pr.AcceptedCh <- struct{}{}:
	default:
	}
}
