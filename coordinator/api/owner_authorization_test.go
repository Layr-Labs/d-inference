package api

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestRestartStatusReportsOwnerAuthorizationWithoutPublicGrant(t *testing.T) {
	for _, private := range []bool{false, true} {
		s, p, _ := newAuthorizationFixture(t)
		s.registry.ClearAppAttestServingAuthorization(p)
		p.Mu().Lock()
		p.PrivateOnly = private
		p.ChallengeVerifiedSIP = true
		p.Mu().Unlock()
		s.registry.RecordChallengeSuccess(p.ID)
		if s.registry.ProviderLegacyServingAuthorized(p) {
			t.Fatal("fixture unexpectedly passed public trust floor")
		}
		status := s.providerServingAuthorizationStatus(p)
		if status == nil || status.Path != "self_route" || status.SessionID != p.ID {
			t.Fatalf("owner status: %+v", status)
		}
		p.Mu().Lock()
		p.RuntimeVerified = false
		p.Mu().Unlock()
		if status = s.providerServingAuthorizationStatus(p); status != nil && status.Path == "self_route" {
			t.Fatal("runtime failure got owner authorization")
		}
		p.Mu().Lock()
		p.RuntimeVerified = true
		p.AccountID = ""
		p.Mu().Unlock()
		if s.registry.ProviderOwnerServingAuthorized(p) {
			t.Fatal("unowned provider got self-route authorization")
		}
		p.Mu().Lock()
		p.AccountID = "account"
		p.Status = registry.StatusUntrusted
		p.Mu().Unlock()
		if s.registry.ProviderOwnerServingAuthorized(p) {
			t.Fatal("untrusted provider got self-route authorization")
		}
	}
}
