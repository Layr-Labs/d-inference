package api

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Existing API fixtures continue to exercise the real shared frame owner.
// Production Session callbacks bind its methods directly.
func (s *Server) handleChunk(id string, p *registry.Provider, msg *protocol.InferenceResponseChunkMessage) {
	s.inferenceFrames().Chunk(id, p, msg)
}

func (s *Server) handleInferenceAccepted(p *registry.Provider, msg *protocol.InferenceAcceptedMessage) {
	s.inferenceFrames().Accepted(p, msg)
}

func (s *Server) handleComplete(id string, p *registry.Provider, msg *protocol.InferenceCompleteMessage) {
	s.inferenceFrames().CompleteAt(id, p, msg, time.Now())
}

func (s *Server) handleCompleteAt(id string, p *registry.Provider, msg *protocol.InferenceCompleteMessage, receivedAt time.Time) {
	s.inferenceFrames().CompleteAt(id, p, msg, receivedAt)
}

func (s *Server) handleInferenceError(id string, p *registry.Provider, msg *protocol.InferenceErrorMessage) {
	s.inferenceFrames().Error(id, p, msg)
}
