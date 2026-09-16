package codeidentity

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/apns"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Loop drives the APNs code-identity challenge for one connection.
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
// (HandleResponse), which flips CodeAttested. So:
//   - Reuse: if this device attested recently with the same binary version,
//     APNs token, and exact registration process key, it reuses with NO APNs push.
//   - Reconnect-safe: the pushed nonce is tracked per-device, so a reply
//     that lands on a DIFFERENT (re)connection still attests; this loop just polls
//     GetCodeAttested and exits. A push budget held over from the prior connection
//     means this loop simply waits for that reply instead of burning a new push.
//   - Bounded, jittered retry: if no reply lands within the budget cooldown
//     the loop re-pushes, capped at maxAttempts. The poll/backoff cadence
//     (retryDelay) is decoupled from the push budget; alert delivery uses a far
//     shorter budget than background.
//
// Providers with no APNs device token (legacy <0.6.0, or headless boxes with no
// GUI session) can never attest, so the loop exits immediately — they are derouted
// once enforcement begins, the intended "everyone must update" outcome.
func (s *Manager) Loop(
	ctx context.Context, providerID string, provider *registry.Provider,
) {
	s.codeAttestLoopForGeneration(ctx, providerID, provider, true, 0)
}

func (s *Manager) codeAttestLoopWithResume(
	ctx context.Context,
	providerID string,
	provider *registry.Provider,
	allowResume bool,
) {
	s.codeAttestLoopForGeneration(
		ctx, providerID, provider, allowResume, 0,
	)
}

func (s *Manager) codeAttestLoopForGeneration(
	ctx context.Context,
	providerID string,
	provider *registry.Provider,
	allowResume bool,
	loopGeneration uint64,
) {
	if s.attestor == nil || provider == nil {
		return
	}
	provider.Mu().Lock()
	var seKey string
	if provider.AttestationResult != nil {
		seKey = provider.AttestationResult.PublicKey
	}
	provider.Mu().Unlock()
	if seKey == "" {
		return
	}
	if loopGeneration == 0 {
		loopGeneration = s.state.beginLoop(seKey)
	} else if !s.state.loopCurrent(seKey, loopGeneration) {
		return
	}
	if loopGeneration == 0 {
		return
	}
	defer s.state.endLoop(seKey, loopGeneration)

	// Wait for the initial fresh process/posture challenge before deciding
	// whether a genuine prior APNs proof can be composed with its release fact.
	// Application evidence alone is never an early-return condition.
	if settled := provider.ApplicationProofSettledChan(); settled != nil {
		select {
		case <-ctx.Done():
			return
		case <-settled:
		}
		if !s.state.loopCurrent(seKey, loopGeneration) {
			return
		}
		if allowResume &&
			s.TryResumeApproved(ctx, providerID, provider) {
			return
		}
	}

	provider.Mu().Lock()
	apnsToken := provider.APNsDeviceToken
	version := provider.Version
	nodeKey := provider.PublicKey
	provider.Mu().Unlock()
	if apnsToken == "" {
		s.deps.Metric("no_token")
		s.deps.Logger.Info("code-attest: provider has no APNs device token; cannot attest")
		return
	}
	requiresProcessProof := provider.RequiresFreshRuntimeCodeProof()

	// Cached same-version evidence authorizes only a live encrypted nonce
	// challenge to this exact process key. CodeAttested is set only after the
	// process decrypts that challenge and the SE key signs its nonce.
	if basis := s.state.reuseAttestationBasis(seKey, version, apnsToken, nodeKey); allowResume && basis != "" {
		if s.sendCodeIdentityResumeChallenge(
			ctx, providerID, provider, nodeKey, seKey, apnsToken,
		) {
			s.deps.Metric("resume_sent")
			s.deps.Incr("code_attest.resume_proof_sent", []string{"basis:" + basis})
			return
		}
		if ctx.Err() != nil {
			return
		}
	}

	// Cross-version reuse likewise requires a live encrypted process-key proof.
	if allowResume &&
		s.TryResumeApproved(ctx, providerID, provider) {
		return
	}

	// Alert delivery is not background-throttled, so it may retry on a far shorter
	// push budget than background. Detected via the attestor seam.
	alertMode := false
	if m, ok := s.attestor.(interface{ Mode() apns.Mode }); ok {
		alertMode = m.Mode() == apns.ModeAlert
	}

	pushes := 0
	prevSent := false // the last push was accepted by APNs but not yet answered
	for {
		if !s.state.loopCurrent(seKey, loopGeneration) {
			return
		}
		if provider.GetCodeAttested() &&
			(!requiresProcessProof || provider.GetFreshCodeAttested()) {
			return // delivery path completed the proof required by this provider
		}
		if provider.ChallengeShouldStop() {
			return // hard (non-recoverable) untrust — stop challenging
		}

		// Re-check each iteration: current application evidence and a cached APNs
		// proof may settle concurrently, but they only authorize a live resume.
		if allowResume &&
			s.TryResumeApproved(ctx, providerID, provider) {
			return
		}

		// Push when the per-device budget permits. A budget cooldown elapsing
		// without attestation means a delivered push's reply never came (timeout);
		// a budget held over from a prior connection means we simply wait (poll)
		// for that reply rather than burning another push (reconnect-safe).
		if pushes >= s.state.maxAttempts {
			s.deps.Metric("max_attempts")
			s.deps.Logger.Warn("code-attest: max attempts reached; waiting for a later reconnect")
			return
		}
		releaseReservation, reserved := s.state.reservePush(
			ctx, seKey, apnsToken, alertMode, loopGeneration,
		)
		if reserved {
			if prevSent {
				s.deps.Metric("timeout")
				s.deps.Logger.Warn("code-attest: no valid reply within the push budget; retrying",
					"attempt", pushes)
			}
			prevSent = func() bool {
				defer releaseReservation()
				return s.sendCodeIdentityChallengeForReservation(
					ctx, provider,
					seKey, apnsToken, nodeKey, loopGeneration,
				)
			}()
			pushes++
		}

		// Poll for the delivery path's verdict on a jittered cadence decoupled from
		// the push budget; bail if the connection ends first.
		select {
		case <-ctx.Done():
			return
		case <-time.After(s.state.retryDelay()):
		}
	}
}
