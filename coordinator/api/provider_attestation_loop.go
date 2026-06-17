package api

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"nhooyr.io/websocket"
)

// challengeLoop periodically sends attestation challenges to a provider.
func (s *Server) challengeLoop(ctx context.Context, conn *websocket.Conn, providerID string, provider *registry.Provider, tracker *challengeTracker) {
	if s.skipChallenge {
		return
	}

	interval := s.challengeInterval
	if interval == 0 {
		interval = DefaultChallengeInterval
	}

	// Send initial challenge immediately so the provider is routable
	// without waiting for the first ticker interval.
	s.sendChallenge(ctx, conn, providerID, provider, tracker)

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
			s.sendChallenge(ctx, conn, providerID, provider, tracker)
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
func (s *Server) sendChallenge(ctx context.Context, conn *websocket.Conn, providerID string, provider *registry.Provider, tracker *challengeTracker) {
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
	if err := conn.Write(writeCtx, websocket.MessageText, data); err != nil {
		s.logger.Error("failed to send challenge", "provider_id", providerID, "error", err)
		tracker.remove(nonce)
		return
	}
	s.ddIncr("attestation.challenges_sent", nil)

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
			s.handleTransientChallengeFailure(conn, providerID, "no response")
			return
		}
		s.verifyChallengeResponse(providerID, provider, pc, resp)
	case <-time.After(timeout):
		tracker.remove(nonce)
		s.handleTransientChallengeFailure(conn, providerID, "timeout")
	}
}

