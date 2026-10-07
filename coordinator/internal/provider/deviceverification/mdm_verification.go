package deviceverification

import (
	"context"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	identityevidence "github.com/eigeninference/d-inference/coordinator/internal/provider/identity/evidence"
	"github.com/eigeninference/d-inference/coordinator/mdm"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type Outcome int

const (
	Granted   Outcome = iota // hardware trust granted — stop
	Transient                // not-enrolled / not-found / timeout / error — retry
	Terminal                 // posture mismatch (hard untrust) — stop
)

// verifyProviderViaMDM runs one MDM SecurityInfo attempt and, on success,
// upgrades the live provider to hardware trust. It records a bucketed
// MDMFailureReason and returns a fixed outcome to the scheduler. Transient
// transport/enrollment failures never hard-untrust; proven posture mismatch does.
func (s *Verifier) VerifyProviderViaMDM(ctx context.Context, providerID string, provider *registry.Provider, attestResult attestation.VerificationResult) Outcome {
	if s.legacyMDMAllowed != nil && !s.legacyMDMAllowed(provider) {
		provider.SetMDMFailureReason("app-attest-required")
		return Terminal
	}
	// Never let MDM promote a provider whose Secure Enclave attestation is not
	// valid. VerifyProviderAttestation stores an AttestationResult even for an
	// invalid attestation (and, in Open Mode, leaves the provider connected), so
	// without this a later SecurityInfo success could grant hardware to a provider
	// whose SE attestation / encryption-key binding failed. result.Valid==true
	// implies both passed (VerifyProviderAttestation returns early otherwise). The
	// scheduler also gates on this; this is the authoritative backstop.
	if !attestResult.Valid {
		s.logger.Warn("refusing MDM verification: SE attestation not valid")
		return Transient
	}

	s.logger.Info("starting scheduled MDM verification")

	var (
		observeUDID    func(string)
		observeCommand func(string, string)
	)
	if metadata, ok := ctx.Value(mdmSchedulerAttemptContextKey{}).(*mdmSchedulerAttemptMetadata); ok {
		observeUDID = func(udid string) {
			metadata.udid = udid
			if s.verificationBackend.
				Scheduler !=
				nil {
				s.verificationBackend.
					Scheduler.
					ObserveAttemptUDID(provider, udid)
			}
		}
		observeCommand = func(udid, commandUUID string) {
			if s.verificationBackend.
				Scheduler !=
				nil {
				s.verificationBackend.
					Scheduler.
					ObserveAttemptCommand(
						provider, store.VerificationTaskSecurityInfo,
						udid, commandUUID,
					)
			}
		}
	}
	mdmResult, err := s.verificationBackend.
		Client.
		VerifyProviderWithUDIDObserver(
			ctx, attestResult.SerialNumber, attestResult.SIPEnabled,
			attestResult.SecureBootEnabled, observeUDID, observeCommand,
		)
	if err != nil {
		s.logger.Error("MDM verification error", "error", err)
		provider.SetMDMFailureReason("error")
		s.observation.Incr("mdm.verification", []string{"outcome:error"})
		return Transient
	}

	if !mdmResult.DeviceEnrolled {
		// A MicroMDM lookup/transport failure (500, network error) also returns
		// DeviceEnrolled=false — but the device may well be enrolled; we just
		// couldn't ask. Bucket that as "error" (MDM-side outage) so the stuck-cohort
		// gauge doesn't point operators at provider enrollment during an MDM outage.
		// Otherwise distinguish "no record of this serial" (profile never installed /
		// check-in never reached the server) from "record exists but enrollment
		// didn't complete" — different provider-side fixes.
		reason := "found-not-enrolled"
		switch {
		case strings.Contains(mdmResult.Error, "lookup failed"):
			reason = "error"
		case strings.Contains(mdmResult.Error, "not found"):
			reason = "device-not-found"
		}
		s.logger.Warn("provider not MDM-verified; retaining current trust",
			"reason", reason,
			"error", mdmResult.Error,
		)
		provider.SetMDMFailureReason(reason)
		s.observation.Incr("mdm.verification", []string{"outcome:" + reason})
		return Transient
	}

	if mdmResult.Error != "" {
		// Hard untrust ONLY for a genuine posture mismatch proven by a received
		// SecurityInfo response (SecurityMismatch). Everything else with a non-empty
		// error — a SecurityInfo timeout, a MicroMDM command-send/transport failure,
		// a decode error, or a context cancellation on disconnect — is a "could not
		// complete the check" condition: keep the provider at its current trust
		// level (self_signed) and let the loop retry. Treating a transient MicroMDM
		// API hiccup as a posture mismatch would wrongly hard-untrust an enrolled,
		// genuinely-secure box.
		if !mdmResult.SecurityMismatch {
			reason := "error"
			if strings.Contains(mdmResult.Error, "timeout") {
				reason = "securityinfo-timeout"
			}
			s.logger.Warn("MDM verification did not complete; retaining current trust",
				"reason", reason,
				"error", mdmResult.Error,
			)
			provider.SetMDMFailureReason(reason)
			s.observation.Incr("mdm.verification", []string{"outcome:" + reason})
			return Transient
		}
		// A real posture mismatch (SIP disabled, Secure Boot not full, attestation
		// disagrees with MDM) IS evidence of a problem — hard untrust, no retry.
		s.logger.Warn("MDM posture verification failed; marking provider untrusted",
			"error", mdmResult.Error,
			"mdm_sip", mdmResult.MDMSIPEnabled,
			"mdm_secure_boot", mdmResult.MDMSecureBootFull,
			"sip_match", mdmResult.SIPMatch,
			"secure_boot_match", mdmResult.SecureBootMatch,
		)
		provider.SetMDMFailureReason("posture-mismatch")
		s.observation.Incr("mdm.verification", []string{"outcome:posture-mismatch"})
		s.registry.MarkUntrusted(providerID)
		return Terminal
	}

	// If the connection went away while we were waiting on SecurityInfo, do NOT
	// mutate/persist trust for a provider that is no longer here — the next
	// connection re-verifies from scratch (RestoreProviderState caps to
	// self_signed). Treat as transient; the loop's ctx.Done will end it.
	if ctx.Err() != nil {
		provider.SetMDMFailureReason("securityinfo-timeout")
		return Transient
	}
	binaryHash := identityevidence.BinaryHash(
		provider, attestResult.PublicKey, attestResult.BinaryHash,
	)

	// Durable revocation is authoritative. Persist/recover the verified device
	// evidence at the expected generation before touching live hardware trust;
	// then the helper atomically rechecks the provider epoch/status while granting.
	if !s.authority.RecordTrustReuse(
		provider,
		attestResult.PublicKey,
		attestResult.SerialNumber,
		binaryHash,
		mdmResult.MDMSIPEnabled,
		mdmResult.MDMSecureBootFull,
		mdmResult.UDID,
	) {
		s.observation.Incr("mdm.verification", []string{"outcome:deferred-revocation-cas"})
		return Transient
	}
	provider.SetMDMFailureReason("")
	s.sendTrustStatus(provider, registry.TrustHardware, "online", "MDM verification passed")
	s.observation.Incr("mdm.verification", []string{"outcome:granted"})
	s.logger.Info("MDM verification passed; upgraded live provider to hardware trust",
		"mdm_sip", mdmResult.MDMSIPEnabled,
		"mdm_secure_boot", mdmResult.MDMSecureBootFull,
		"mdm_auth_root_volume", mdmResult.MDMAuthRootVolume,
	)
	s.registry.PersistProvider(provider)

	// Direct attempt-level callers retain the historical synchronous MDA behavior.
	// Scheduler workers enqueue MDA behind the same global budget instead.
	if _, scheduled := ctx.Value(mdmSchedulerAttemptContextKey{}).(*mdmSchedulerAttemptMetadata); !scheduled {
		s.VerifyAppleDeviceAttestation(ctx, providerID, provider, attestResult, mdmResult.UDID)
	}
	return Granted
}

// ApplyLateSecurityInfo accepts a delayed response only for the exact current
// scheduler binding that issued the command and has completed the current
// connection's phase-1 challenge. Unowned or stale-generation callbacks are
// dropped; they are never bearer credentials for a fleet-wide provider lookup.
func (s *Verifier) ApplyLateSecurityInfo(
	udid, commandUUID string,
	info *mdm.SecurityInfoResponse,
) {
	if s.verificationBackend.
		Client ==
		nil || info == nil || commandUUID == "" {
		return
	}
	securityOK := info.SystemIntegrityProtectionEnabled && info.SecureBootLevel == "full"
	if s.verificationBackend.
		Scheduler ==
		nil {
		return
	}
	binding := s.verificationBackend.
		Scheduler.
		ApplyLateSecurityInfo(
			udid, commandUUID, securityOK,
		)
	if binding == nil {
		return
	}
	if s.legacyMDMAllowed != nil && !s.legacyMDMAllowed(binding.Provider) {
		return
	}
	if !securityOK {
		binding.Provider.SetMDMFailureReason("posture-mismatch")
		s.registry.MarkUntrusted(binding.ProviderID)
		s.verificationBackend.
			Scheduler.
			RejectLateSecurityInfo(
				*binding, udid, commandUUID,
			)
		return
	}
	ar := binding.Attestation
	binaryHash := identityevidence.BinaryHash(
		binding.Provider, ar.PublicKey, ar.BinaryHash,
	)
	if !s.authority.RecordLateTrustReuse(
		binding.Provider, ar.PublicKey, ar.SerialNumber, binaryHash,
		true, true, udid,
	) {
		return
	}
	binding.Provider.SetMDMFailureReason("")
	s.sendTrustStatus(binding.Provider, registry.TrustHardware, "online", "MDM verification passed (late SecurityInfo)")
	s.registry.PersistProvider(binding.Provider)
	if s.observation.Metrics() != nil {
		s.observation.Metrics().IncCounter("mdm_late_securityinfo_upgrade_total")
	}
	s.observation.Incr("mdm.verification", []string{"outcome:granted-late"})
	s.verificationBackend.
		Scheduler.
		CompleteLateSecurityInfo(
			*binding, udid, commandUUID,
		)
}

// stageDurableMDAChain recovers a previously-earned Apple MDA cert chain from the
// store (by serial) and stages it on the provider as a reuse candidate for this
// reconnect. A missing record / chain or a read error stages nothing, and a
// fresh attestation is requested. This read is independent of counter recovery.
