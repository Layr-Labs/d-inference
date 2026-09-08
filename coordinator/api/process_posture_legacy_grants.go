package api

import (
	"bytes"
	"crypto/sha256"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// legacyGrantSecurityInfo preserves the pre-policy admission path in shadow.
// The candidate observer is separate and cannot influence this result.
func (s *Server) legacyGrantSecurityInfo(p *registry.Provider, ar attestation.VerificationResult, udid string, late bool) bool {
	if s.processPostureEnforced() {
		return false
	}
	binary := providerApplicationBinaryHash(p, ar.PublicKey, ar.BinaryHash)
	var granted bool
	if late {
		granted = s.recordLateTrustReuse(p, ar.PublicKey, ar.SerialNumber, binary, true, true, udid)
	} else {
		granted = s.recordTrustReuse(p, ar.PublicKey, ar.SerialNumber, binary, true, true, udid)
	}
	if !granted {
		return false
	}
	p.SetMDMFailureReason("")
	reason, outcome := "MDM verification passed", "granted"
	if late {
		reason, outcome = "MDM verification passed (late SecurityInfo)", "granted-late"
		if s.metrics != nil {
			s.metrics.IncCounter("mdm_late_securityinfo_upgrade_total")
		}
	}
	s.sendTrustStatus(p, registry.TrustHardware, "online", reason)
	s.registry.PersistProvider(p)
	s.ddIncr("mdm.verification", []string{"outcome:" + outcome})
	return true
}

func (s *Server) legacyValidateLateMDA(ar attestation.VerificationResult, udid string, proof *attestation.MDAResult) bool {
	if s.processPostureEnforced() {
		return false
	}
	if proof == nil || !proof.Valid {
		if s.mdmScheduler != nil {
			s.mdmScheduler.metricCounter("mda_verification_total", "outcome", "invalid")
		}
		return false
	}
	want := sha256.Sum256([]byte(ar.PublicKey))
	if len(proof.FreshnessCode) == 0 || !bytes.Equal(proof.FreshnessCode, want[:]) ||
		(proof.DeviceSerial != "" && proof.DeviceSerial != ar.SerialNumber) ||
		(proof.DeviceUDID != "" && proof.DeviceUDID != udid) {
		if s.mdmScheduler != nil {
			s.mdmScheduler.metricCounter("mda_verification_total", "outcome", "binding_mismatch")
		}
		return false
	}
	return true
}
