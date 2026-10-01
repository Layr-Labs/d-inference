package api

import "github.com/eigeninference/d-inference/coordinator/registry"

// These are wire-payload limits, not token estimates. JSON envelopes, reasoning,
// tool arguments and usage all consume bytes; empty frames still consume slots.
const (
	defaultNonStreamingResponseMaxBytes  = 64 << 20
	defaultNonStreamingResponseMaxChunks = 262144
	nonStreamingResponseLimitError       = "provider response exceeds non-streaming response limit"
)

func (s *Server) newNonStreamingResponseBudget(stream bool) *registry.ResponseBudget {
	if stream {
		return nil
	}
	bytes, chunks := s.nonStreamingResponseMaxBytes, s.nonStreamingResponseMaxChunks
	if bytes <= 0 {
		bytes = defaultNonStreamingResponseMaxBytes
	}
	if chunks <= 0 {
		chunks = defaultNonStreamingResponseMaxChunks
	}
	return registry.NewResponseBudget(bytes, chunks)
}
