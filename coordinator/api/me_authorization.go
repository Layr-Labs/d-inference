package api

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Call only after building the live snapshot and releasing the provider lock.
// The verdict and compatibility fields use one registry/provider observation.
func (s *Server) attachMyProviderAuthorization(mp *myProvider, live *registry.Provider, account string) {
	mp.AppAttestAuthorized, mp.AuthorizationExpiresAt = false, 0
	mp.Verification = s.registry.ProviderVerification(nil)
	if live == nil || mp.AccountID != account {
		return
	}
	snapshot := s.registry.ProviderVerificationAndAuthorization(live)
	if snapshot.AccountID != account {
		// A live connection may change owners after the earlier fleet merge.
		// Do not expose the new owner's verification or lease to the former account.
		mp.Status, mp.Online = "offline", false
		return
	}
	mp.Verification = snapshot.Verification
	mp.Status = string(snapshot.Status)
	mp.Online = snapshot.Status != registry.StatusOffline && snapshot.Status != registry.StatusUntrusted
	// Connected, untrusted machines still have a live verification verdict
	// (including revocation). A verified verdict already passed online and
	// endpoint gates at the same instant as these compatibility fields.
	if !snapshot.Authorized {
		return
	}
	mp.AppAttestAuthorized = true
	mp.AuthorizationExpiresAt = snapshot.AuthorizationExpiresAt
}

func myProviderHasAppAttestAuthorization(mp *myProvider, now time.Time) bool {
	return mp.Online && (mp.Status == "online" || mp.Status == "serving") &&
		mp.AppAttestAuthorized && mp.AuthorizationExpiresAt > now.Unix()
}
