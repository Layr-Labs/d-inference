package trust_test

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"nhooyr.io/websocket"
)

type challengeProofFixture struct {
	nonce     string
	timestamp string
}

func (s *trustFixture) verifyChallengeResponse(id string, provider *registry.Provider, proof *challengeProofFixture, response *protocol.AttestationResponseMessage) {
	s.VerifyResponse(id, provider, proof.nonce, proof.timestamp, response)
}

func (s *trustFixture) handleChallengeFailure(id, reason string) int {
	return s.HandleFailure(id, reason)
}

func (s *trustFixture) handleTransientChallengeFailure(conn *websocket.Conn, id, reason string) {
	s.HandleTransientFailure(conn, id, reason)
}

func (s *trustFixture) applyChallengeRuntimePolicy(provider *registry.Provider, response *protocol.AttestationResponseMessage) (bool, bool, []protocol.RuntimeMismatch) {
	return s.ApplyRuntimePolicy(provider, response)
}

func (s *trustFixture) applyChallengeMinVersionPolicy(provider *registry.Provider) (string, bool) {
	return s.ApplyMinVersionPolicy(provider)
}
