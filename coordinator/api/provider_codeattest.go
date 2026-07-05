package api

// APNs code-identity attestation (v0.6.0). The coordinator pushes an encrypted
// nonce to a provider's device via APNs; the provider replies with a Secure
// Enclave signature over it, proving the running binary's code identity. This
// file owns the per-connection challenge loop, the same-/cross-version and
// reconnect reuse fast-paths, the heartbeat-driven re-arm (late/rotated token),
// the push, and the fail-closed verification chokepoint. CodeAttested is set
// ONLY by handleCodeAttestationResponse after the full round-trip verifies.

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"time"

	"github.com/eigeninference/d-inference/coordinator/apns"
	"github.com/eigeninference/d-inference/coordinator/attestation"
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
//   - Reuse: if this device (Secure Enclave key) attested recently with the same
//     binary version, the new connection inherits the proof with NO push.
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
// tryCrossVersionReuse rides a recent same-device, same-token attestation across a
// binary VERSION change so a healthy update isn't forced into a fresh APNs round-
// trip (which would deroute the provider for the whole re-attest window). Reuse
// fires only behind ALL fences: valid registration attestation, runtime + manifest
// verified, SIP-verified challenge, a non-empty version at/above MIN_PROVIDER_VERSION,
// and the same non-empty APNs token. The SE key + token alone are too weak
// (NodeKeyPair rotates per startup), so the fences are what prove the current
// binary is legitimate. Decision + grant run atomically via GrantCodeAttestedIf
// against the LIVE state, so a concurrent token rotation can't slip a stale-token
// proof past the gate. Returns true (and drains) when reuse fired.
func (s *Server) tryCrossVersionReuse(providerID string, provider *registry.Provider) bool {
	// blockedBy names the first fence that prevented reuse, for forensic debugging
	// of a provider stuck re-challenging instead of reusing (set inside the locked
	// decision; read only after it returns).
	blockedBy := ""
	granted := provider.GrantCodeAttestedIf(func(st registry.CodeIdentityState) bool {
		// An empty version never satisfies a configured floor (version is optional
		// on the wire); only treat the floor as cleared when there is no floor.
		aboveMinVersion := s.minProviderVersion == "" ||
			(st.Version != "" && !semverLess(st.Version, s.minProviderVersion))
		switch {
		case !st.AttestationValid:
			blockedBy = "attestation_invalid"
		case !st.RuntimeVerified:
			blockedBy = "runtime_unverified"
		case !st.RuntimeManifestChecked:
			blockedBy = "runtime_manifest_unchecked"
		case !st.ChallengeVerifiedSIP:
			blockedBy = "sip_challenge_pending" // armed concurrently; the loop re-checks
		case !aboveMinVersion:
			blockedBy = "below_min_version"
		default:
			// reuseAttestationCrossVersion takes the throttle lock; the lock order is
			// always provider → throttle (throttle methods never touch a provider),
			// so calling it from inside the provider-locked decision is deadlock-safe.
			if !s.codeAttestThrottle.reuseAttestationCrossVersion(st.SEPublicKey, st.APNsDeviceToken) {
				blockedBy = "no_fresh_same_token_proof"
				return false
			}
			return true
		}
		return false
	})
	if !granted {
		s.logger.Debug("code-attest: cross-version reuse not taken; will challenge/poll",
			"provider_id", providerID, "blocked_by", blockedBy)
		return false
	}
	s.registry.DrainQueuedRequestsForProvider(provider)
	s.codeAttestMetric("reused_cross_version")
	s.logger.Info("code-attest: reused a recent attestation across a version change (fenced: attestation+runtime+SIP+min-version verified; no push)",
		"provider_id", providerID)
	return true
}

