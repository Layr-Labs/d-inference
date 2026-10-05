package deviceverification

import (
	"github.com/eigeninference/d-inference/coordinator/internal/provider/verification"
)

// The owner supplies verification effects; the scheduler owns only dispatch,
// durable claims and registration-bound callback fencing.
func (s *Verifier) NewVerificationScheduler(cfg verification.Config, deps verification.Dependencies) *verification.Service {
	if deps.Execute == nil {
		deps.Execute = s.ExecuteScheduledVerification
	}
	if deps.ReuseMDA == nil {
		deps.ReuseMDA = func(binding verification.Binding) bool {
			return s.AttachCachedMDAProof(binding.ProviderID, binding.Provider, binding.Attestation)
		}
	}
	if deps.PersistProvider == nil {
		deps.PersistProvider = s.registry.PersistProvider
	}
	return &verification.Service{Scheduler: verification.New(s.store, s.logger, s.observation, verification.NewQueue(cfg), deps)}
}
