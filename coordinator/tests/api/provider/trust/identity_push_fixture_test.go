package trust_test

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// sendCodeIdentityChallenge pushes one APNs code-identity challenge (v0.6.0) and
// returns WITHOUT waiting for the reply (Fix 1). It generates a fresh nonce,
// records it per-device (keyed by the registration-bound SE key) so the read-loop
// delivery path can match the provider's code_attestation_response — even one that
// arrives on a later (reconnected) WebSocket — then pushes E_K(nonce) to the
// device. The nonce is a base64 string encrypted to the provider's X25519 key K
// via the same E2E path used for inference bodies; the eventual proof is the SE
// P-256 signature over that nonce (K is decrypt-only — there is no Sign_K).
// Fail-closed: a failed push clears the outstanding challenge so a stale reply for
// it can never attest. Returns true iff the push was accepted by APNs (so the loop
// can tell a delivered-but-unanswered push apart from a send failure). See
// docs/apns-code-attestation-design.md.
func (s *trustFixture) sendCodeIdentityChallenge(
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
	generation := s.codeAttestThrottle.BeginLoop(seKey)
	if generation == 0 {
		return false
	}
	defer s.codeAttestThrottle.EndLoop(seKey, generation)
	release, reserved := s.codeAttestThrottle.ReservePush(ctx, seKey, token, s.AlertMode(), generation)
	if !reserved {
		return false
	}
	defer release()
	return s.SendCodeIdentityChallengeForReservation(
		ctx, provider, seKey, token, pubKey, generation,
	)
}
