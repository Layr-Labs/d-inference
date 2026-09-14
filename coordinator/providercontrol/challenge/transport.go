package challenge

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// generateNonce creates a random 32-byte nonce and returns it as base64.
func generateNonce() (string, error) {
	nonce := make([]byte, 32)
	if _, err := rand.Read(nonce); err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(nonce), nil
}

// sendChallenge sends an attestation challenge to a provider and waits for the response.
func (s *Session) sendChallenge(ctx context.Context, providerID string, provider *registry.Provider) {
	defer provider.SignalApplicationProofSettled()
	nonce, err := generateNonce()
	if err != nil {
		s.verifier.deps.Logger().Error("failed to generate challenge nonce", "provider_id", providerID, "error", err)
		return
	}

	timestamp := time.Now().UTC().Format(time.RFC3339)

	challenge := protocol.AttestationChallengeMessage{
		Type:      protocol.TypeAttestationChallenge,
		Nonce:     nonce,
		Timestamp: timestamp,
	}

	data, err := json.Marshal(challenge)
	if err != nil {
		s.verifier.deps.Logger().Error("failed to marshal challenge", "provider_id", providerID, "error", err)
		return
	}

	pc := &pendingChallenge{
		nonce:      nonce,
		timestamp:  timestamp,
		sentAt:     time.Now(),
		responseCh: make(chan *protocol.AttestationResponseMessage, 1),
	}
	s.tracker.add(nonce, pc)

	writeCtx, writeCancel := context.WithTimeout(ctx, 5*time.Second)
	defer writeCancel()
	// Control lane: a challenge must not queue behind multi-MiB inference
	// frames — a congested data lane would turn transport backpressure into
	// "attestation timeout" reputation events.
	if err := provider.WriteTextControl(writeCtx, data); err != nil {
		s.verifier.deps.Logger().Error("failed to send challenge", "provider_id", providerID, "error", err)
		s.tracker.remove(nonce)
		return
	}
	s.verifier.deps.Incr("attestation.challenges_sent", nil)

	s.verifier.deps.Logger().Debug("sent attestation challenge", "provider_id", providerID, "nonce", nonce[:8]+"...")

	// Wait for response with timeout.
	timeout := ResponseTimeout
	select {
	case <-ctx.Done():
		s.tracker.remove(nonce)
		return
	case resp := <-pc.responseCh:
		s.tracker.remove(nonce)
		if resp == nil {
			// Channel closed without response
			s.verifier.TransientFailure(provider.Conn, providerID, "no response")
			return
		}
		s.verifier.VerifyResponse(providerID, provider, Expected{Nonce: pc.nonce, Timestamp: pc.timestamp}, resp)
	case <-time.After(timeout):
		s.tracker.remove(nonce)
		s.verifier.TransientFailure(provider.Conn, providerID, "timeout")
	}
}

// Deliver processes an attestation response from a provider.
func (s *Session) Deliver(providerID string, provider *registry.Provider, msg *protocol.AttestationResponseMessage) {
	if provider == nil {
		s.verifier.deps.Logger().Warn("attestation response from unregistered provider", "provider_id", providerID)
		return
	}

	pc := s.tracker.remove(msg.Nonce)
	if pc == nil {
		// The nonce is provider-controlled until it matches coordinator state.
		// Omitting it also avoids a short-string slice panic on malformed frames.
		s.verifier.deps.Logger().Warn("attestation response for unknown challenge", "provider_id", providerID)
		return
	}

	// Send response to the waiting goroutine.
	select {
	case pc.responseCh <- msg:
	default:
	}
}
