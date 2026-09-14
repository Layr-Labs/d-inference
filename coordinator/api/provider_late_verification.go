package api

import (
	"github.com/eigeninference/d-inference/coordinator/mdm"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// ApplyLateSecurityInfo accepts a delayed response only for the exact current
// scheduler binding that issued the command and has completed the current
// connection's phase-1 challenge. Unowned or stale-generation callbacks are
// dropped; they are never bearer credentials for a fleet-wide provider lookup.
func (s *Server) ApplyLateSecurityInfo(
	udid, commandUUID string,
	info *mdm.SecurityInfoResponse,
) {
	if s.mdmClient == nil || info == nil || commandUUID == "" {
		return
	}
	securityOK := info.SystemIntegrityProtectionEnabled && info.SecureBootLevel == "full"
	if s.mdmScheduler == nil {
		return
	}
	binding := s.mdmScheduler.ApplyLateSecurityInfo(
		udid, commandUUID, securityOK,
	)
	if binding == nil {
		return
	}
	target := binding.Target()
	if !securityOK {
		target.Provider.SetMDMFailureReason("posture-mismatch")
		s.registry.MarkUntrusted(target.ProviderID)
		s.mdmScheduler.RejectLateSecurityInfo(
			*binding, udid, commandUUID,
		)
		return
	}
	ar := target.Attestation
	binaryHash := providerApplicationBinaryHash(
		target.Provider, ar.PublicKey, ar.BinaryHash,
	)
	if !s.recordLateTrustReuse(
		target.Provider, ar.PublicKey, ar.SerialNumber, binaryHash,
		true, true, udid,
	) {
		return
	}
	target.Provider.SetMDMFailureReason("")
	s.sendTrustStatus(target.Provider, registry.TrustHardware, "online", "MDM verification passed (late SecurityInfo)")
	s.registry.PersistProvider(target.Provider)
	if s.metrics != nil {
		s.metrics.IncCounter("mdm_late_securityinfo_upgrade_total")
	}
	s.ddIncr("mdm.verification", []string{"outcome:granted-late"})
	s.mdmScheduler.CompleteLateSecurityInfo(
		*binding, udid, commandUUID,
	)
}

// ApplyLateMDA attaches a late Apple response only to the exact scheduler job
// that issued work for this UDID. Unowned and stale-generation callbacks are
// dropped without any fleet-wide fallback.
func (s *Server) ApplyLateMDA(
	udid, commandUUID string,
	certChain [][]byte,
) {
	if s == nil || s.mdmScheduler == nil ||
		udid == "" || commandUUID == "" || len(certChain) == 0 {
		return
	}
	s.mdmScheduler.ApplyLateMDA(udid, commandUUID, certChain)
}
