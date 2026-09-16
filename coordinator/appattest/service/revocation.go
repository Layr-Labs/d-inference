package service

const RevocationFreshness = appAttestRevocationFreshness

// RevokeCredential invalidates live state after the HTTP adapter has durably
// written an authenticated revocation. No storage write or HTTP auth lives here.
func (s *Service) RevokeCredential(keyID string) {
	affected := s.registry.RevokeAppAttestCredential(keyID)
	if a := s.authorizer; a != nil {
		a.mu.Lock()
		for p, record := range a.current {
			if record.evidence.Binding.Credential == keyID {
				delete(a.current, p)
			}
		}
		a.mu.Unlock()
	}
	for _, id := range affected {
		s.sendAppAttestAuthorizationStatus(s.registry.GetProvider(id))
	}
}
