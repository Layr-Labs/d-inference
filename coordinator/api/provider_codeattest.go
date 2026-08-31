package api

// APNs code-identity attestation (v0.6.0). The coordinator pushes an encrypted
// nonce to a provider's device via APNs; the provider replies with a Secure
// Enclave signature over it, proving the running binary's code identity. This
// file owns the per-connection challenge loop, the same-/cross-version and
// reconnect reuse fast-paths, the heartbeat-driven re-arm (late/rotated token),
// the push, and the fail-closed verification chokepoint. CodeAttested comes only
// from a live verified APNs round trip or a still-fresh APNs proof composed with
// current generation-bound application evidence.

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"time"

	"github.com/eigeninference/d-inference/coordinator/apns"
	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
)

// codeAttestMetric records a code-identity attestation outcome to both Datadog
// (s.ddIncr) and the in-process registry exposed at /v1/admin/metrics, so the
// APNs code-attest funnel (push_sent → attested vs timeout/verify_failed/no_token)
// is measurable per cohort. Outcomes: no_token, reused, push_sent,
// push_send_failed, attested, nonce_mismatch, verify_failed, timeout,
// max_attempts, rearm_token_arrived, rearm_token_changed (W5 Fix 2 heartbeat
// re-arm). Metadata only — no provider identifiers in the metric.
func (s *Server) codeAttestMetric(outcome string) {
	s.ddIncr("code_attest", []string{"outcome:" + outcome})
	s.metrics.IncCounter("code_attest_total", MetricLabel{"outcome", outcome})
}

// codeAttestLoop drives the APNs code-identity challenge for one connection.
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
// (handleCodeAttestationResponse), which flips CodeAttested. So:
//   - Reuse: if this device attested recently with the same binary version,
//     APNs token, and exact registration process key, it reuses with NO APNs push.
//   - Reconnect-safe (Fix 1): the pushed nonce is tracked per-device, so a reply
//     that lands on a DIFFERENT (re)connection still attests; this loop just polls
//     GetCodeAttested and exits. A push budget held over from the prior connection
//     means this loop simply waits for that reply instead of burning a new push.
//   - Bounded, jittered retry (Fix 3): if no reply lands within the budget cooldown
//     the loop re-pushes, capped at maxAttempts. The poll/backoff cadence
//     (retryDelay) is decoupled from the push budget; alert delivery uses a far
//     shorter budget than background.
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
func (s *Server) tryCrossVersionReuse(
	ctx context.Context,
	providerID string,
	provider *registry.Provider,
) bool {
	evidence, ok := provider.ApplicationEvidenceSnapshot()
	if !ok || evidence.BinaryHash == "" || evidence.ProcessPublicKey == "" ||
		evidence.APNsToken == "" || evidence.PolicyGeneration == 0 {
		return false
	}
	snapshot := s.releaseTrustPolicy.Load()
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
	cachedBinaryHash, ok := s.codeAttestThrottle.reuseAttestationForTransition(
		evidence.SEPublicKey, evidence.APNsToken)
	if !ok {
		return false
	}
	// Bind the proof to the binary that earned it: same binary as the current
	// approved identity, or an APPROVED active predecessor of the current
	// release. Legacy identity-less records already failed above.
	if cachedBinaryHash != evidence.BinaryHash &&
		!approvedTransitionPredecessor(
			snapshot, cachedBinaryHash,
			evidence.Platform, evidence.Backend, evidence.Version,
		) {
		return false
	}
	if !s.sendCodeIdentityResumeChallenge(
		ctx, providerID, provider, nodeKey,
		evidence.SEPublicKey, evidence.APNsToken,
	) {
		return false
	}
	s.codeAttestMetric("resume_sent_approved_release")
	s.logger.Info("code-attest: current approved release authorized a live process-key resume challenge")
	return true
}

