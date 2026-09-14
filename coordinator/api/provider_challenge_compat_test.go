package api

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/providercontrol/challenge"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"nhooyr.io/websocket"
)

// Keep the existing direct API fixtures on the actual verifier entry point.
// This adapter carries expected values only; nonce ownership stays in Session.
type pendingChallenge struct{ nonce, timestamp string }

func (s *Server) verifyChallengeResponse(id string, p *registry.Provider, expected *pendingChallenge, response *protocol.AttestationResponseMessage) {
	s.newProviderChallengeVerifier().VerifyResponse(id, p, challenge.Expected{Nonce: expected.nonce, Timestamp: expected.timestamp}, response)
}
func (s *Server) handleChallengeFailure(id, reason string) int {
	return s.newProviderChallengeVerifier().RecordFailure(id, reason)
}
func (s *Server) handleTransientChallengeFailure(conn *websocket.Conn, id, reason string) {
	s.newProviderChallengeVerifier().TransientFailure(conn, id, reason)
}