// handleAttestationResponse processes an attestation response from a provider.
func (s *Server) handleAttestationResponse(providerID string, provider *registry.Provider, msg *protocol.AttestationResponseMessage, tracker *challengeTracker) {
	if provider == nil {
		s.logger.Warn("attestation response from unregistered provider", "provider_id", providerID)
		return
	}

	pc := tracker.remove(msg.Nonce)
	if pc == nil {
		s.logger.Warn("attestation response for unknown challenge", "provider_id", providerID, "nonce", msg.Nonce[:8]+"...")
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
func (s *Server) verifyChallengeResponse(providerID string, provider *registry.Provider, pc *pendingChallenge, resp *protocol.AttestationResponseMessage) {
	// Verify the nonce matches.
	if resp.Nonce != pc.nonce {
		s.handleChallengeFailure(providerID, "nonce mismatch")
		return
	}

	// Verify the public key matches the registered key.
	if provider.PublicKey != "" && resp.PublicKey != provider.PublicKey {
		s.handleChallengeFailure(providerID, "public key mismatch")
		return
	}

	// Verify the signature cryptographically using the provider's Secure
	// Enclave P-256 public key. The provider signs SHA-256(nonce + timestamp)
	// with its SE key via eigeninference-enclave CLI.
	if resp.Signature == "" {
		s.handleChallengeFailure(providerID, "empty signature")
		return
	}

	// statusFieldsTrusted gates whether we treat resp.SIPEnabled,
	// resp.BinaryHash etc. as authoritative. False means the provider
	// signed only nonce+timestamp (legacy or downgrade), so the status
	// fields are advisory and we must not act on them as if they were
	// cryptographically bound.
	statusFieldsTrusted := false

	// If the provider has an attested SE public key, verify the signature.
	// Providers without attestation (TrustNone / Open Mode) skip crypto
	// verification — their trust is already "none".
	if provider.AttestationResult != nil && provider.AttestationResult.PublicKey != "" {
		challengeData := pc.nonce + pc.timestamp
		if err := attestation.VerifyChallengeSignature(
			provider.AttestationResult.PublicKey,
			resp.Signature,
			challengeData,
		); err != nil {
			s.logger.Error("challenge signature verification failed",
				"provider_id", providerID,
				"error", err,
			)
			s.handleChallengeFailure(providerID, "signature verification failed: "+err.Error())
			return
		}

		// Now verify the extended status signature if the provider sent
		// one. Old providers (pre-v0.3.11) won't — log and continue with
		// status fields untrusted. Mismatch is fatal: it means either
		// tampering or the provider is signing a different canonical
		// payload than this code expects.
		statusInput := attestation.StatusCanonicalInput{
			Nonce:             pc.nonce,
			Timestamp:         pc.timestamp,
			HypervisorActive:  resp.HypervisorActive,
			RDMADisabled:      resp.RDMADisabled,
			SIPEnabled:        resp.SIPEnabled,
			SecureBootEnabled: resp.SecureBootEnabled,
			BinaryHash:        resp.BinaryHash,
			ActiveModelHash:   resp.ActiveModelHash,
			PythonHash:        resp.PythonHash,
			RuntimeHash:       resp.RuntimeHash,
			TemplateHashes:    resp.TemplateHashes,
			ModelHashes:       resp.ModelHashes,
		}
		switch err := attestation.VerifyStatusSignature(
			provider.AttestationResult.PublicKey,
			resp.StatusSignature,
			statusInput,
		); err {
		case nil:
			statusFieldsTrusted = true
		case attestation.ErrStatusSignatureMissing:
			s.ddIncr("attestation.challenges", []string{"outcome:status_sig_missing"})
			s.logger.Warn("provider sent no status_signature — status fields are advisory; upgrade provider to bind them",
				"provider_id", providerID,
			)
		default:
			// Instrumentation for the non-recovering status-sig lockout seen on
			// a couple of nodes (cause unconfirmed). Because the plain challenge
			// signature already verified above (we returned on its failure),
			// reaching here isolates the status-sig / canonical path: log
			// plain_sig_passed plus the Go canonical bytes and per-field lengths
			// so a field-presence or canonicalization mismatch is diagnosable
			// from logs alone, without shipping a new build to the affected box.
			canonical, cerr := attestation.BuildStatusCanonical(statusInput)
			canonicalB64 := ""
			if cerr == nil {
				canonicalB64 = base64.StdEncoding.EncodeToString(canonical)
			}
			s.ddIncr("attestation.challenges", []string{"outcome:status_sig_failed"})
			if s.metrics != nil {
				s.metrics.IncCounter("attestation_status_sig_failed_total")
			}
			s.logger.Error("status signature verification failed — possible tampering or canonical mismatch",
				"provider_id", providerID,
				"error", err,
				"plain_sig_passed", true,
				"go_canonical_b64", canonicalB64,
				"go_canonical_len", len(canonical),
				"canonical_build_err", cerr,
				"status_sig_len", len(resp.StatusSignature),
				"binary_hash_len", len(resp.BinaryHash),
				"active_model_hash_len", len(resp.ActiveModelHash),
				"python_hash_len", len(resp.PythonHash),
				"runtime_hash_len", len(resp.RuntimeHash),
				"template_hashes_count", len(resp.TemplateHashes),
				"model_hashes_count", len(resp.ModelHashes),
			)
			s.handleChallengeFailure(providerID, "status signature verification failed: "+err.Error())
			return
		}
	}

	// Status-field enforcement policy (asymmetric, by design):
	//
	// The checks below act on resp.SIPEnabled / SecureBootEnabled /
	// RDMADisabled / BinaryHash / ActiveModelHash regardless of
	// statusFieldsTrusted. The asymmetry is intentional during the
	// v0.3.11 rollout window:
	//
	//   - Negative reports (SIP=false, hash mismatch, etc.) ALWAYS mark
	//     the provider untrusted. Acting on a negative is safe even if
	//     the field is spoofable: the worst case is a compromised
	//     provider DoS-ing itself, which we want anyway.
	//
	//   - Positive reports (SIP=true, hash matches) are accepted but
	//     can only be fully trusted when statusFieldsTrusted is true.
	//     A v0.3.10 provider with a compromised process (but intact SE
	//     key) can echo a valid nonce signature while lying that
	//     SIPEnabled=true. We accept this risk during rollout.
	//
	// TODO(security/v0.3.13+): Once `attestation_challenges_total{
	// outcome="status_sig_missing"}` is zero across the fleet for a
	// week, treat ErrStatusSignatureMissing as a hard challenge failure
	// (target: 2 release cycles after v0.3.11 GA).
	s.logger.Debug("attestation challenge response verified",
		"provider_id", providerID,
		"status_fields_trusted", statusFieldsTrusted,
	)

	// Verify fresh SIP status. This signal is mandatory for private text:
	// an omitted value is not evidence of safety, so fail closed.
	if resp.SIPEnabled == nil {
		s.handleChallengeFailure(providerID, "SIP status not reported")
		return
	}
	// If the provider reports SIP disabled, they've rebooted since
	// registration and are no longer trustworthy. SIP cannot be disabled at
	// runtime — a reboot into Recovery Mode is required.
	if !*resp.SIPEnabled {
		s.logger.Error("provider SIP disabled in challenge response — marking untrusted",
			"provider_id", providerID,
		)
		s.registry.MarkUntrusted(providerID)
		s.handleChallengeFailure(providerID, "SIP disabled")
		return
	}

	// Verify fresh Secure Boot status.
	if resp.SecureBootEnabled != nil && !*resp.SecureBootEnabled {
		s.logger.Error("provider Secure Boot disabled in challenge response — marking untrusted",
			"provider_id", providerID,
		)
		s.registry.MarkUntrusted(providerID)
		s.handleChallengeFailure(providerID, "Secure Boot disabled")
		return
	}

	// Verify fresh RDMA status. Reporting remains mandatory so routing and
	// trust policy can distinguish single-node providers from RDMA-aware
	// cluster runtimes. RDMA enablement is not itself a challenge failure:
	// Apple Silicon Thunderbolt RDMA is IOMMU-scoped to registered buffers,
	// so the security boundary is the signed runtime's buffer-registration
	// discipline, not a hypervisor flag.
	if resp.RDMADisabled == nil {
		s.handleChallengeFailure(providerID, "RDMA status not reported — provider must update to v0.2.0+")
		return
	}
	if !*resp.RDMADisabled {
		s.logger.Info("provider RDMA enabled — accepting under registered-buffer RDMA policy",
			"provider_id", providerID,
			"backend", provider.Backend,
			"hypervisor_active", resp.HypervisorActive,
		)
	}

	// Verify fresh binary hash when a known-good policy is configured. A
	// reported binary hash only counts when the response is signed by the
	// provider key from a valid registration attestation.
	//
	// v0.6.0: binaryHash is self-reported and demoted to drift telemetry — APNs
	// code-identity attestation is the real code-identity signal — so this gate
	// deroutes a provider only when enforcement is explicitly enabled (rollback).
	policyConfigured, knownBinaryHashes := s.binaryHashPolicySnapshot()
	if s.binaryHashEnforce && policyConfigured {
		attestationResult := provider.AttestationResult
		if attestationResult == nil || !attestationResult.Valid || attestationResult.PublicKey == "" {
			s.logger.Error("provider cannot prove binary hash without valid attestation",
				"provider_id", providerID,
			)
			s.registry.MarkUntrusted(providerID)
			s.handleChallengeFailure(providerID, "valid attestation required for binary hash policy")
			return
		}
		if resp.BinaryHash == "" {
			s.logger.Error("provider omitted binary hash while known-good policy is configured",
				"provider_id", providerID,
			)
			s.registry.MarkUntrusted(providerID)
			s.handleChallengeFailure(providerID, "binary hash missing")
			return
		}
		attestedBinaryHash, err := normalizeSHA256Hex(attestationResult.BinaryHash, "attested binary_hash")
		if err != nil {
			s.logger.Error("provider attestation has no usable binary hash",
				"provider_id", providerID,
				"binary_hash", attestationResult.BinaryHash,
			)
			s.registry.MarkUntrusted(providerID)
			s.handleChallengeFailure(providerID, "attested binary hash missing")
			return
		}
		binaryHash, err := normalizeSHA256Hex(resp.BinaryHash, "binary_hash")
		if err != nil || !knownBinaryHashes[binaryHash] {
			s.logger.Error("provider binary hash changed — no longer matches known-good list",
				"provider_id", providerID,
				"binary_hash", resp.BinaryHash,
			)
			s.registry.MarkUntrusted(providerID)
			s.handleChallengeFailure(providerID, "binary hash mismatch")
			return
		}
		if binaryHash != attestedBinaryHash {
			s.logger.Error("provider binary hash changed from registration attestation",
				"provider_id", providerID,
				"attested_binary_hash", registry.TruncHash(attestedBinaryHash),
				"challenge_binary_hash", registry.TruncHash(binaryHash),
			)
			s.registry.MarkUntrusted(providerID)
			s.handleChallengeFailure(providerID, "binary hash changed from registration attestation")
			return
		}
	}

	// Verify reported model weight hashes against the catalog. The response's
	// model_hashes map is keyed by model ID, so each entry is compared against
	// the catalog hash for exactly that model — race-free, and strictly
	// stronger than checking only the active model.
	//
	// The previous check compared resp.ActiveModelHash (the hash of whatever
	// model the PROVIDER considered current when it built the response)
	// against the catalog hash of provider.CurrentModel (the model the
	// COORDINATOR believed current, from the last heartbeat — up to a full
	// heartbeat interval stale). On a busy multi-model provider the current
	// model flips between heartbeats, so the two regularly disagreed and a
	// perfectly correct hash of model B was misread as a tampered hash of
	// model A ("possible model swap") → false hard-untrust. Hit in prod by
	// the two busiest dual-model boxes (gemma-4-26b + gpt-oss-20b interleaved).
	for modelID, hash := range resp.ModelHashes {
		if hash == "" {
			continue
		}
		expectedHash := s.registry.CatalogWeightHash(modelID)
		if expectedHash != "" && hash != expectedHash {
			s.logger.Error("provider model weight hash mismatch — possible model swap",
				"provider_id", providerID,
				"model", modelID,
				"expected", registry.TruncHash(expectedHash),
				"got", registry.TruncHash(hash),
			)
			s.registry.MarkUntrusted(providerID)
			s.handleChallengeFailure(providerID, "model weight hash mismatch")
			return
		}
	}

	// The bare active_model_hash names no model, so the strongest race-free
	// statement it admits is membership: when EVERY advertised model has an
	// enforced catalog hash, a hash that matches none of them is tampered.
	// This runs regardless of model_hashes — a map holding only empty or
	// unknown entries must not suppress it — and stays inconclusive (skipped)
	// when any advertised model is unenforced, since the bare hash could
	// legitimately belong to that model. (Comparing against the
	// heartbeat-derived "current model" instead is inherently racy — see
	// above.)
	if resp.ActiveModelHash != "" {
		provider.Mu().Lock()
		models := provider.Models
		provider.Mu().Unlock()
		allEnforced := len(models) > 0
		matched := false
		for _, m := range models {
			expectedHash := s.registry.CatalogWeightHash(m.ID)
			if expectedHash == "" {
				allEnforced = false
				break
			}
			if resp.ActiveModelHash == expectedHash {
				matched = true
			}
		}
		// Alias hot-swap (v0.6.x): a hard-swapped build can stay GPU-resident —
		// and remain the provider's "active" model — AFTER it leaves the
		// advertised set (the retired slot drains via the idle monitor, up to
		// an hour). Its hash still arrives in model_hashes, where the per-model
		// loop above already proved it matches its own catalog entry. Such a
		// validated, registered build is a legitimate alibi for the bare active
		// hash — NOT a swap. Without this, every provider hard-untrusts at its
		// first post-swap challenge until a request lands on the new build.
		// A genuinely tampered hash still matches neither the advertised set
		// nor any catalog-validated reported hash, and still untrusts.
		if !matched {
			for modelID, hash := range resp.ModelHashes {
				if hash == "" || hash != resp.ActiveModelHash {
					continue
				}
				// Scope the alibi to the actual migration case: modelID must be a
				// PREVIOUS/RETIRED member of some alias (a build a hot-swap leaves
				// resident after de-advertising it), not just any catalog model.
				// This keeps the membership check tight — a provider can't name an
				// arbitrary unrelated catalog model as "active" to dodge it.
				if !s.registry.IsAliasLineageBuild(modelID) {
					continue
				}
				if expected := s.registry.CatalogWeightHash(modelID); expected != "" && hash == expected {
					matched = true
					break
				}
			}
		}
		if allEnforced && !matched {
			s.logger.Error("provider active model hash matches no advertised model — possible model swap",
				"provider_id", providerID,
				"got", registry.TruncHash(resp.ActiveModelHash),
			)
			s.registry.MarkUntrusted(providerID)
			s.handleChallengeFailure(providerID, "active model weight hash mismatch")
			return
		}
	}

	// Verify runtime integrity hashes from the signed challenge response.
	// Swift providers omit Python/vllm hashes, but must still match manifest
	// entries for external runtime assets such as mlx.metallib.
	if s.knownRuntimeManifest != nil {
		runtimeOK, mismatches := s.verifyRuntimeHashesForBackend(
			provider.Backend, resp.PythonHash, resp.RuntimeHash, resp.TemplateHashes)
		provider.Mu().Lock()
		provider.RuntimeVerified = runtimeOK
		provider.RuntimeManifestChecked = runtimeOK
		if resp.PythonHash != "" {
			provider.PythonHash = resp.PythonHash
		}
		if resp.RuntimeHash != "" {
			provider.RuntimeHash = resp.RuntimeHash
		}
		if len(resp.TemplateHashes) > 0 {
			provider.TemplateHashes = registry.CloneStringMap(resp.TemplateHashes)
		}
		provider.Mu().Unlock()

		if !runtimeOK {
			// Log detailed mismatch info for debugging outages.
			mismatchDetails := make([]string, 0, len(mismatches))
			for _, m := range mismatches {
				mismatchDetails = append(mismatchDetails, m.Component+"="+m.Got)
			}
			s.logger.Warn("provider runtime integrity mismatch in challenge response — excluding from routing",
				"provider_id", providerID,
				"mismatches", len(mismatches),
				"details", mismatchDetails,
				"backend", provider.Backend,
			)
			// Send status feedback but do NOT fail the challenge or mark untrusted.
			// The provider remains connected but is excluded from routing until
			// it reports matching hashes.
			if provider.Conn != nil {
				statusMsg := protocol.RuntimeStatusMessage{
					Type:       protocol.TypeRuntimeStatus,
					Verified:   false,
					Mismatches: mismatches,
				}
				statusData, err := json.Marshal(statusMsg)
				if err == nil {
					writeCtx, writeCancel := context.WithTimeout(context.Background(), 5*time.Second)
					_ = provider.Conn.Write(writeCtx, websocket.MessageText, statusData)
					writeCancel()
				}
			}
			return
		}
	}

	provider.Mu().Lock()
	version := provider.Version
	provider.Mu().Unlock()
	if s.minProviderVersion != "" && version != "" && semverLess(version, s.minProviderVersion) {
		s.logger.Warn("provider version below minimum during challenge revalidation — excluded from routing",
			"provider_id", providerID,
			"version", version,
			"min_version", s.minProviderVersion,
		)
		s.ddIncr("provider_version_below_minimum", []string{"gate:challenge_revalidation", "version:" + version})
		provider.Mu().Lock()
		provider.RuntimeVerified = false
		provider.RuntimeManifestChecked = false
		provider.Mu().Unlock()
		return
	}

	// Override self-reported privacy capabilities with coordinator-verified
	// values from the challenge response. The coordinator independently checks
	// SIP during each attestation challenge. Hypervisor status is preserved as
	// a reported capability only; it is not the RDMA safety proof.
	provider.Mu().Lock()
	if provider.PrivacyCapabilities != nil {
		if resp.SIPEnabled != nil {
			provider.PrivacyCapabilities.SIPEnabled = *resp.SIPEnabled
		}
		if resp.HypervisorActive != nil {
			provider.PrivacyCapabilities.HypervisorActive = *resp.HypervisorActive
		}
	}
	provider.ChallengeVerifiedSIP = resp.SIPEnabled != nil && *resp.SIPEnabled
	provider.Mu().Unlock()

	// Challenge passed. Refresh stored per-model weight hashes BEFORE
	// RecordChallengeSuccess: its queue drain re-enters routing, and queued
	// requests must be admitted against the hashes this verified response just
	// proved — not the registration-time snapshot. The provider recomputes
	// hashes when it (re)loads a model from disk (e.g. after a model
	// re-publish), so the registration-time value can go stale mid-connection,
	// which would silently fail the per-model catalog routing filter until the
	// next reconnect.
	s.registry.UpdateModelWeightHashes(providerID, resp.ModelHashes)

	recovered := s.registry.RecordChallengeSuccess(providerID)
	if recovered {
		// The provider was transiently untrusted and is now back online. It was
		// last told "untrusted" (handleChallengeFailure) and scheduled a 10-min
		// diagnostic auto-report; push a fresh "online" trust_status so it clears
		// that local state and cancels the report.
		provider.Mu().Lock()
		trustLevel := provider.TrustLevel
		provider.Mu().Unlock()
		s.sendTrustStatus(provider, trustLevel, "online", "recovered after transient deroute")
	}
	s.ddIncr("attestation.challenges", []string{"outcome:passed"})
	s.logger.Info("attestation challenge verified",
		"provider_id", providerID,
		"sip_enabled", resp.SIPEnabled,
		"secure_boot_enabled", resp.SecureBootEnabled,
		"rdma_disabled", resp.RDMADisabled,
		"hypervisor_active", resp.HypervisorActive,
		"binary_hash", resp.BinaryHash,
		"active_model_hash", resp.ActiveModelHash,
		"model_hashes_count", len(resp.ModelHashes),
	)
	for modelID, hash := range resp.ModelHashes {
		s.logger.Info("model weight hash verified",
			"provider_id", providerID,
			"model_id", modelID,
			"weight_hash", hash,
		)
	}

	// MDM SecurityInfo re-verification is intentionally NOT driven from the
	// challenge response. The per-connection mdmVerificationLoop owns MDM
	// verification with a push-budget-aware backoff.
	provider.Mu().Lock()
	trustLevel := provider.TrustLevel
	provider.Mu().Unlock()

	// Re-attempt ACME (mTLS device-cert) trust for self_signed providers.
	// applyACMETrust ran at registration before attestation was bound, so a
	// provider that presented a valid device cert can be promoted to hardware
	// now that the challenge has passed. No-op if nothing was stashed.
	if trustLevel == registry.TrustSelfSigned {
		s.retryACMETrust(providerID, provider)
	}
}

// handleTransientChallengeFailure records a transient challenge failure
// (timeout / no response) and, once a provider has missed too many consecutive
// challenges, force-closes its WebSocket so it must reconnect and re-register.
//
// A provider whose outbound path is wedged keeps heartbeating (so the stale
// sweeper never evicts it) while every challenge times out, pinning it
// hardware/untrusted forever. MarkUntrustedTransient alone cannot recover it
// because recovery requires a passing challenge, which requires a working
// outbound path. Cycling the connection forces a clean re-registration.
func (s *Server) handleTransientChallengeFailure(conn *websocket.Conn, providerID, reason string) {
	failures := s.handleChallengeFailure(providerID, reason)
	if conn == nil || failures < MaxConsecutiveChallengeTimeoutsBeforeReconnect {
		return
	}
	s.logger.Warn("provider exceeded consecutive challenge timeouts — forcing reconnect",
		"provider_id", providerID,
		"consecutive_failures", failures,
		"reason", reason,
	)
	s.ddIncr("attestation.force_reconnect", []string{"reason:" + reason})
	if s.metrics != nil {
		s.metrics.IncCounter("attestation_force_reconnect_total", MetricLabel{"reason", reason})
	}
	// Closing the conn unblocks providerReadLoop's conn.Read, which cancels the
	// loop context (stopping this challenge loop) and runs registry.Disconnect.
	_ = conn.Close(websocket.StatusPolicyViolation, "attestation unresponsive — reconnect required")
}

// handleChallengeFailure records a failed challenge and marks the provider
// as untrusted if the failure threshold is reached. It returns the running
// count of consecutive failures.
func (s *Server) handleChallengeFailure(providerID string, reason string) int {
	transient := reason == "timeout" || reason == "no response"
	failures := s.registry.RecordChallengeFailure(providerID, transient)
	s.ddIncr("attestation.challenges", []string{"outcome:failed"})
	s.logger.Warn("attestation challenge failed",
		"provider_id", providerID,
		"reason", reason,
		"consecutive_failures", failures,
	)

	severity := protocol.SeverityWarn
	if failures >= registry.MaxFailedChallenges {
		severity = protocol.SeverityError
		if transient {
			// Missed-challenge timeouts (sleep / network blip) are recoverable:
			// keep challenging and let a later passing challenge restore the
			// provider without requiring a reconnect.
			s.registry.MarkUntrustedTransient(providerID)
		} else {
			s.registry.MarkUntrusted(providerID)
		}
		if p := s.registry.GetProvider(providerID); p != nil {
			s.sendTrustStatus(p, p.TrustLevel, string(registry.StatusUntrusted), reason)
		}
	}
	s.emit(context.Background(), severity, protocol.KindAttestationFailure,
		"attestation challenge failed",
		map[string]any{
			"provider_id":     providerID,
			"reason":          reason,
			"reconnect_count": failures,
		})
	if s.metrics != nil {
		s.metrics.IncCounter("attestation_failures_total",
			MetricLabel{"reason", reason},
		)
	}
	s.ddIncr("attestation.failures", []string{"reason:" + reason})
	return failures
}