// approvedTransitionPredecessor reports whether fromHash names an ACTIVE
// release row that the current release identity (platform/backend/version) may
// transition from. This is the single approved-transition derivation — the
// same per-candidate rule deriveApprovedReleaseTransition applies when
// building ApprovedFromBinaryHashes: same platform, backend-compatible (a
// legacy empty row backend matches any), and non-downgrade (the current
// version is not below the predecessor's). A hash absent from the ACTIVE
// inventory — e.g. a deactivated release — is never an approved predecessor.
func approvedTransitionPredecessor(
	snapshot *releaseTrustPolicySnapshot,
	fromHash, platform, backend, version string,
) bool {
	if snapshot == nil || fromHash == "" || platform == "" {
		return false
	}
	for _, candidate := range snapshot.ByBinaryHash[fromHash] {
		if candidate.Platform == platform &&
			(candidate.Backend == backend || candidate.Backend == "") &&
			!semverLess(version, candidate.Version) {
			return true
		}
	}
	return false
}

func (s *Server) codeAttestLoop(
	ctx context.Context, providerID string, provider *registry.Provider,
) {
	s.codeAttestLoopForGeneration(ctx, providerID, provider, true, 0)
}

func (s *Server) codeAttestLoopWithResume(
	ctx context.Context,
	providerID string,
	provider *registry.Provider,
	allowResume bool,
) {
	s.codeAttestLoopForGeneration(
		ctx, providerID, provider, allowResume, 0,
	)
}

