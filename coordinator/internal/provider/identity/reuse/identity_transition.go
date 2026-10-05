package reuse

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// CodeAttestLoop drives the APNs code-identity challenge for one connection.
//
// Attestation is PER-CONNECTION: while a WebSocket is alive the provider's binary
// cannot change (a binary swap restarts the process and drops the connection), so
// one successful challenge proves the connection's code identity for its whole
// lifetime — there is NO periodic re-challenge. That also respects Apple's
// background-push budget (~2-3/hour/device); a 5-minute ticker (12/hour) would be
// throttled and dropped.
//
// The loop only PUSHES; it never blocks on the reply. The provider's
// code_attestation_response is verified in the read-loop delivery path
// (HandleCodeAttestationResponse), which flips CodeAttested. So:
//   - Reuse: if this device attested recently with the same binary version,
//     APNs token, and exact registration process key, it reuses with NO APNs push.
//   - Reconnect-safe (Fix 1): the pushed nonce is tracked per-device, so a reply
//     that lands on a DIFFERENT (re)connection still attests; this loop just polls
//     GetCodeAttested and exits. A push budget held over from the prior connection
//     means this loop simply waits for that reply instead of burning a new push.
//   - Bounded, jittered retry (Fix 3): if no reply lands within the budget cooldown
//     the loop re-pushes, maxAttempts times on the fast cadence and then at most
//     once per slowRetryInterval for as long as the connection stays alive and
//     unattested. The poll/backoff cadence (retryDelay) is decoupled from the
//     push budget; alert delivery uses a far shorter budget than background.
//
// Providers with no APNs device token (legacy <0.6.0, or headless boxes with no
// GUI session) can never attest, so the loop exits immediately — they are derouted
// once enforcement begins, the intended "everyone must update" outcome.
// tryCrossVersionReuse combines a genuine cached APNs proof (same SE identity,
// same exact APNs token — the process key MAY differ, since the provider mints
// a fresh ephemeral NodeKeyPair every process start) with CURRENT generation-
// bound application evidence (a fresh SE-signed challenge attesting this exact
// process key and approved binary) only to authorize a live encrypted resume
// challenge to the current process key. The cached proof must additionally
// have been EARNED by the same binary this process now runs, or by an APPROVED
// active predecessor of the current release (the exact approved-transition
// derivation) — a proof earned by a since-deactivated or unknown release falls
// through to a real APNs challenge under the durable floor (Codex 05:55Z P1).
// Decrypting that challenge is the sole possession proof for the new key; the
// persisted proof never grants code trust by itself. This is what lets a
// routine upgrade/restart re-attest over the live WebSocket instead of falling
// to a fresh APNs push behind the durable per-device floor while queued
// requests expire (Codex 05:33Z #1).
func (s *Transition,

) TryCrossVersionReuse(
	ctx context.Context,
	providerID string,
	provider *registry.Provider,
) bool {
	evidence, ok := provider.ApplicationEvidenceSnapshot()
	if !ok || evidence.BinaryHash == "" || evidence.ProcessPublicKey == "" ||
		evidence.APNsToken == "" || evidence.PolicyGeneration == 0 {
		return false
	}
	snapshot := s.releases.Policy()
	if snapshot == nil || !snapshot.Required ||
		snapshot.Generation != evidence.PolicyGeneration {
		return false
	}
	provider.Mu().Lock()
	nodeKey := provider.PublicKey
	provider.Mu().Unlock()
	if nodeKey == "" || evidence.ProcessPublicKey != nodeKey {
		return false
	}
	cachedBinaryHash, ok := s.codeAttestThrottle.ReuseAttestationForTransition(
		evidence.SEPublicKey, evidence.APNsToken)
	if !ok {
		return false
	}
	// Bind the proof to the binary that earned it: same binary as the current
	// approved identity, or an APPROVED active predecessor of the current
	// release. Legacy identity-less records already failed above.
	if cachedBinaryHash != evidence.BinaryHash &&
		!snapshot.ApprovedTransitionPredecessor(cachedBinaryHash,
			evidence.Platform, evidence.Backend, evidence.Version,
		) {
		return false
	}
	if !s.resume.SendCodeIdentityResumeChallenge(
		ctx, providerID, provider, nodeKey,
		evidence.SEPublicKey, evidence.APNsToken,
	) {
		return false
	}
	s.recordMetric("resume_sent_approved_release")
	s.logger.Info("code-attest: current approved release authorized a live process-key resume challenge")
	return true
}
