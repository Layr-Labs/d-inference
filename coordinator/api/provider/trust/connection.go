package trust

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

func (s *Owner) SubmitRegistrationVerification(ctx context.Context, id string, p *registry.Provider) (string, uint64) {
	if s.verificationBackend.
		Scheduler !=
		nil {
		if ar := p.GetAttestationResult(); ar != nil && ar.Valid {
			priority := s.VerificationSubmitPriority(ar.PublicKey, ar.SerialNumber)
			return ar.PublicKey, s.verificationBackend.
				Scheduler.
				Submit(ctx, id, p, priority)
		}
	}
	return "", 0
}

func (s *Owner) UnbindConnection(id, seKey string, generation uint64) {
	if s.verificationBackend.
		Scheduler !=
		nil {
		s.verificationBackend.
			Scheduler.
			Unbind(seKey, generation)
	}
	if s.codeAttestThrottle != nil {
		s.codeAttestThrottle.ClearResumeChallenges(id)
	}
}
