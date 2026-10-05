package verification

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Service is the registration-driven lifecycle used by the trust owner. It
// starts the dispatcher after validation but before persisting the submission,
// using the same captured attestation for both validation and persistence.
// Scheduler itself also supports an explicit load/dispatch driver.
type Service struct{ *Scheduler }

func (s *Service) Submit(ctx context.Context, id string, provider *registry.Provider, priority store.VerificationPriority) uint64 {
	if s == nil {
		return 0
	}
	return s.submit(ctx, id, provider, priority, s.Start)
}
