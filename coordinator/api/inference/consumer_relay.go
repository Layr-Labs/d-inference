package inference

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/relay"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// NewRelay binds output delivery to this request owner's lifecycle operations.
// Settlement authority never leaves the owner when a relay is constructed.
func (s *Owner) NewRelay() *relay.Controller {
	return &relay.Controller{
		Observation: s.observation,
		Refund:      s.refundReservedBalance, Success: s.noteInferenceSuccess,
		Error: s.noteInferenceError, Outcome: s.updateInferenceRouteOutcomeForPending,
		ProviderError: s.writeGenericProviderError,
	}
}

func (s *Owner) handleStreamingResponseWithFirstChunkAndError(w http.ResponseWriter, r *http.Request, pr *registry.PendingRequest, firstChunks []string, initialError *protocol.InferenceErrorMessage) {
	s.NewRelay().Stream(w, r, pr, firstChunks, initialError)
}

func (s *Owner) handleNonStreamingResponseWithFirstChunkAndError(w http.ResponseWriter, r *http.Request, pr *registry.PendingRequest, firstChunks []string, initialError *protocol.InferenceErrorMessage) {
	s.NewRelay().NonStream(w, r, pr, firstChunks, initialError)
}
