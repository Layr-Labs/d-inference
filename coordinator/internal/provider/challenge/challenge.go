package challenge

// Provider WebSocket management for the Darkbloom coordinator.
//
// This file handles the provider side of the coordinator: WebSocket connections,
// provider registration, attestation verification, challenge-response loops,
// and inference request/response relay.
//
// Provider lifecycle:
//   1. Provider connects via WebSocket to /ws/provider
//   2. Provider sends a Register message with hardware info, models, and attestation
//   3. Coordinator verifies attestation (Secure Enclave P-256 signature)
//   4. Coordinator starts periodic challenge-response loop to verify liveness
//   5. Coordinator routes inference requests to the provider via WebSocket
//   6. Provider streams response chunks back through the WebSocket
//   7. Coordinator relays chunks to the waiting consumer HTTP handler
//
// Attestation trust levels:
//   - none: No attestation provided (Open Mode, still accepted)
//   - self_signed: Attestation signed by provider's own Secure Enclave key
//   - hardware: MDA certificate chain verified against Apple Root CA (future)

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// pendingChallenge tracks an outstanding challenge sent to a provider.
type pendingChallenge struct {
	nonce      string
	timestamp  string
	sentAt     time.Time
	responseCh chan *protocol.AttestationResponseMessage
}

// ChallengeTracker manages pending challenges for provider connections.
type ChallengeTracker struct {
	mu      sync.Mutex
	pending map[string]*pendingChallenge // keyed by nonce
}

func NewChallengeTracker() *ChallengeTracker {
	return &ChallengeTracker{
		pending: make(map[string]*pendingChallenge),
	}
}

func (ct *ChallengeTracker) add(nonce string, pc *pendingChallenge) {
	ct.mu.Lock()
	defer ct.mu.Unlock()
	ct.pending[nonce] = pc
}

func (ct *ChallengeTracker) remove(nonce string) *pendingChallenge {
	ct.mu.Lock()
	defer ct.mu.Unlock()
	pc := ct.pending[nonce]
	delete(ct.pending, nonce)
	return pc
}

func (s *Engine) ChallengeLoop(ctx context.Context, providerID string, provider *registry.Provider, tracker *ChallengeTracker) {
	if s.challengeSettings.
		Skip {
		return
	}

	interval := s.challengeSettings.
		Interval

	if interval == 0 {
		interval = DefaultChallengeInterval
	}

	// Send initial challenge immediately so the provider is routable
	// without waiting for the first ticker interval.
	s.sendChallenge(ctx, providerID, provider, tracker)

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			// Stop only for a hard (non-recoverable) untrust. A transiently
			// untrusted provider (missed-challenge timeouts) keeps being
			// challenged so a later passing challenge can restore it.
			if provider.ChallengeShouldStop() {
				return
			}
			s.sendChallenge(ctx, providerID, provider, tracker)
		case <-provider.ImmediateChallengeChan():
			// Out-of-band kick (e.g. a release-policy refresh invalidated this
			// provider's application evidence): re-challenge now so a healthy
			// provider is re-verified and routable again well before the next
			// periodic tick.
			if provider.ChallengeShouldStop() {
				return
			}
			s.sendChallenge(ctx, providerID, provider, tracker)
		}
	}
}

// generateNonce creates a random 32-byte nonce and returns it as base64.
func generateNonce() (string, error) {
	nonce := make([]byte, 32)
	if _, err := rand.Read(nonce); err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(nonce), nil
}

// sendChallenge sends an attestation challenge to a provider and waits for the response.
func (s *Engine) sendChallenge(ctx context.Context, providerID string, provider *registry.Provider, tracker *ChallengeTracker) {
	defer provider.SignalApplicationProofSettled()
	nonce, err := generateNonce()
	if err != nil {
		s.logger.Error("failed to generate challenge nonce", "provider_id", providerID, "error", err)
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
		s.logger.Error("failed to marshal challenge", "provider_id", providerID, "error", err)
		return
	}

	pc := &pendingChallenge{
		nonce:      nonce,
		timestamp:  timestamp,
		sentAt:     time.Now(),
		responseCh: make(chan *protocol.AttestationResponseMessage, 1),
	}
	tracker.add(nonce, pc)

	writeCtx, writeCancel := context.WithTimeout(ctx, 5*time.Second)
	defer writeCancel()
	// Control lane: a challenge must not queue behind multi-MiB inference
	// frames — a congested data lane would turn transport backpressure into
	// "attestation timeout" reputation events.
	if err := provider.WriteTextControl(writeCtx, data); err != nil {
		s.logger.Error("failed to send challenge", "provider_id", providerID, "error", err)
		tracker.remove(nonce)
		return
	}
	s.observation.Incr("attestation.challenges_sent", nil)

	s.logger.Debug("sent attestation challenge", "provider_id", providerID, "nonce", nonce[:8]+"...")

	// Wait for response with timeout.
	timeout := ChallengeResponseTimeout
	select {
	case <-ctx.Done():
		tracker.remove(nonce)
		return
	case resp := <-pc.responseCh:
		tracker.remove(nonce)
		if resp == nil {
			// Channel closed without response
			s.HandleTransientFailure(provider.Conn, providerID, "no response")
			return
		}
		s.VerifyResponse(providerID, provider, pc.nonce, pc.timestamp, resp)
	case <-time.After(timeout):
		tracker.remove(nonce)
		s.HandleTransientFailure(provider.Conn, providerID, "timeout")
	}
}

// HandleAttestationResponse processes an attestation response from a provider.
func (s *Engine) HandleAttestationResponse(providerID string, provider *registry.Provider, msg *protocol.AttestationResponseMessage, tracker *ChallengeTracker) {
	if provider == nil {
		s.logger.Warn("attestation response from unregistered provider", "provider_id", providerID)
		return
	}

	pc := tracker.remove(msg.Nonce)
	if pc == nil {
		// The nonce is provider-controlled until it matches coordinator state.
		// Omitting it also avoids a short-string slice panic on malformed frames.
		s.logger.Warn("attestation response for unknown challenge", "provider_id", providerID)
		return
	}

	// Send response to the waiting goroutine.
	select {
	case pc.responseCh <- msg:
	default:
	}
}

// verifyChallengeResponse verifies a challenge response from a provider.
// In addition to verifying the nonce and signature, it checks the fresh
// SIP status reported by the provider. If SIP has been disabled since
// registration, the provider is marked untrusted immediately.
