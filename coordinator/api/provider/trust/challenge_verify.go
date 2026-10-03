package trust

import (
	"context"
	"encoding/base64"
	"encoding/json"

	"github.com/eigeninference/d-inference/coordinator/api/releases"
	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
)

func (s *Owner) verifyChallengeResponse(providerID string, provider *registry.Provider, pc *pendingChallenge, resp *protocol.AttestationResponseMessage) {
	provider.ClearApplicationEvidence()
	defer provider.SignalApplicationProofSettled()
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
	// with its SE key.
	if resp.Signature == "" {
		s.handleChallengeFailure(providerID, "empty signature")
		return
	}

	// statusFieldsTrusted gates whether we treat resp.SIPEnabled,
	// resp.BinaryHash etc. as authoritative. It is true only when the
	// status signature verified against the attested SE key; a provider
	// without an attested key (trust none) keeps advisory status fields.
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

		// Now verify the extended status signature. Every Swift provider
		// signs the canonical status in every challenge response, so a
		// missing signature is as fatal as a mismatch: either tampering,
		// a downgrade, or a provider signing a different canonical
		// payload than this code expects.
		statusInput := attestation.StatusCanonicalInput{
			Nonce:             pc.nonce,
			Timestamp:         pc.timestamp,
			RDMADisabled:      resp.RDMADisabled,
			SIPEnabled:        resp.SIPEnabled,
			SecureBootEnabled: resp.SecureBootEnabled,
			BinaryHash:        resp.BinaryHash,
			ActiveModelHash:   resp.ActiveModelHash,
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
			s.observation.Incr("attestation.challenges", []string{"outcome:status_sig_missing"})
			s.logger.Error("provider sent no status_signature — failing the challenge",
				"provider_id", providerID,
			)
			s.handleChallengeFailure(providerID, "status signature missing")
			return
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
			s.observation.Incr("attestation.challenges", []string{"outcome:status_sig_failed"})
			if s.observation.Metrics() != nil {
				s.observation.Metrics().IncCounter("attestation_status_sig_failed_total")
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
				"template_hashes_count", len(resp.TemplateHashes),
				"model_hashes_count", len(resp.ModelHashes),
			)
			s.handleChallengeFailure(providerID, "status signature verification failed: "+err.Error())
			return
		}
	}

	// Status-field enforcement policy: for a provider with an attested SE
	// key the fields below are bound by the verified status signature.
	// Negative reports (SIP=false, hash mismatch, etc.) mark the provider
	// untrusted, and an omitted mandatory field fails the challenge; for a
	// provider without an attested key the fields stay advisory and it
	// never holds hardware trust.
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

	// Verify fresh Secure Boot status. Like SIP, it is mandatory: an omitted
	// value is not evidence of safety, so fail closed.
	if resp.SecureBootEnabled == nil {
		s.handleChallengeFailure(providerID, "Secure Boot status not reported")
		return
	}
	if !*resp.SecureBootEnabled {
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
	// discipline.
	if resp.RDMADisabled == nil {
		s.handleChallengeFailure(providerID, "RDMA status not reported")
		return
	}
	if !*resp.RDMADisabled {
		s.logger.Info("provider RDMA enabled — accepting under registered-buffer RDMA policy",
			"provider_id", providerID,
			"backend", provider.Backend,
		)
	}

	// Verify fresh binary hash when a known-good policy is configured. A
	// reported binary hash only counts when the response is signed by the
	// provider key from a valid registration attestation.
	//
	// v0.6.0: binaryHash is self-reported and demoted to drift telemetry — APNs
	// code-identity attestation is the real code-identity signal — so this gate
	// deroutes a provider only when enforcement is explicitly enabled (rollback).
	policyConfigured, knownBinaryHashes := s.releases.BinaryHashPolicySnapshot()
	if s.releases.BinaryHashEnforced() && policyConfigured {
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
		attestedBinaryHash, err := releases.NormalizeSHA256Hex(attestationResult.BinaryHash, "attested binary_hash")
		if err != nil {
			s.logger.Error("provider attestation has no usable binary hash",
				"provider_id", providerID,
				"binary_hash", attestationResult.BinaryHash,
			)
			s.registry.MarkUntrusted(providerID)
			s.handleChallengeFailure(providerID, "attested binary hash missing")
			return
		}
		binaryHash, err := releases.NormalizeSHA256Hex(resp.BinaryHash, "binary_hash")
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
		if expectedHash != "" && !s.registry.CatalogAcceptsWeightHash(modelID, hash) {
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
			if s.registry.CatalogAcceptsWeightHash(m.ID, resp.ActiveModelHash) {
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
				if expected := s.registry.CatalogWeightHash(modelID); expected != "" && s.registry.CatalogAcceptsWeightHash(modelID, hash) {
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

	// Always ingest the signed runtime identity, even while policy is withdrawn:
	// otherwise a changed/omitted identity could leave stale approved hashes that
	// re-promote when the old manifest returns.
	runtimePolicyActive, runtimeOK, mismatches :=
		s.applyChallengeRuntimePolicy(provider, resp)
	if runtimePolicyActive && !runtimeOK {
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
				if err := provider.EnqueueText(context.Background(), statusData); err != nil {
					s.logger.Debug("failed to enqueue runtime status to provider", "provider_id", provider.ID, "error", err)
					s.observation.Incr("provider.enqueue_failed", []string{"msg:runtime_status"})
				}
			}
		}
		_ = s.registry.ReconcileAttestedRuntimeCapabilities(providerID)
		return
	}

	version, versionAllowed := s.applyChallengeMinVersionPolicy(provider)
	if !versionAllowed {
		s.logger.Warn("provider version below minimum during challenge revalidation — excluding from routing",
			"provider_id", providerID,
			"version", version,
			"min_version", s.minProviderVersion,
		)
		s.observation.Incr("provider_version_below_minimum", []string{"gate:challenge_revalidation", VersionMetricTag(version)})
		_ = s.registry.ReconcileAttestedRuntimeCapabilities(providerID)
		return
	}

	if err := s.registry.ReconcileAttestedRuntimeCapabilities(providerID); err != nil {
		s.logger.Warn("provider live runtime claims no longer match attestation",
			"provider_id", providerID,
			"reason", err.Error(),
		)
		s.registry.MarkUntrusted(providerID)
		s.handleChallengeFailure(providerID, "attested runtime claims mismatch")
		return
	}

	// Override the self-reported SIP capability with the coordinator-verified
	// value from the challenge response. The coordinator independently checks
	// SIP during each attestation challenge.
	provider.Mu().Lock()
	if provider.PrivacyCapabilities != nil {
		if resp.SIPEnabled != nil {
			provider.PrivacyCapabilities.SIPEnabled = *resp.SIPEnabled
		}
	}
	provider.ChallengeVerifiedSIP = resp.SIPEnabled != nil && *resp.SIPEnabled
	provider.Mu().Unlock()

	releaseFact := releases.ApprovedTransitionFact{}
	if fact, evidence, ok := s.releases.DeriveApprovedReleaseTransition(
		provider, resp, statusFieldsTrusted,
	); ok {
		if provider.GrantApplicationEvidenceIfNotUntrusted(evidence) {
			releaseFact = fact
			s.codeAttestMetric("direct_application_proof")
		} else {
			// Derivation succeeded but installation lost a race (policy
			// generation refresh or identity/token change between derive and
			// grant). The derive-side "granted" counter alone would make this
			// look successful; the distinct outcome keeps shadow-rollout
			// counters honest. The grant path already kicks a re-challenge.
			s.releases.RecordGrantLostRace()
		}
	}

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
		// The provider was transiently untrusted and is now back online. Push a
		// fresh status so its locally persisted operator state reflects recovery.
		provider.Mu().Lock()
		trustLevel := provider.TrustLevel
		provider.Mu().Unlock()
		s.sendTrustStatus(provider, trustLevel, "online", "recovered after transient deroute")
	}
	s.observation.Incr("attestation.challenges", []string{"outcome:passed"})
	s.logger.Info("attestation challenge verified",
		"provider_id", providerID,
		"sip_enabled", resp.SIPEnabled,
		"secure_boot_enabled", resp.SecureBootEnabled,
		"rdma_disabled", resp.RDMADisabled,
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

	// MDM SecurityInfo work is driven only by the Server-owned scheduler. The
	// periodic direct challenge refreshes live posture but never creates another
	// MDM command; reboot/reconnect instead rebinds the durable singleflight job.
	provider.Mu().Lock()
	trustLevel := provider.TrustLevel
	provider.Mu().Unlock()

	if trustLevel == registry.TrustSelfSigned {
		// DAR-326 Phase 0: trust-reuse fast-skip. The live SE challenge above just
		// re-proved this connection's identity + posture. If this device recently
		// passed a FULL live MDM verification (a fresh trust-reuse record) and the
		// fresh SIGNED challenge re-proves the SAME identity, an unchanged binary,
		// and good posture within the window, grant hardware now and complete the
		// scheduler fallback before any worker/command. The live SE challenge
		// always ran; any gate miss falls through to durable live verification.
		if s.tryTrustReuseFastSkip(providerID, provider, resp, statusFieldsTrusted, releaseFact) {
			// The fast-skip granted hardware WITHOUT running the full live MDM verify,
			// so verifyAppleDeviceAttestation never ran on this connection. Reuse the
			// durable MDA proof (re-verified locally against Apple's root + re-bound to
			// this SE key) so a restart keeps mda_verified green with zero MDM/APNs
			// traffic — the whole point of the fast-skip is to avoid that round-trip.
			if ar := provider.GetAttestationResult(); ar != nil {
				s.attachCachedMDAProof(providerID, provider, *ar)
			}
			if s.mdmScheduler != nil {
				s.mdmScheduler.ChallengeSettled(provider, true)
			}
			// DAR-326 FIX 3: the fast-skip just granted hardware, so this provider is
			// freshly routable — drain any queued requests now instead of waiting for
			// the next heartbeat / 120s queue timeout. Off the challenge goroutine,
			// mirroring the code-attest / MDM hardware-grant drain.
			saferun.Go(s.logger, "trustReuseDrain", func() {
				s.registry.DrainQueuedRequestsForProviderWithReason(provider, registry.DrainTriggerChallenge)
			})
		} else {
			// Fast-skip missed. The submit-time refresh classification (a
			// fresh-looking or continuity-covered record) is now known to be
			// optimistic — the read gate refused it — so promote the job to
			// first/expired before settling: the live MDM attempt must start
			// inside the 120s dispatch-queue deadline, not on the refresh
			// spread. Durable due time, priority, and retry stage then decide
			// when SecurityInfo runs.
			if s.mdmScheduler != nil {
				s.mdmScheduler.PromoteFailedFastSkip(provider)
				s.mdmScheduler.ChallengeSettled(provider, false)
			}
		}
	}
}

// VerificationSubmitPriority classifies this connection's durable SecurityInfo
// submission. A record currently admissible for the fast-skip — via window
// freshness OR connection continuity — schedules as a routine refresh (full
// spread); anything else is first/expired (immediate due). The classification
// is optimistic: if the fast-skip later DECLINES despite it, the read path
// promotes the job back to first/expired (PromoteFailedFastSkip).
