package trust

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

func (s *Owner) SubmitRegistrationVerification(ctx context.Context, id string, p *registry.Provider) (string, uint64) {
	if s.mdmScheduler != nil {
		if ar := p.GetAttestationResult(); ar != nil && ar.Valid {
			priority := s.VerificationSubmitPriority(ar.PublicKey, ar.SerialNumber)
			return ar.PublicKey, s.mdmScheduler.Submit(ctx, id, p, priority)
		}
	}
	return "", 0
}

func (s *Owner) UnbindConnection(id, seKey string, generation uint64) {
	if s.mdmScheduler != nil {
		s.mdmScheduler.Unbind(seKey, generation)
	}
	if s.codeAttestThrottle != nil {
		s.codeAttestThrottle.clearResumeChallenges(id)
	}
}

func (s *Owner) CodeAttestorConfigured() bool { return s.codeAttestor != nil }
