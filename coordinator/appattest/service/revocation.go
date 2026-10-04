package service

import "github.com/eigeninference/d-inference/coordinator/internal/appattest/authorization"

const RevocationFreshness = authorization.RevocationFreshness

// RevokeCredential invalidates live state after the HTTP adapter has durably
// written an authenticated revocation. No storage write or HTTP auth lives here.
func (s *Service) RevokeCredential(keyID string) {
	if a := s.authorizer; a != nil {
		a.Revoke(keyID)
	} else {
		s.registry.RevokeAppAttestCredential(keyID)
	}
}
