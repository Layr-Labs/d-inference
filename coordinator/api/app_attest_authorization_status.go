package api

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func (s *Server) providerServingAuthorizationStatus(p *registry.Provider) *protocol.ProviderServingAuthorization {
	if !s.appAttestShadow.ServingEnabled || p == nil {
		return nil
	}
	result := &protocol.ProviderServingAuthorization{Protocol: 1, AppAttestAvailable: s.appAttestShadow.Environment == "production", Path: "none", Reason: "app_attest_qualification_required", SessionID: p.ID}
	_, result.MachineID = p.GetVerifiedMachineIdentity()
	if reason := s.registry.ProviderServingDenialReason(p); reason != "" {
		result.Reason = reason
		return result
	}
	if lease, ok := s.registry.ProviderServingAuthorization(p); ok {
		result.Path, result.Reason, result.ExpiresAt = "app_attest", "app_attest_verified", lease.ValidUntil.Unix()
		result.MachineID = lease.MachineID
		result.MDMRemovalReady = s.appAttestShadow.MDMRemovalEnabled
	} else if s.registry.ProviderLegacyServingAuthorized(p) {
		result.Path, result.Reason = "legacy", "legacy_verification_active"
	}
	return result
}

func (s *Server) sendAppAttestAuthorizationStatus(p *registry.Provider) {
	if !s.appAttestShadow.ServingEnabled || p == nil {
		return
	}
	status := string(p.GetStatus())
	if s.registry.ProviderServingDenialReason(p) != "" {
		status = string(registry.StatusUntrusted)
	}
	if status != string(registry.StatusUntrusted) && status != string(registry.StatusOffline) {
		status = "online"
	}
	s.sendTrustStatus(p, p.GetTrustLevel(), status, "Provider authorization updated")
}