func (s *Server) codeAttestLoop(ctx context.Context, providerID string, provider *registry.Provider) {
	if s.codeAttestor == nil || provider == nil {
		return
	}

	provider.Mu().Lock()
	apnsToken := provider.APNsDeviceToken
	version := provider.Version
	var seKey string
	if provider.AttestationResult != nil {
		seKey = provider.AttestationResult.PublicKey
	}
	provider.Mu().Unlock()
	if apnsToken == "" {
		s.codeAttestMetric("no_token")
		s.logger.Info("code-attest: provider has no APNs device token; cannot attest (will be derouted once enforcement begins)",
			"provider_id", providerID)
		return
	}

	// Reuse a recent, same-version, SAME-TOKEN attestation for this device instead
	// of spending a push — the binary can't have changed (same version), the APNs
	// token is unchanged (Codex #7), and the proof is fresh.
	if s.codeAttestThrottle.reuseAttestation(seKey, version, apnsToken) {
		provider.SetCodeAttested(true)
		s.registry.DrainQueuedRequestsForProvider(provider)
		s.codeAttestMetric("reused")
		s.logger.Info("code-attest: reused a recent attestation for this device (no push)",
			"provider_id", providerID)
		return
	}

	// Cross-version reuse (every update bumps the version, missing the same-version
	// reuse above). Try up front; the loop also re-checks since the fences arm
	// concurrently on a fresh connection.
	if s.tryCrossVersionReuse(providerID, provider) {
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
		if provider.GetCodeAttested() {
			return // attested by the delivery path; nothing more to do
		}
		if provider.ChallengeShouldStop() {
			return // hard (non-recoverable) untrust — stop challenging
		}

		// Re-check each iteration: the fences arm concurrently, so a connection that
		// missed up front may reuse now instead of burning a push.
		if s.tryCrossVersionReuse(providerID, provider) {
			return
		}

		// Push when the per-device budget permits. A budget cooldown elapsing
		// without attestation means a delivered push's reply never came (timeout);
		// a budget held over from a prior connection means we simply wait (poll)
		// for that reply rather than burning another push (reconnect-safe).
		if s.codeAttestThrottle.allowPush(seKey, alertMode) {
			if prevSent {
				s.codeAttestMetric("timeout")
				s.logger.Warn("code-attest: no valid reply within the push budget; retrying",
					"provider_id", providerID, "attempt", pushes)
			}
			if pushes >= s.codeAttestThrottle.maxAttempts {
				s.codeAttestMetric("max_attempts")
				s.logger.Warn("code-attest: not attested after max attempts; will retry on a later reconnect (within the push budget)",
					"provider_id", providerID)
				return
			}
			s.codeAttestThrottle.recordPush(seKey)
			prevSent = s.sendCodeIdentityChallenge(ctx, providerID, provider)
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
//     ride a proof earned under the old one.
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
		// Fail-closed: a changed token must complete a fresh round-trip before it
		// is treated as code-attested (and thus routable) again.
		provider.CodeAttested = false
	}
	provider.Mu().Unlock()

	if changed {
		// No bypass: drop the cached reuse record (in-memory) AND the persisted
		// row, so neither this connection nor a post-restart reseed can short-
		// circuit on a prior (old-token) proof — the loop must run a REAL
		// challenge against the new token (Codex #6). Also drop any outstanding
		// old-token challenge so a stale reply to it can't complete the rotation
		// if the fresh push is delayed/fails (Codex #1, fail-closed). And clear the
		// per-device push cooldown (keyed by SE key, tracking pushes to the OLD
		// token) so the forced re-challenge can reach the new token immediately —
		// the new token has its own Apple budget (Codex #9).
		s.codeAttestThrottle.invalidateReuse(seKey)
		s.codeAttestThrottle.clearChallenge(seKey)
		s.codeAttestThrottle.clearPushBudget(seKey)
		s.invalidatePersistedCodeAttestation(seKey)
		s.codeAttestMetric("rearm_token_changed")
		s.logger.Info("code-attest: APNs device token changed; forcing re-challenge (no reuse bypass)",
			"provider_id", providerID)
	} else {
		s.codeAttestMetric("rearm_token_arrived")
		s.logger.Info("code-attest: APNs device token arrived after registration; arming challenge (no reconnect)",
			"provider_id", providerID)
	}

	saferun.Go(s.logger, "codeAttestRearm", func() {
		s.codeAttestLoop(ctx, providerID, provider)
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
func (s *Server) sendCodeIdentityChallenge(ctx context.Context, providerID string, provider *registry.Provider) bool {
	if s.codeAttestor == nil || provider == nil {
		return false
	}
	provider.Mu().Lock()
	deviceToken := provider.APNsDeviceToken
	env := provider.APNsEnvironment
	pubKey := provider.PublicKey
	var sePubKey string
	if provider.AttestationResult != nil {
		sePubKey = provider.AttestationResult.PublicKey
	}
	provider.Mu().Unlock()

	if deviceToken == "" || pubKey == "" || sePubKey == "" {
		s.logger.Warn("code-attest skipped: missing device token, encryption key, or SE key",
			"provider_id", providerID,
			"has_token", deviceToken != "",
			"has_pubkey", pubKey != "",
			"has_se_key", sePubKey != "",
		)
		return false
	}

	nonceBytes := make([]byte, 32)
	if _, err := rand.Read(nonceBytes); err != nil {
		s.logger.Error("code-attest nonce generation failed", "provider_id", providerID, "error", err)
		return false
	}
	nonceB64 := base64.StdEncoding.EncodeToString(nonceBytes)

	// Record BEFORE the push so a reply that races back (even on another
	// connection) is matchable. Keyed by SE key, so it survives reconnects.
	s.codeAttestThrottle.recordChallenge(sePubKey, nonceB64)

	sendCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	err := s.codeAttestor.SendCodeChallenge(sendCtx, deviceToken, env, pubKey, nonceB64)
	cancel()
	if err != nil {
		// The push never went out — drop the outstanding challenge so no stale
		// reply for this nonce can attest.
		s.codeAttestThrottle.clearChallengeIf(sePubKey, nonceB64)
		s.codeAttestMetric("push_send_failed")
		s.logger.Warn("code-attest push send failed", "provider_id", providerID, "error", err)
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
		s.logger.Warn("code-attest response from unregistered provider", "provider_id", providerID)
		return
	}
	if resp == nil {
		return
	}
	if provider.GetCodeAttested() {
		return // already attested on this connection; ignore duplicate/late replies
	}

	provider.Mu().Lock()
	var sePubKey string
	if provider.AttestationResult != nil {
		sePubKey = provider.AttestationResult.PublicKey
	}
	version := provider.Version
	apnsToken := provider.APNsDeviceToken
	provider.Mu().Unlock()

	if sePubKey == "" {
		s.codeAttestMetric("verify_failed")
		s.logger.Warn("code-attest response but provider has no registration-bound SE key",
			"provider_id", providerID)
		return
	}

	// Match against ANY still-valid nonce we pushed to THIS device (survives
	// reconnect, and accepts a reply to an earlier in-flight challenge in alert
	// mode; no/expired match => fail-closed) — Codex #8.
	if resp.Nonce == "" || !s.codeAttestThrottle.matchChallenge(sePubKey, resp.Nonce) {
		s.codeAttestMetric("nonce_mismatch")
		s.logger.Warn("code-attest response nonce mismatch or no outstanding challenge",
			"provider_id", providerID)
		return
	}
	// Verify Sign_SE(nonce) against the SE public key bound to THIS connection at
	// registration — never a key supplied in the response.
	if err := attestation.VerifyChallengeSignature(sePubKey, resp.Signature, resp.Nonce); err != nil {
		s.codeAttestMetric("verify_failed")
		s.logger.Warn("code-attest signature verification failed", "provider_id", providerID, "error", err)
		return
	}

	provider.SetCodeAttested(true)
	s.codeAttestThrottle.recordAttested(sePubKey, version, apnsToken)
	// Persist the same record (incl. the bound APNs token) so the reuse cache
	// survives a coordinator restart/blue-green deploy (W5 Fix 2) yet still forces a
	// re-challenge if the token later rotates (Codex #7). Behind the store seam +
	// off the read loop; written only here, after the full round-trip verified above.
	s.persistCodeAttestation(sePubKey, version, apnsToken)
	s.codeAttestThrottle.clearChallengeIf(sePubKey, resp.Nonce)
	s.codeAttestMetric("attested")
	s.logger.Info("provider code-attested via APNs", "provider_id", providerID)
	// Newly eligible for private routing — drain requests that queued waiting for an
	// attested provider instead of waiting for the next heartbeat tick. Off the read
	// loop so verification stays responsive.
	saferun.Go(s.logger, "codeAttestDrain", func() {
		s.registry.DrainQueuedRequestsForProvider(provider)
	})
}
