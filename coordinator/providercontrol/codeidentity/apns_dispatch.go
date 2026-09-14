package codeidentity

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// sendCodeIdentityChallenge pushes one APNs code-identity challenge (v0.6.0) and
// returns WITHOUT waiting for the reply. It generates a fresh nonce,
// records it per-device (keyed by the registration-bound SE key) so the read-loop
// delivery path can match the provider's code_attestation_response — even one that
// arrives on a later (reconnected) WebSocket — then pushes E_K(nonce) to the
// device. The nonce is a base64 string encrypted to the provider's X25519 key K
// via the same E2E path used for inference bodies; the eventual proof is the SE
// P-256 signature over that nonce (K is decrypt-only — there is no Sign_K).
// Fail-closed: a failed push clears the outstanding challenge so a stale reply for
// it can never attest. Returns true iff the push was accepted by APNs (so the loop
// can tell a delivered-but-unanswered push apart from a send failure). See
// docs/design/apns-code-attestation.md.
func (s *Manager) sendCodeIdentityChallenge(
	ctx context.Context,
	_ string,
	provider *registry.Provider,
) bool {
	if provider == nil {
		return false
	}
	provider.Mu().Lock()
	token := provider.APNsDeviceToken
	pubKey := provider.PublicKey
	var seKey string
	if provider.AttestationResult != nil {
		seKey = provider.AttestationResult.PublicKey
	}
	provider.Mu().Unlock()
	generation := s.state.beginLoop(seKey)
	if generation == 0 {
		return false
	}
	defer s.state.endLoop(seKey, generation)
	s.state.mu.Lock()
	s.state.loopTokens[seKey] = codeAttestTokenHash(token)
	s.state.mu.Unlock()
	return s.sendCodeIdentityChallengeForReservation(
		ctx, provider, seKey, token, pubKey, generation,
	)
}

func (s *Manager) sendCodeIdentityChallengeForReservation(
	ctx context.Context,
	provider *registry.Provider,
	sePubKey, deviceToken, pubKey string,
	loopGeneration uint64,
) bool {
	if s.attestor == nil || provider == nil {
		return false
	}
	provider.Mu().Lock()
	currentToken := provider.APNsDeviceToken
	env := provider.APNsEnvironment
	currentPubKey := provider.PublicKey
	var currentSEPubKey string
	if provider.AttestationResult != nil {
		currentSEPubKey = provider.AttestationResult.PublicKey
	}
	provider.Mu().Unlock()

	if deviceToken == "" || pubKey == "" || sePubKey == "" ||
		currentToken != deviceToken ||
		currentPubKey != pubKey ||
		currentSEPubKey != sePubKey ||
		!s.state.loopCurrentForToken(
			sePubKey, deviceToken, loopGeneration,
		) {
		s.deps.Logger.Warn("code-attest skipped: reserved push identity changed")
		return false
	}

	nonceBytes := make([]byte, 32)
	if _, err := rand.Read(nonceBytes); err != nil {
		s.deps.Logger.Error("code-attest nonce generation failed", "error", err)
		return false
	}
	nonceB64 := base64.StdEncoding.EncodeToString(nonceBytes)

	// Record the token + process key used for E_K(nonce). A reply landing on a
	// later connection is accepted only when both identities still match.
	s.state.recordChallengeForIdentity(
		sePubKey, nonceB64, deviceToken, pubKey)

	sendCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	err := s.attestor.SendCodeChallenge(sendCtx, deviceToken, env, pubKey, nonceB64)
	cancel()
	if err != nil {
		// The push never went out — drop the outstanding challenge so no stale
		// reply for this nonce can attest.
		s.state.clearChallengeIf(sePubKey, nonceB64)
		s.deps.Metric("push_send_failed")
		s.deps.Logger.Warn("code-attest push send failed", "error", err)
		return false
	}
	s.deps.Metric("push_sent")
	// No blocking wait: the reply is verified in HandleResponse on
	// whichever live connection it lands.
	return true
}