func (s *Server) codeAttestLoopForGeneration(
	ctx context.Context,
	providerID string,
	provider *registry.Provider,
	allowResume bool,
	loopGeneration uint64,
) {
	if s.codeAttestor == nil || provider == nil {
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
		loopGeneration = s.codeAttestThrottle.beginLoop(seKey)
	} else if !s.codeAttestThrottle.loopCurrent(seKey, loopGeneration) {
		return
	}
	if loopGeneration == 0 {
		return
	}
	defer s.codeAttestThrottle.endLoop(seKey, loopGeneration)

	// Wait for the initial fresh process/posture challenge before deciding
	// whether a genuine prior APNs proof can be composed with its release fact.
	// Application evidence alone is never an early-return condition.
	if settled := provider.ApplicationProofSettledChan(); settled != nil {
		select {
		case <-ctx.Done():
			return
		case <-settled:
		}
		if !s.codeAttestThrottle.loopCurrent(seKey, loopGeneration) {
			return
		}
		if allowResume &&
			s.tryCrossVersionReuse(ctx, providerID, provider) {
			return
		}
	}

	provider.Mu().Lock()
	apnsToken := provider.APNsDeviceToken
	version := provider.Version
	nodeKey := provider.PublicKey
	provider.Mu().Unlock()
	if apnsToken == "" {
		s.codeAttestMetric("no_token")
		s.logger.Info("code-attest: provider has no APNs device token; cannot attest")
		return
	}
	requiresProcessProof := provider.RequiresFreshRuntimeCodeProof()

	// Cached same-version evidence authorizes only a live encrypted nonce
	// challenge to this exact process key. CodeAttested is set only after the
	// process decrypts that challenge and the SE key signs its nonce.
	if allowResume && s.codeAttestThrottle.reuseAttestation(
		seKey, version, apnsToken, nodeKey,
	) {
		if s.sendCodeIdentityResumeChallenge(
			ctx, providerID, provider, nodeKey, seKey, apnsToken,
		) {
			s.codeAttestMetric("resume_sent")
			return
		}
		if ctx.Err() != nil {
			return
		}
	}

	// Cross-version reuse likewise requires a live encrypted process-key proof.
	if allowResume &&
		s.tryCrossVersionReuse(ctx, providerID, provider) {
		return
	}

	// Alert delivery is not background-throttled, so it may retry on a far shorter
	// push budget than background (Fix 3). Detected via the attestor seam.
	alertMode := false
	if m, ok := s.codeAttestor.(interface{ Mode() apns.Mode }); ok {
		alertMode = m.Mode() == apns.ModeAlert
	}

	pushes := 0
	prevSent := false // the last push was accepted by APNs but not yet answered
	for {
		if !s.codeAttestThrottle.loopCurrent(seKey, loopGeneration) {
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
			s.tryCrossVersionReuse(ctx, providerID, provider) {
			return
		}

		// Push when the per-device budget permits. A budget cooldown elapsing
		// without attestation means a delivered push's reply never came (timeout);
		// a budget held over from a prior connection means we simply wait (poll)
		// for that reply rather than burning another push (reconnect-safe).
		if pushes >= s.codeAttestThrottle.maxAttempts {
			s.codeAttestMetric("max_attempts")
			s.logger.Warn("code-attest: max attempts reached; waiting for a later reconnect")
			return
		}
		releaseReservation, reserved := s.codeAttestThrottle.reservePush(
			ctx, seKey, apnsToken, alertMode, loopGeneration,
		)
		if reserved {
			if prevSent {
				s.codeAttestMetric("timeout")
				s.logger.Warn("code-attest: no valid reply within the push budget; retrying",
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
		case <-time.After(s.codeAttestThrottle.retryDelay()):
		}
	}
}

// maybeRearmCodeAttest re-arms an APNs code-identity challenge when a provider's
// HEARTBEAT carries a device token the coordinator has not yet acted on (W5 Fix
// 2, 2a): a headless/late-token Mac that only obtained its APNs token AFTER
// registration, or a token that ROTATED mid-connection. The original token
// arrives only in RegisterMessage, so without a heartbeat re-arm such providers
// would never be challenged again short of a full reconnect.
//
// SECURITY — the heartbeat token NEVER grants attestation. It only updates the
// push target so the coordinator can SEND a challenge; CodeAttested is still set
// exclusively by handleCodeAttestationResponse after the full E_K(nonce)
// round-trip is verified against the SE key bound at REGISTRATION. Two cases:
//   - First token on a previously token-less provider: record the token and arm
//     the normal loop. A genuine, same-version recent attestation may still be
//     reused — that is a real prior proof for this Secure-Enclave identity, not
//     the token.
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
func (s *Server) maybeRearmCodeAttest(ctx context.Context, providerID string, provider *registry.Provider, hb *protocol.HeartbeatMessage) {
	if s.codeAttestor == nil || provider == nil || hb == nil {
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
	if changed {
		// Token rotation invalidates the application/process half and both code
		// flags, but never the independent device evidence.
		provider.ApplicationEvidence = registry.ApplicationEvidence{}
		provider.CodeAttested = false
		provider.FreshCodeAttested = false
		provider.RuntimeCapabilities = nil
	}
	provider.Mu().Unlock()
	if changed {
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
		s.codeAttestThrottle.invalidateReuse(seKey)
		s.codeAttestThrottle.clearChallenge(seKey)
		s.codeAttestThrottle.clearResumeChallenges(providerID)
		loopGeneration = s.codeAttestThrottle.rotateLoopAndClearPushBudget(ctx, seKey)
		s.invalidatePersistedCodeAttestation(seKey)
		s.codeAttestMetric("rearm_token_changed")
		s.logger.Info("code-attest: APNs device token changed; forcing re-challenge")
	} else {
		loopGeneration = s.codeAttestThrottle.beginLoop(seKey)
		s.codeAttestMetric("rearm_token_arrived")
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

// sendCodeIdentityResumeChallenge performs a one-time private-key possession
// check over the live WebSocket. Cached SE+token+K equality only authorizes
// sending this challenge; it never grants capabilities by itself.
func (s *Server) sendCodeIdentityResumeChallenge(
	ctx context.Context,
	providerID string,
	provider *registry.Provider,
	nodeKeyB64, seKey, token string,
) bool {
	if s.codeResumeBeforeIdentityCheck != nil {
		s.codeResumeBeforeIdentityCheck()
	}
	provider.Mu().Lock()
	identityCurrent := provider.PublicKey == nodeKeyB64 &&
		provider.APNsDeviceToken == token
	provider.Mu().Unlock()
	if !identityCurrent {
		return false
	}
	rawKey, err := base64.StdEncoding.DecodeString(nodeKeyB64)
	if err != nil || len(rawKey) != 32 {
		return false
	}
	var nodeKey [32]byte
	copy(nodeKey[:], rawKey)
	session, err := e2e.GenerateSessionKeys()
	if err != nil {
		return false
	}
	nonceBytes := make([]byte, 32)
	if _, err := rand.Read(nonceBytes); err != nil {
		return false
	}
	tokenHash := sha256.Sum256([]byte(token))
	nonce := base64.StdEncoding.EncodeToString(nonceBytes) + "." +
		base64.RawURLEncoding.EncodeToString(tokenHash[:])
	encrypted, err := e2e.Encrypt([]byte(nonce), nodeKey, session)
	if err != nil {
		return false
	}
	message := protocol.CodeAttestationResumeChallenge{
		Type: protocol.TypeCodeAttestationResumeChallenge,
		CodeChallenge: protocol.EncryptedPayload{
			EphemeralPublicKey: encrypted.EphemeralPublicKey,
			Ciphertext:         encrypted.Ciphertext,
		},
	}
	data, err := json.Marshal(message)
	if err != nil {
		return false
	}
	resumeDone := s.codeAttestThrottle.recordResumeChallenge(
		nonce, providerID, nodeKeyB64, seKey, token)
	if s.codeResumeSender != nil {
		if err := s.codeResumeSender(providerID, message); err != nil {
			s.codeAttestThrottle.consumeResumeChallenge(
				nonce, providerID, nodeKeyB64, seKey, token)
			return false
		}
		s.armCodeIdentityResumeFallback(
			ctx, providerID, provider, nonce, nodeKeyB64, seKey, token, resumeDone)
		return true
	}
	sendCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if err := provider.WriteText(sendCtx, data); err != nil {
		s.codeAttestThrottle.consumeResumeChallenge(
			nonce, providerID, nodeKeyB64, seKey, token)
		return false
	}
	s.armCodeIdentityResumeFallback(
		ctx, providerID, provider, nonce, nodeKeyB64, seKey, token, resumeDone)
	return true
}

func (s *Server) armCodeIdentityResumeFallback(
	ctx context.Context,
	providerID string,
	provider *registry.Provider,
	nonce, nodeKey, seKey, token string,
	done <-chan struct{},
) {
	expiresAt, ok := s.codeAttestThrottle.resumeChallengeExpiry(
		nonce, providerID, nodeKey, seKey, token,
	)
	if !ok {
		return
	}
	saferun.Go(s.logger, "codeAttestResumeFallback", func() {
		delay := time.Until(expiresAt)
		if delay < 0 {
			delay = 0
		}
		timer := time.NewTimer(delay)
		defer timer.Stop()
		select {
		case <-ctx.Done():
			return
		case <-done:
			return
		case <-timer.C:
		}
		if !s.codeAttestThrottle.expireResumeChallenge(
			nonce, providerID, nodeKey, seKey, token,
		) {
			return // response, disconnect cleanup, or another timer won
		}
		if s.codeResumeFallbackBeforeAPNs != nil {
			s.codeResumeFallbackBeforeAPNs()
		}
		if ctx.Err() != nil {
			return // connection canceled after timer won; do not spend APNs budget
		}
		s.codeAttestMetric("resume_timeout")
		s.codeAttestLoopWithResume(ctx, providerID, provider, false)
	})
}

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
func (s *Server) sendCodeIdentityChallenge(
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
	generation := s.codeAttestThrottle.beginLoop(seKey)
	if generation == 0 {
		return false
	}
	defer s.codeAttestThrottle.endLoop(seKey, generation)
	s.codeAttestThrottle.mu.Lock()
	s.codeAttestThrottle.loopTokens[seKey] = codeAttestTokenHash(token)
	s.codeAttestThrottle.mu.Unlock()
	return s.sendCodeIdentityChallengeForReservation(
		ctx, provider, seKey, token, pubKey, generation,
	)
}

func (s *Server) sendCodeIdentityChallengeForReservation(
	ctx context.Context,
	provider *registry.Provider,
	sePubKey, deviceToken, pubKey string,
	loopGeneration uint64,
) bool {
	if s.codeAttestor == nil || provider == nil {
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
		!s.codeAttestThrottle.loopCurrentForToken(
			sePubKey, deviceToken, loopGeneration,
		) {
		s.logger.Warn("code-attest skipped: reserved push identity changed")
		return false
	}

	nonceBytes := make([]byte, 32)
	if _, err := rand.Read(nonceBytes); err != nil {
		s.logger.Error("code-attest nonce generation failed", "error", err)
		return false
	}
	nonceB64 := base64.StdEncoding.EncodeToString(nonceBytes)

	// Record the token + process key used for E_K(nonce). A reply landing on a
	// later connection is accepted only when both identities still match.
	s.codeAttestThrottle.recordChallengeForIdentity(
		sePubKey, nonceB64, deviceToken, pubKey)

	sendCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	err := s.codeAttestor.SendCodeChallenge(sendCtx, deviceToken, env, pubKey, nonceB64)
	cancel()
	if err != nil {
		// The push never went out — drop the outstanding challenge so no stale
		// reply for this nonce can attest.
		s.codeAttestThrottle.clearChallengeIf(sePubKey, nonceB64)
		s.codeAttestMetric("push_send_failed")
		s.logger.Warn("code-attest push send failed", "error", err)
		return false
	}
	s.codeAttestMetric("push_sent")
	// No blocking wait: the reply is verified in handleCodeAttestationResponse on
	// whichever live connection it lands.
	return true
}

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
func (s *Server) handleCodeAttestationResponse(providerID string, provider *registry.Provider, resp *protocol.CodeAttestationResponseMessage) {
	if provider == nil {
		s.logger.Warn("code-attest response from unregistered provider")
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
		// The SE-signed application challenge measured this binary; retain it
		// on the cached APNs proof so a later release-transition resume is
		// bound to the binary that EARNED the proof (Codex 05:55Z P1). A
		// missing/unparseable hash leaves it empty — an identity-less record
		// that never authorizes a transition (fail-closed).
		attestedBinaryHash, _ = normalizeSHA256Hex(
			provider.AttestationResult.BinaryHash, "attested binary_hash")
	}
	version := provider.Version
	apnsToken := provider.APNsDeviceToken
	nodeKey := provider.PublicKey
	provider.Mu().Unlock()

	if sePubKey == "" {
		s.codeAttestMetric("verify_failed")
		s.logger.Warn("code-attest response missing registration-bound SE key")
		return
	}

	resumeProof := resp.Nonce != "" &&
		s.codeAttestThrottle.matchResumeChallenge(
			resp.Nonce, providerID, nodeKey, sePubKey, apnsToken)
	apnsProof := !resumeProof && resp.Nonce != "" &&
		s.codeAttestThrottle.matchChallengeForIdentity(
			sePubKey, resp.Nonce, apnsToken, nodeKey)
	if !resumeProof && !apnsProof {
		s.codeAttestMetric("nonce_mismatch")
		s.logger.Warn("code-attest response nonce mismatch or expired proof")
		return
	}
	// Verify Sign_SE(nonce) against the SE public key bound to THIS connection at
	// registration — never a key supplied in the response.
	if err := attestation.VerifyChallengeSignature(sePubKey, resp.Signature, resp.Nonce); err != nil {
		s.codeAttestMetric("verify_failed")
		s.logger.Warn("code-attest signature verification failed", "error", err)
		return
	}
	if resumeProof {
		if !s.codeAttestThrottle.consumeResumeChallenge(
			resp.Nonce, providerID, nodeKey, sePubKey, apnsToken,
		) {
			return // timeout/disconnect/racing response consumed it first
		}
	} else if !s.codeAttestThrottle.consumeChallengeForIdentity(
		sePubKey, resp.Nonce, apnsToken, nodeKey,
	) {
		return
	}

	if !provider.GrantProcessCodeAttested(apnsToken, nodeKey) {
		s.codeAttestMetric("identity_rotated")
		return
	}
	if apnsProof {
		s.codeAttestThrottle.recordAttestedForProcess(
			sePubKey, version, apnsToken, nodeKey, attestedBinaryHash)
		// Persist the SE+token+process-key+binary binding. Reuse still requires
		// a live encrypted nonce PoP before protected capabilities are restored.
		s.persistCodeAttestation(
			sePubKey, version, apnsToken, nodeKey, attestedBinaryHash)
		// The APNs challenge was atomically consumed after signature verification.
	}
	s.codeAttestMetric("attested")
	s.logger.Info("provider code-attested via APNs")
	// Newly eligible for private routing — drain requests that queued waiting for an
	// attested provider instead of waiting for the next heartbeat tick. Off the read
	// loop so verification stays responsive.
	saferun.Go(s.logger, "codeAttestDrain", func() {
		s.registry.DrainQueuedRequestsForProvider(provider)
	})
}
