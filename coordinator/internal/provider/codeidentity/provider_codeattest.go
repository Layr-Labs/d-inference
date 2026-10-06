package codeidentity

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/releases"
	"github.com/eigeninference/d-inference/coordinator/attestation"
	codeidentity "github.com/eigeninference/d-inference/coordinator/internal/provider/identity"
	identityevidence "github.com/eigeninference/d-inference/coordinator/internal/provider/identity/evidence"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
)

// APNs code-identity attestation (v0.6.0). The coordinator pushes an encrypted
// nonce to a provider's device via APNs; the provider replies with a Secure
// Enclave signature over it, proving the running binary's code identity. This
// file owns the per-connection challenge loop, the same-/cross-version and
// reconnect reuse fast-paths, the heartbeat-driven re-arm (late/rotated token),
// the push, and the fail-closed verification chokepoint. CodeAttested comes only
// from a live verified APNs round trip or a still-fresh APNs proof composed with
// current generation-bound application evidence.

func (s *Controller,

) CodeAttestLoop(
	ctx context.Context, providerID string, provider *registry.Provider,
) {
	s.codeAttestLoopForGeneration(ctx, providerID, provider, true, 0)
}

func (s *Controller,

) codeAttestLoopWithResume(
	ctx context.Context,
	providerID string,
	provider *registry.Provider,
	allowResume bool,
) {
	s.codeAttestLoopForGeneration(
		ctx, providerID, provider, allowResume, 0,
	)
}

