package api

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Call only after building the live snapshot and releasing the provider lock:
// ProviderServingAuthorization takes registry and provider locks itself.
func (s *Server) attachMyProviderAuthorization(mp *myProvider, live *registry.Provider, account string) {
	mp.AppAttestAuthorized, mp.AuthorizationExpiresAt = false, 0
	mp.Verification = s.registry.ProviderVerification(nil)
	if live == nil || mp.AccountID != account {
		return
	}
	mp.Verification = s.registry.ProviderVerification(live)
	// Connected, untrusted machines still have a live verification verdict
	// (including revocation). Online gates serving permission, not diagnostics.
	if !mp.Online {
		return
	}
	lease, valid := s.registry.ProviderServingAuthorization(live)
	if !valid || lease.AccountID != account || lease.Endpoint != mp.ProviderKey {
		return
	}
	mp.AppAttestAuthorized = true
	mp.AuthorizationExpiresAt = lease.ValidUntil.Unix()
}

func myProviderHasAppAttestAuthorization(mp *myProvider, now time.Time) bool {
	return mp.Online && (mp.Status == "online" || mp.Status == "serving") &&
		mp.AppAttestAuthorized && mp.AuthorizationExpiresAt > now.Unix()
}
