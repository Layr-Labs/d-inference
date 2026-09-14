package codeidentity

import (
	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
)

// handleCodeAttestationResponse verifies a provider's code_attestation_response in
// the WebSocket read-loop delivery path and marks the connection CodeAttested on
// success (Fix 1). This is the SINGLE fail-closed code-identity chokepoint moved
// off the blocking push goroutine: it attests whatever live connection the reply
// lands on, so a late reply or a reply after a mid-flight reconnect still attests
// (within the pushed nonce's validity window), while every security check is
// byte-for-byte the prior logic:
//   - the reply's nonce must equal the nonce the coordinator pushed to THIS device
//     (looked up by the registration-bound SE key; proves the provider decrypted
//     E_K(nonce) ⟹ holds K), AND
//   - Sign_SE(nonce) must verify against the SE public key bound to THIS connection
//     at registration — never a key supplied in the response.
//
// Any failure leaves CodeAttested false (fail-closed). Runs in the read loop, so
// the (potentially slower) queue drain is dispatched to a goroutine.
func (s *Manager) HandleResponse(providerID string, provider *registry.Provider, resp *protocol.CodeAttestationResponseMessage) {
	if provider == nil {
		s.deps.Logger.Warn("code-attest response from unregistered provider")
		return
	}
	if resp == nil {
		return
	}
	if provider.GetCodeAttested() &&
		(!provider.RequiresFreshRuntimeCodeProof() ||
			provider.GetFreshCodeAttested()) {
		return // already holds every proof required by this connection
	}

	provider.Mu().Lock()
	var sePubKey, attestedBinaryHash string
	if provider.AttestationResult != nil {
		sePubKey = provider.AttestationResult.PublicKey
		// Prefer the binary identity measured during registration. Production
		// registrations may omit it; after releasing Provider.mu below, current
		// application evidence may supply the same SE- and process-bound identity.
		// If neither source is usable, the proof remains identity-less and cannot
		// authorize a release transition.
		attestedBinaryHash, _ = s.deps.NormalizeHash(
			provider.AttestationResult.BinaryHash, "attested binary_hash")
	}
	version := provider.Version
	apnsToken := provider.APNsDeviceToken
	nodeKey := provider.PublicKey
	provider.Mu().Unlock()
	attestedBinaryHash = s.deps.ApplicationBinaryHash(
		provider, sePubKey, attestedBinaryHash)

	if sePubKey == "" {
		s.deps.Metric("verify_failed")
		s.deps.Logger.Warn("code-attest response missing registration-bound SE key")
		return
	}

	resumeProof := resp.Nonce != "" &&
		s.state.matchResumeChallenge(
			resp.Nonce, providerID, nodeKey, sePubKey, apnsToken)
	apnsProof := !resumeProof && resp.Nonce != "" &&
		s.state.matchChallengeForIdentity(
			sePubKey, resp.Nonce, apnsToken, nodeKey)
	if !resumeProof && !apnsProof {
		s.deps.Metric("nonce_mismatch")
		s.deps.Logger.Warn("code-attest response nonce mismatch or expired proof")
		return
	}
	// Verify Sign_SE(nonce) against the SE public key bound to THIS connection at
	// registration — never a key supplied in the response.
	if err := attestation.VerifyChallengeSignature(sePubKey, resp.Signature, resp.Nonce); err != nil {
		s.deps.Metric("verify_failed")
		s.deps.Logger.Warn("code-attest signature verification failed", "error", err)
		return
	}
	if resumeProof {
		if !s.state.consumeResumeChallenge(
			resp.Nonce, providerID, nodeKey, sePubKey, apnsToken,
		) {
			return // timeout/disconnect/racing response consumed it first
		}
	} else if !s.state.consumeChallengeForIdentity(
		sePubKey, resp.Nonce, apnsToken, nodeKey,
	) {
		return
	}

	if !provider.GrantProcessCodeAttested(apnsToken, nodeKey) {
		s.deps.Metric("identity_rotated")
		return
	}
	if apnsProof {
		s.state.recordAttestedForProcess(
			sePubKey, version, apnsToken, nodeKey, attestedBinaryHash)
		// Persist the SE+token+process-key+binary binding. Reuse still requires
		// a live encrypted nonce PoP before protected capabilities are restored.
		s.persistCodeAttestation(
			sePubKey, version, apnsToken, nodeKey, attestedBinaryHash)
		// The APNs challenge was atomically consumed after signature verification.
	}
	s.deps.Metric("attested")
	proofKind := "resume"
	if apnsProof {
		proofKind = "apns"
	}
	s.deps.Incr("code_attest.proof_verified", []string{"kind:" + proofKind})
	s.deps.Logger.Info("provider code identity verified", "proof_kind", proofKind)
	// Newly eligible for private routing — drain requests that queued waiting for an
	// attested provider instead of waiting for the next heartbeat tick. Off the read
	// loop so verification stays responsive.
	saferun.Go(s.deps.Logger, "codeAttestDrain", func() {
		s.deps.Registry.DrainQueuedRequestsForProviderWithReason(provider, registry.DrainTriggerChallenge)
	})
}
