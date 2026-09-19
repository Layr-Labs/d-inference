package service

import "github.com/eigeninference/d-inference/coordinator/registry"

const RevocationFreshness = appAttestRevocationFreshness

// RevokeCredential invalidates live state after the HTTP adapter has durably
// written an authenticated revocation. No storage write or HTTP auth lives here.
func (s *Service) RevokeCredential(keyID string) {
	affected := s.registry.RevokeAppAttestCredential(keyID)
	if a := s.authorizer; a != nil {
		var presenters []*registry.Provider
		a.mu.Lock()
		for p, record := range a.current {
			if record.evidence.Binding.Credential == keyID {
				delete(a.current, p)
				presenters = append(presenters, p)
			}
		}
		a.mu.Unlock()
		for _, p := range presenters {
			if s.registry.DenyAppAttestProvider(p) {
				s.queueAuthorizationStatus(p)
			}
		}
	}
	for _, id := range affected {
		s.queueAuthorizationStatus(s.registry.GetProvider(id))
	}
}

// Security state is fenced synchronously above; provider writes belong to the
// bounded post worker so a stalled socket cannot block revocation refresh.
func (s *Service) queueAuthorizationStatus(p *registry.Provider) {
	if p == nil || s.authorizer == nil {
		return
	}
	a := s.authorizer
	a.mu.Lock()
	a.queuePostLocked(p)
	a.mu.Unlock()
}
