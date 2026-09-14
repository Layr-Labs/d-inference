package verification

import (
	"context"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// VerifySecurityInfo runs one MDM SecurityInfo attempt and, on success,
// upgrades the live provider to hardware trust. It records a bucketed
// MDMFailureReason and returns a fixed outcome to the scheduler. Transient
// transport/enrollment failures never hard-untrust; proven posture mismatch does.
func (s *Verifier) VerifySecurityInfo(ctx context.Context, providerID string, provider *registry.Provider, attestResult attestation.VerificationResult) Outcome {
	// Never let MDM promote a provider whose Secure Enclave attestation is not
	// valid. VerifyRegistration stores an AttestationResult even for an
	// invalid attestation (and, in Open Mode, leaves the provider connected), so
	// without this a later SecurityInfo success could grant hardware to a provider
	// whose SE attestation / encryption-key binding failed. result.Valid==true
	// implies both passed (VerifyRegistration returns early otherwise). The
	// scheduler also gates on this; this is the authoritative backstop.
	if !attestResult.Valid {
		s.deps.Logger().Warn("refusing MDM verification: SE attestation not valid")
		return Transient
	}

	s.deps.Logger().Info("starting scheduled MDM verification")

	var (
		observeUDID    func(string)
		observeCommand func(string, string)
	)
	if metadata, ok := scheduledAttempt(ctx); ok {
		observeUDID = func(udid string) {
			metadata.udid = udid
			if s.deps.Scheduler() != nil {
				s.deps.Scheduler().ObserveAttemptUDID(provider, udid)
			}
		}
		observeCommand = func(udid, commandUUID string) {
			if s.deps.Scheduler() != nil {
				s.deps.Scheduler().ObserveAttemptCommand(
					provider, store.VerificationTaskSecurityInfo,
					udid, commandUUID,
				)
			}
		}
	}
	mdmResult, err := s.deps.MDM().VerifyProviderWithUDIDObserver(
		ctx, attestResult.SerialNumber, attestResult.SIPEnabled,
		attestResult.SecureBootEnabled, observeUDID, observeCommand,
	)
	if err != nil {
		s.deps.Logger().Error("MDM verification error", "error", err)
		provider.SetMDMFailureReason("error")
		s.deps.Incr("mdm.verification", []string{"outcome:error"})
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
		s.deps.Logger().Warn("provider not MDM-verified; retaining current trust",
			"reason", reason,
			"error", mdmResult.Error,
		)
		provider.SetMDMFailureReason(reason)
		s.deps.Incr("mdm.verification", []string{"outcome:" + reason})
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
			s.deps.Logger().Warn("MDM verification did not complete; retaining current trust",
				"reason", reason,
				"error", mdmResult.Error,
			)
			provider.SetMDMFailureReason(reason)
			s.deps.Incr("mdm.verification", []string{"outcome:" + reason})
			return Transient
		}
		// A real posture mismatch (SIP disabled, Secure Boot not full, attestation
		// disagrees with MDM) IS evidence of a problem — hard untrust, no retry.
		s.deps.Logger().Warn("MDM posture verification failed; marking provider untrusted",
			"error", mdmResult.Error,
			"mdm_sip", mdmResult.MDMSIPEnabled,
			"mdm_secure_boot", mdmResult.MDMSecureBootFull,
			"sip_match", mdmResult.SIPMatch,
			"secure_boot_match", mdmResult.SecureBootMatch,
		)
		provider.SetMDMFailureReason("posture-mismatch")
		s.deps.Incr("mdm.verification", []string{"outcome:posture-mismatch"})
		s.deps.Registry().MarkUntrusted(providerID)
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
	binaryHash := s.deps.ApplicationBinaryHash(
		provider, attestResult.PublicKey, attestResult.BinaryHash,
	)

	// Durable revocation is authoritative. Persist/recover the verified device
	// evidence at the expected generation before touching live hardware trust;
	// then the helper atomically rechecks the provider epoch/status while granting.
	if !s.deps.RecordTrustReuse(
		provider,
		attestResult.PublicKey,
		attestResult.SerialNumber,
		binaryHash,
		mdmResult.MDMSIPEnabled,
		mdmResult.MDMSecureBootFull,
		mdmResult.UDID,
	) {
		s.deps.Incr("mdm.verification", []string{"outcome:deferred-revocation-cas"})
		return Transient
	}
	provider.SetMDMFailureReason("")
	s.deps.SendStatus(provider, registry.TrustHardware, "online", "MDM verification passed")
	s.deps.Incr("mdm.verification", []string{"outcome:granted"})
	s.deps.Logger().Info("MDM verification passed; upgraded live provider to hardware trust",
		"mdm_sip", mdmResult.MDMSIPEnabled,
		"mdm_secure_boot", mdmResult.MDMSecureBootFull,
		"mdm_auth_root_volume", mdmResult.MDMAuthRootVolume,
	)
	s.deps.Registry().PersistProvider(provider)

	// Direct attempt-level callers retain the historical synchronous MDA behavior.
	// Scheduler workers enqueue MDA behind the same global budget instead.
	if _, scheduled := scheduledAttempt(ctx); !scheduled {
		s.VerifyMDA(ctx, providerID, provider, attestResult, mdmResult.UDID)
	}
	return Granted
}
