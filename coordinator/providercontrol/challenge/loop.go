package challenge

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Run periodically sends attestation challenges to a provider.
func (s *Session) Run(ctx context.Context, providerID string, provider *registry.Provider) {
	if s.verifier.deps.Skip() {
		return
	}

	interval := s.verifier.deps.Interval()
	if interval == 0 {
		interval = DefaultInterval
	}

	// Send initial challenge immediately so the provider is routable
	// without waiting for the first ticker interval.
	s.sendChallenge(ctx, providerID, provider)

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			// Stop only for a hard (non-recoverable) untrust. A transiently
			// untrusted provider (missed-challenge timeouts) keeps being
			// challenged so a later passing challenge can restore it.
			if provider.ChallengeShouldStop() {
				return
			}
			s.sendChallenge(ctx, providerID, provider)
		case <-provider.ImmediateChallengeChan():
			// Out-of-band kick (e.g. a release-policy refresh invalidated this
			// provider's application evidence): re-challenge now so a healthy
			// provider is re-verified and routable again well before the next
			// periodic tick.
			if provider.ChallengeShouldStop() {
				return
			}
			s.sendChallenge(ctx, providerID, provider)
		}
	}
}
