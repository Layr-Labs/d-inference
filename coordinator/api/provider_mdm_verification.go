package api

import (
	"context"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/mdm"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

type mdmVerifyOutcome int

const (
	mdmVerifyGranted mdmVerifyOutcome = iota
	mdmVerifyTransient
	mdmVerifyTerminal
)

func (s *Server) verifyProviderViaMDM(ctx context.Context, providerID string, provider *registry.Provider, attestResult attestation.VerificationResult) mdmVerifyOutcome {
	if !attestResult.Valid {
		s.logger.Warn("refusing MDM verification — SE attestation not valid",
			"provider_id", providerID, "serial_number", attestResult.SerialNumber)
		return mdmVerifyTransient
	}

	s.logger.Info("starting MDM verification",
		"provider_id", providerID,
		"serial_number", attestResult.SerialNumber,
	)

	mdmResult, err := s.mdmClient.VerifyProvider(
		ctx,
		attestResult.SerialNumber,
		attestResult.SIPEnabled,
		attestResult.SecureBootEnabled,
	)
	if err != nil {
		s.logger.Error("MDM verification error",
			"provider_id", providerID,
			"error", err,
		)
		provider.SetMDMFailureReason("error")
		s.ddIncr("mdm.verification", []string{"outcome:error"})
		return mdmVerifyTransient
	}

	if !mdmResult.DeviceEnrolled {
		reason := "found-not-enrolled"
		switch {
		case strings.Contains(mdmResult.Error, "lookup failed"):
			reason = "error"
		case strings.Contains(mdmResult.Error, "not found"):
			reason = "device-not-found"
		}
		s.logger.Warn("provider not MDM-verified — staying at self_signed trust",
			"provider_id", providerID,
			"serial_number", attestResult.SerialNumber,
			"reason", reason,
			"error", mdmResult.Error,
		)
		provider.SetMDMFailureReason(reason)
		s.ddIncr("mdm.verification", []string{"outcome:" + reason})
		return mdmVerifyTransient
	}

	if mdmResult.Error != "" {
		if !mdmResult.SecurityMismatch {
			reason := "error"
			if strings.Contains(mdmResult.Error, "timeout") {
				reason = "securityinfo-timeout"
			}
			s.logger.Warn("MDM verification did not complete — staying at current trust level",
				"provider_id", providerID,
				"reason", reason,
				"error", mdmResult.Error,
			)
			provider.SetMDMFailureReason(reason)
			s.ddIncr("mdm.verification", []string{"outcome:" + reason})
			return mdmVerifyTransient
		}
		s.logger.Warn("MDM verification failed — marking provider untrusted",
			"provider_id", providerID,
			"error", mdmResult.Error,
			"mdm_sip", mdmResult.MDMSIPEnabled,
			"mdm_secure_boot", mdmResult.MDMSecureBootFull,
			"sip_match", mdmResult.SIPMatch,
			"secure_boot_match", mdmResult.SecureBootMatch,
		)
		provider.SetMDMFailureReason("posture-mismatch")
		s.ddIncr("mdm.verification", []string{"outcome:posture-mismatch"})
		s.registry.MarkUntrusted(providerID)
		return mdmVerifyTerminal
	}

	if ctx.Err() != nil {
		provider.SetMDMFailureReason("securityinfo-timeout")
		return mdmVerifyTransient
	}

	if !provider.GrantHardwareIfNotUntrusted() {
		s.ddIncr("mdm.verification", []string{"outcome:deferred-untrusted"})
		return mdmVerifyTransient
	}
	provider.SetMDMFailureReason("")
	s.sendTrustStatus(provider, registry.TrustHardware, "online", "MDM verification passed")
	s.ddIncr("mdm.verification", []string{"outcome:granted"})
	s.logger.Info("MDM verification passed — upgraded to hardware trust",
		"provider_id", providerID,
		"serial_number", attestResult.SerialNumber,
		"mdm_sip", mdmResult.MDMSIPEnabled,
		"mdm_secure_boot", mdmResult.MDMSecureBootFull,
		"mdm_auth_root_volume", mdmResult.MDMAuthRootVolume,
	)
	s.registry.PersistProvider(provider)
	s.verifyAppleDeviceAttestation(ctx, providerID, provider, attestResult, mdmResult.UDID)
	return mdmVerifyGranted
}

func (s *Server) ApplyLateSecurityInfo(udid string, info *mdm.SecurityInfoResponse) {
	if s.mdmClient == nil || info == nil {
		return
	}
	if !info.SystemIntegrityProtectionEnabled || info.SecureBootLevel != "full" {
		return
	}
	type candidate struct {
		provider *registry.Provider
		serial   string
	}
	var candidates []candidate
	s.registry.ForEachProvider(func(p *registry.Provider) {
		p.Mu().Lock()
		trust := p.TrustLevel
		valid := p.AttestationResult != nil && p.AttestationResult.Valid
		serial := ""
		if p.AttestationResult != nil {
			serial = p.AttestationResult.SerialNumber
		}
		p.Mu().Unlock()
		if trust == registry.TrustSelfSigned && valid && serial != "" {
			candidates = append(candidates, candidate{provider: p, serial: serial})
		}
	})
	for _, c := range candidates {
		dev, _ := s.mdmClient.LookupDevice(context.Background(), c.serial)
		if dev == nil || dev.UDID != udid {
			continue
		}
		if !c.provider.GrantHardwareIfNotUntrusted() {
			continue
		}
		c.provider.SetMDMFailureReason("")
		s.sendTrustStatus(c.provider, registry.TrustHardware, "online", "MDM verification passed (late SecurityInfo)")
		if s.metrics != nil {
			s.metrics.IncCounter("mdm_late_securityinfo_upgrade_total")
		}
		s.ddIncr("mdm.verification", []string{"outcome:granted-late"})
		s.logger.Info("late SecurityInfo arrival — upgraded provider to hardware trust",
			"provider_id", c.provider.ID,
			"serial", c.serial,
			"udid", udid,
		)
		s.registry.PersistProvider(c.provider)
	}
}

func (s *Server) mdmVerificationLoop(ctx context.Context, providerID string, provider *registry.Provider) {
	if s.mdmClient == nil {
		return
	}
	provider.Mu().Lock()
	var result *attestation.VerificationResult
	if provider.AttestationResult != nil {
		r := *provider.AttestationResult
		result = &r
	}
	provider.Mu().Unlock()
	if result == nil || !result.Valid || result.SerialNumber == "" {
		return
	}

	backoff := []time.Duration{2 * time.Minute, 6 * time.Minute}
	const steadyInterval = 15 * time.Minute

	for attempt := 0; ; attempt++ {
		if provider.GetTrustLevel() == registry.TrustHardware {
			return
		}
		if provider.ChallengeShouldStop() {
			return
		}
		switch s.verifyProviderViaMDM(ctx, providerID, provider, *result) {
		case mdmVerifyGranted, mdmVerifyTerminal:
			return
		}
		d := steadyInterval
		if attempt < len(backoff) {
			d = backoff[attempt]
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(d):
		}
	}
}
