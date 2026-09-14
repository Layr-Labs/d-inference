package codeidentity

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
)

// Rearm re-arms an APNs code-identity challenge when a provider's
// HEARTBEAT carries a device token the coordinator has not yet acted on: a headless/late-token Mac that only obtained its APNs token AFTER
// registration, or a token that ROTATED mid-connection. The original token
// arrives only in RegisterMessage, so without a heartbeat re-arm such providers
// would never be challenged again short of a full reconnect.
//
// SECURITY — the heartbeat token NEVER grants attestation. It only updates the
// push target so the coordinator can SEND a challenge; CodeAttested is still set
// exclusively by HandleResponse after the full E_K(nonce)
// round-trip is verified against the SE key bound at REGISTRATION. Two cases:
//   - First token on a previously token-less provider: record the token and arm
//     the normal loop. A genuine, same-version recent attestation may still be
//     reused — that is a real prior proof for this Secure-Enclave identity, not
//     the token. But application evidence EARNED while token-less carries an
//     empty APNsToken, and the routing gate binds evidence.APNsToken to the
//     provider's current token — so installing the first token strands any such
//     evidence (unroutable until the 5-minute ticker re-proves it). The
//     empty→non-empty transition is therefore a rotation for the EVIDENCE
//     lifecycle only: clear the stale evidence and kick the ordinary challenge
//     loop (no reuse invalidation, no code-flag reset, no extra APNs push —
//     evidence regenerates over the live WebSocket).
//   - CHANGED token: a material change to the device's identity-binding inputs.
//     Reset CodeAttested (fail-closed — deroute until re-proven) AND force a real
//     challenge with NO reuse bypass (invalidateReuse), so the new token cannot
//     ride a proof earned under the old one. Because the rotation also clears
//     application evidence, the connection's ORDINARY attestation challenge loop
//     is kicked immediately (RequestImmediateChallenge) so the evidence half
//     regenerates well inside the 120s request-queue window instead of waiting
//     out the 5-minute periodic ticker.
//
// A token-less heartbeat is ignored (it never clears an existing token), and an
// unchanged token is a no-op, so the steady state adds no churn or pushes.
func (s *Manager) Rearm(ctx context.Context, providerID string, provider *registry.Provider, hb *protocol.HeartbeatMessage) {
	if s.attestor == nil || provider == nil || hb == nil {
		return
	}
	newTok := hb.APNsDeviceToken
	if newTok == "" {
		return // no token in this heartbeat — nothing to re-arm; never clears one
	}

	provider.Mu().Lock()
	oldTok := provider.APNsDeviceToken
	if oldTok == newTok {
		// Steady state: keep the environment in sync but do not re-challenge.
		if hb.APNsEnvironment != "" {
			provider.APNsEnvironment = hb.APNsEnvironment
		}
		provider.Mu().Unlock()
		return
	}
	changed := oldTok != ""
	provider.APNsDeviceToken = newTok
	if hb.APNsEnvironment != "" {
		provider.APNsEnvironment = hb.APNsEnvironment
	}
	var seKey string
	if provider.AttestationResult != nil {
		seKey = provider.AttestationResult.PublicKey
	}
	// True whenever installing newTok leaves held application evidence bound to
	// a different (possibly empty) token: a genuine rotation always does; a
	// first token does iff evidence was earned token-less.
	evidenceStale := changed ||
		(provider.ApplicationEvidence.EvidenceGeneration != 0 &&
			provider.ApplicationEvidence.APNsToken != newTok)
	if changed {
		// Token rotation invalidates the application/process half and both code
		// flags, but never the independent device evidence.
		provider.ApplicationEvidence = registry.ApplicationEvidence{}
		provider.CodeAttested = false
		provider.FreshCodeAttested = false
		provider.RuntimeCapabilities = nil
	} else if evidenceStale {
		// First token, token-less evidence: clear only the evidence half —
		// code-attest state and the reuse cache are untouched (the prior proof
		// is real; the token never granted it).
		provider.ApplicationEvidence = registry.ApplicationEvidence{}
		provider.RuntimeCapabilities = nil
	}
	provider.Mu().Unlock()
	if evidenceStale {
		_ = s.deps.Registry.ReconcileAttestedRuntimeCapabilities(providerID)
		// The cleared application evidence is regenerated only by the ordinary
		// challenge loop; without a kick the provider stays unroutable until the
		// next periodic tick even after the code-attest half re-proves.
		provider.RequestImmediateChallenge()
	}

	var loopGeneration uint64
	if changed {
		// No bypass: drop the cached reuse record and outstanding proof state.
		// Rotate loop ownership and clear the old token's budget under the same
		// per-device reservation lock, so an old loop cannot consume the freshly
		// reset budget before the new-token loop owns it.
		s.state.invalidateReuse(seKey)
		s.state.clearChallenge(seKey)
		s.state.clearResumeChallenges(providerID)
		loopGeneration = s.state.rotateLoopAndClearPushBudget(ctx, seKey)
		s.invalidatePersistedCodeAttestation(seKey)
		s.deps.Metric("rearm_token_changed")
		s.deps.Logger.Info("code-attest: APNs device token changed; forcing re-challenge")
	} else {
		loopGeneration = s.state.beginLoop(seKey)
		s.deps.Metric("rearm_token_arrived")
		s.deps.Logger.Info("code-attest: APNs device token arrived; arming challenge")
	}
	if loopGeneration == 0 {
		return
	}

	saferun.Go(s.deps.Logger, "codeAttestRearm", func() {
		s.codeAttestLoopForGeneration(
			ctx, providerID, provider, true, loopGeneration,
		)
	})
}