func (s *Controller,

) codeAttestLoopForGeneration(
	ctx context.Context,
	providerID string,
	provider *registry.Provider,
	allowResume bool,
	loopGeneration uint64,
) {
	if !s.CodeAttestorConfigured() || provider == nil {
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
		loopGeneration = s.codeAttestThrottle.BeginLoop(seKey)
	} else if !s.codeAttestThrottle.LoopCurrent(seKey, loopGeneration) {
		return
	}
	if loopGeneration == 0 {
		return
	}
	defer s.codeAttestThrottle.EndLoop(seKey, loopGeneration)
	// Finalize only this loop's accepted pushes, leaving a replacement loop alone.
	// Nonces remain valid for late verified replies. Diagnostics never revoke trust.
	defer s.RecordUnansweredCodeAttestPushes(providerID, seKey, loopGeneration)

	// Wait for the initial fresh process/posture challenge before deciding
	// whether a genuine prior APNs proof can be composed with its release fact.
	// Application evidence alone is never an early-return condition.
	if settled := provider.ApplicationProofSettledChan(); settled != nil {
		select {
		case <-ctx.Done():
			return
		case <-settled:
		}
		if !s.codeAttestThrottle.LoopCurrent(seKey, loopGeneration) {
			return
		}
		if allowResume &&
			s.TryCrossVersionReuse(ctx, providerID, provider) {
			return
		}
	}

	provider.Mu().Lock()
	apnsToken := provider.APNsDeviceToken
	version := provider.Version
	nodeKey := provider.PublicKey
	provider.Mu().Unlock()
	if apnsToken == "" {
		s.CodeAttestMetric("no_token")
		s.logger.Info("code-attest: provider has no APNs device token; cannot attest")
		return
	}
	requiresProcessProof := provider.RequiresFreshRuntimeCodeProof()

	// Cached same-version evidence authorizes only a live encrypted nonce
	// challenge to this exact process key. CodeAttested is set only after the
	// process decrypts that challenge and the SE key signs its nonce.
	if basis := s.codeAttestThrottle.ReuseAttestationBasis(seKey, version, apnsToken, nodeKey); allowResume && basis != "" {
		if s.SendCodeIdentityResumeChallenge(
			ctx, providerID, provider, nodeKey, seKey, apnsToken,
		) {
			s.CodeAttestMetric("resume_sent")
			s.observation.Incr("code_attest.resume_proof_sent", []string{"basis:" + basis})
			return
		}
		if ctx.Err() != nil {
			return
		}
	}

	// Cross-version reuse likewise requires a live encrypted process-key proof.
	if allowResume &&
		s.TryCrossVersionReuse(ctx, providerID, provider) {
		return
	}

	// Alert delivery is not background-throttled, so it may retry on a far shorter
	// push budget than background (Fix 3). Detected via the attestor seam.
	alertMode := s.AlertMode()

	schedule := codeidentity.NewCodeAttestPushSchedule(s.codeAttestThrottle)
	prevSent := false // the last push was accepted by APNs but not yet answered
	for {
		if !s.codeAttestThrottle.LoopCurrent(seKey, loopGeneration) {
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
			s.TryCrossVersionReuse(ctx, providerID, provider) {
			return
		}

		// Push when the per-device budget permits. A budget cooldown elapsing
		// without attestation means a delivered push's reply never came (timeout);
		// a budget held over from a prior connection means we simply wait (poll)
		// for that reply rather than burning another push (reconnect-safe).
		// After maxAttempts fast pushes the loop does not give up while the
		// connection lives: it retries at most once per slowRetryInterval.
		if schedule.EnterSlowIfExhausted() {
			s.CodeAttestMetric("max_attempts")
			s.logger.Warn("code-attest: fast attempts exhausted; continuing on the slow retry cadence",
				"slow_retry_interval", s.codeAttestThrottle.SlowRetryInterval)
		}
		if schedule.Due(s.codeAttestThrottle.Now()) {
			releaseReservation, reserved := s.codeAttestThrottle.ReservePush(
				ctx, seKey, apnsToken, alertMode, loopGeneration,
			)
			if reserved {
				if prevSent {
					s.CodeAttestMetric("timeout")
					s.logger.Warn("code-attest: no valid reply within the push budget; retrying",
						"attempt", schedule.Pushes)
				}
				// Per device, not prevSent: a push accepted before the provider
				// reconnected is counted by this replacement loop.
				s.RecordUnansweredCodeAttestPushes(providerID, seKey)
				if schedule.Slow {
					s.CodeAttestMetric("slow_retry")
					s.logger.Info("code-attest: slow retry push",
						"attempt", schedule.Pushes+1)
				}
				schedule.RecordPush(s.codeAttestThrottle.Now())
				prevSent = func() bool {
					defer releaseReservation()
					return s.SendCodeIdentityChallengeForReservation(
						ctx, provider,
						seKey, apnsToken, nodeKey, loopGeneration,
					)
				}()
			} else if budget := s.codeAttestThrottle.BudgetStatus(seKey, apnsToken); budget.Present {
				s.logger.Debug("code-attest: push reservation deferred", "last_push_at", budget.LastPushAt, "next_push_at", budget.NextPushAt)
			}
		}

		// Poll for the delivery path's verdict on a jittered cadence decoupled from
		// the push budget; bail if the connection ends first.
		select {
		case <-ctx.Done():
			return
		case <-time.After(s.codeAttestThrottle.RetryDelay()):
		}
	}
}

// MaybeRearmCodeAttest re-arms an APNs code-identity challenge when a provider's
// HEARTBEAT carries a device token the coordinator has not yet acted on (W5 Fix
// 2, 2a): a headless/late-token Mac that only obtained its APNs token AFTER
// registration, or a token that ROTATED mid-connection. The original token
// arrives only in RegisterMessage, so without a heartbeat re-arm such providers
// would never be challenged again short of a full reconnect.
//
// SECURITY — the heartbeat token NEVER grants attestation. It only updates the
// push target so the coordinator can SEND a challenge; CodeAttested is still set
// exclusively by HandleCodeAttestationResponse after the full E_K(nonce)
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
//     out the 5-minute periodic ticker (Codex 05:33Z #2).
//
// A token-less heartbeat is ignored (it never clears an existing token), and an
// unchanged token is a no-op, so the steady state adds no churn or pushes.
func (s *Controller,

) MaybeRearmCodeAttest(ctx context.Context, providerID string, provider *registry.Provider, hb *protocol.HeartbeatMessage) {
	if !s.CodeAttestorConfigured() || provider == nil || hb == nil {
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
		_ = s.registry.ReconcileAttestedRuntimeCapabilities(providerID)
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
		s.codeAttestThrottle.InvalidateReuse(seKey)
		s.codeAttestThrottle.ClearChallenge(seKey)
		s.codeAttestThrottle.ClearResumeChallenges(providerID)
		loopGeneration = s.codeAttestThrottle.RotateLoopAndClearPushBudget(ctx, seKey)
		s.invalidatePersistedCodeAttestation(seKey)
		s.CodeAttestMetric("rearm_token_changed")
		s.logger.Info("code-attest: APNs device token changed; forcing re-challenge")
	} else {
		loopGeneration = s.codeAttestThrottle.BeginLoop(seKey)
		s.CodeAttestMetric("rearm_token_arrived")
		s.logger.Info("code-attest: APNs device token arrived; arming challenge")
	}
	if loopGeneration == 0 {
		return
	}

	saferun.Go(s.logger, "codeAttestRearm", func() {
		s.codeAttestLoopForGeneration(
			ctx, providerID, provider, true, loopGeneration,
		)
	})
}

// HandleCodeAttestationResponse verifies a provider's code_attestation_response in
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
func (s *Controller,

) HandleCodeAttestationResponse(providerID string, provider *registry.Provider, resp *protocol.CodeAttestationResponseMessage) {
	if provider == nil {
		s.logger.Warn("code-attest response from unregistered provider")
		return
	}
	if resp == nil {
		return
	}
	alreadyAttested := provider.GetCodeAttested() &&
		(!provider.RequiresFreshRuntimeCodeProof() || provider.GetFreshCodeAttested())

	provider.Mu().Lock()
	var sePubKey, attestedBinaryHash string
	if provider.AttestationResult != nil {
		sePubKey = provider.AttestationResult.PublicKey
		// Prefer the binary identity measured during registration. Production
		// registrations may omit it; after releasing Provider.mu below, current
		// application evidence may supply the same SE- and process-bound identity.
		// If neither source is usable, the proof remains identity-less and cannot
		// authorize a release transition.
		attestedBinaryHash, _ = releases.NormalizeSHA256Hex(
			provider.AttestationResult.BinaryHash, "attested binary_hash")
	}
	version := provider.Version
	apnsToken := provider.APNsDeviceToken
	nodeKey := provider.PublicKey
	provider.Mu().Unlock()
	attestedBinaryHash = identityevidence.BinaryHash(
		provider, sePubKey, attestedBinaryHash)

	if sePubKey == "" {
		s.CodeAttestMetric("verify_failed")
		s.logger.Warn("code-attest response missing registration-bound SE key")
		return
	}

	resumeProof := resp.Nonce != "" &&
		s.codeAttestThrottle.MatchResumeChallenge(
			resp.Nonce, providerID, nodeKey, sePubKey, apnsToken)
	apnsProof := !resumeProof && resp.Nonce != "" &&
		s.codeAttestThrottle.MatchChallengeForIdentity(
			sePubKey, resp.Nonce, apnsToken, nodeKey)
	// Once authorized, only an outstanding APNs nonce has diagnostic work left.
	// Preserve the previous no-op for resume proofs and unrelated/replayed frames.
	if alreadyAttested && !apnsProof {
		return
	}
	if !resumeProof && !apnsProof {
		s.CodeAttestMetric("nonce_mismatch")
		s.logger.Warn("code-attest response nonce mismatch or expired proof")
		return
	}
	// Verify Sign_SE(nonce) against the SE public key bound to THIS connection at
	// registration — never a key supplied in the response.
	if err := attestation.VerifyChallengeSignature(sePubKey, resp.Signature, resp.Nonce); err != nil {
		s.CodeAttestMetric("verify_failed")
		s.logger.Warn("code-attest signature verification failed", "error", err)
		return
	}
	if resumeProof {
		if !s.codeAttestThrottle.ConsumeResumeChallenge(
			resp.Nonce, providerID, nodeKey, sePubKey, apnsToken,
		) {
			return // timeout/disconnect/racing response consumed it first
		}
	} else {
		if !s.codeAttestThrottle.ConsumeChallengeForIdentity(
			sePubKey, resp.Nonce, apnsToken, nodeKey,
		) {
			return
		}
		s.RecordCodeAttestPushReply(providerID, "answered")
	}

	// Counted a late APNs reply; never re-grant or refresh reuse.
	if alreadyAttested {
		return
	}

	if !provider.GrantProcessCodeAttested(apnsToken, nodeKey) {
		s.CodeAttestMetric("identity_rotated")
		return
	}
	if apnsProof {
		s.codeAttestThrottle.RecordAttestedForProcess(
			sePubKey, version, apnsToken, nodeKey, attestedBinaryHash)
		// Persist the SE+token+process-key+binary binding. Reuse still requires
		// a live encrypted nonce PoP before protected capabilities are restored.
		provider.Mu().Lock()
		accountID := provider.AccountID
		provider.Mu().Unlock()
		s.persistCodeAttestation(
			accountID, sePubKey, version, apnsToken, nodeKey, attestedBinaryHash)
		// The APNs challenge was atomically consumed after signature verification.
	}
	s.CodeAttestMetric("attested")
	proofKind := "resume"
	if apnsProof {
		proofKind = "apns"
	}
	s.observation.Incr("code_attest.proof_verified", []string{"kind:" + proofKind})
	s.logger.Info("provider code identity verified", "proof_kind", proofKind)
	// Newly eligible for private routing — drain requests that queued waiting for an
	// attested provider instead of waiting for the next heartbeat tick. Off the read
	// loop so verification stays responsive.
	saferun.Go(s.logger, "codeAttestDrain", func() {
		s.registry.DrainQueuedRequestsForProviderWithReason(provider, registry.DrainTriggerChallenge)
	})
}
