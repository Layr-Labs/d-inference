package challenge

import (
	"context"
	"encoding/json"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/providercontrol/trustreuse"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
)

// VerifyResponse verifies a challenge response from a provider.
// In addition to verifying the nonce and signature, it checks the fresh
// SIP status reported by the provider. If SIP has been disabled since
// registration, the provider is marked untrusted immediately.
func (s *Verifier) VerifyResponse(providerID string, provider *registry.Provider, expected Expected, resp *protocol.AttestationResponseMessage) {
	provider.ClearApplicationEvidence()
	defer provider.SignalApplicationProofSettled()
	statusFieldsTrusted, valid := s.verifySignatures(providerID, provider, expected, resp)
	if !valid {
		return
	}
	if !s.verifyPosture(providerID, provider, resp) {
		return
	}
	if !s.verifyBinaryHash(providerID, provider, resp) {
		return
	}
	if !s.verifyModelHashes(providerID, provider, resp) {
		return
	}

	// Always ingest the signed runtime identity, even while policy is withdrawn:
	// otherwise a changed/omitted identity could leave stale approved hashes that
	// re-promote when the old manifest returns.
	runtimePolicyActive, runtimeOK, mismatches :=
		s.deps.ApplyRuntime(provider, resp)
	if runtimePolicyActive && !runtimeOK {
		// Log detailed mismatch info for debugging outages.
		mismatchDetails := make([]string, 0, len(mismatches))
		for _, m := range mismatches {
			mismatchDetails = append(mismatchDetails, m.Component+"="+m.Got)
		}
		s.deps.Logger().Warn("provider runtime integrity mismatch in challenge response — excluding from routing",
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
					s.deps.Logger().Debug("failed to enqueue runtime status to provider", "provider_id", provider.ID, "error", err)
					s.deps.Incr("provider.enqueue_failed", []string{"msg:runtime_status"})
				}
			}
		}
		_ = s.deps.Registry().ReconcileAttestedRuntimeCapabilities(providerID)
		return
	}

	version, versionAllowed := s.deps.ApplyMinimumVersion(provider)
	if !versionAllowed {
		s.deps.Logger().Warn("provider version below minimum during challenge revalidation — excluding from routing",
			"provider_id", providerID,
			"version", version,
			"min_version", s.deps.MinimumVersion(),
		)
		s.deps.Incr("provider_version_below_minimum", []string{"gate:challenge_revalidation", "version:" + version})
		_ = s.deps.Registry().ReconcileAttestedRuntimeCapabilities(providerID)
		return
	}

	if err := s.deps.Registry().ReconcileAttestedRuntimeCapabilities(providerID); err != nil {
		s.deps.Logger().Warn("provider live runtime claims no longer match attestation",
			"provider_id", providerID,
			"reason", err.Error(),
		)
		s.deps.Registry().MarkUntrusted(providerID)
		s.RecordFailure(providerID, "attested runtime claims mismatch")
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

	releaseFact := trustreuse.ReleaseTransition{}
	if fact, evidence, ok := s.deps.DeriveReleaseTransition(
		provider, resp, statusFieldsTrusted,
	); ok {
		if provider.GrantApplicationEvidenceIfNotUntrusted(evidence) {
			releaseFact = fact
			s.deps.CodeMetric("direct_application_proof")
		} else {
			// Derivation succeeded but installation lost a race (policy
			// generation refresh or identity/token change between derive and
			// grant). The derive-side "granted" counter alone would make this
			// look successful; the distinct outcome keeps shadow-rollout
			// counters honest. The grant path already kicks a re-challenge.
			s.deps.EvidenceOutcome("grant_lost_race")
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
	s.deps.Registry().UpdateModelWeightHashes(providerID, resp.ModelHashes)

	recovered := s.deps.Registry().RecordChallengeSuccess(providerID)
	if recovered {
		// The provider was transiently untrusted and is now back online. Push a
		// fresh status so its locally persisted operator state reflects recovery.
		provider.Mu().Lock()
		trustLevel := provider.TrustLevel
		provider.Mu().Unlock()
		s.deps.SendStatus(provider, trustLevel, "online", "recovered after transient deroute")
	}
	s.deps.Incr("attestation.challenges", []string{"outcome:passed"})
	s.deps.Logger().Info("attestation challenge verified",
		"provider_id", providerID,
		"sip_enabled", resp.SIPEnabled,
		"secure_boot_enabled", resp.SecureBootEnabled,
		"rdma_disabled", resp.RDMADisabled,
		"binary_hash", resp.BinaryHash,
		"active_model_hash", resp.ActiveModelHash,
		"model_hashes_count", len(resp.ModelHashes),
	)
	for modelID, hash := range resp.ModelHashes {
		s.deps.Logger().Info("model weight hash verified",
			"provider_id", providerID,
			"model_id", modelID,
			"weight_hash", hash,
		)
	}

	// MDM SecurityInfo work is driven only by the existing scheduler. The
	// periodic direct challenge refreshes live posture but never creates another
	// MDM command; reboot/reconnect instead rebinds the durable singleflight job.
	provider.Mu().Lock()
	trustLevel := provider.TrustLevel
	provider.Mu().Unlock()

	if trustLevel == registry.TrustSelfSigned {
		// Trust-reuse fast-skip: the live SE challenge above just
		// re-proved this connection's identity + posture. If this device recently
		// passed a FULL live MDM verification (a fresh trust-reuse record) and the
		// fresh SIGNED challenge re-proves the SAME identity, an unchanged binary,
		// and good posture within the window, grant hardware now and complete the
		// scheduler fallback before any worker/command. The live SE challenge
		// always ran; any gate miss falls through to durable live verification.
		if s.deps.TryReuse(providerID, provider, resp, statusFieldsTrusted, releaseFact) {
			// The fast-skip granted hardware WITHOUT running the full live MDM verify,
			// so verifyAppleDeviceAttestation never ran on this connection. Reuse the
			// durable MDA proof (re-verified locally against Apple's root + re-bound to
			// this SE key) so a restart keeps mda_verified green with zero MDM/APNs
			// traffic — the whole point of the fast-skip is to avoid that round-trip.
			if ar := provider.GetAttestationResult(); ar != nil {
				s.deps.AttachMDA(providerID, provider, *ar)
			}
			if s.deps.Scheduler() != nil {
				s.deps.Scheduler().ChallengeSettled(provider, true)
			}
			// The fast-skip just granted hardware, so this provider is
			// freshly routable — drain any queued requests now instead of waiting for
			// the next heartbeat / 120s queue timeout. Off the challenge goroutine,
			// mirroring the code-attest / MDM hardware-grant drain.
			saferun.Go(s.deps.Logger(), "trustReuseDrain", func() {
				s.deps.Registry().DrainQueuedRequestsForProviderWithReason(provider, registry.DrainTriggerChallenge)
			})
		} else {
			// Fast-skip missed. The submit-time refresh classification (a
			// fresh-looking or continuity-covered record) is now known to be
			// optimistic — the read gate refused it — so promote the job to
			// first/expired before settling: the live MDM attempt must start
			// inside the 120s dispatch-queue deadline, not on the refresh
			// spread. Durable due time, priority, and retry stage then decide
			// when SecurityInfo runs.
			if s.deps.Scheduler() != nil {
				s.deps.Scheduler().PromoteFailedFastSkip(provider)
				s.deps.Scheduler().ChallengeSettled(provider, false)
			}
		}
	}
}
