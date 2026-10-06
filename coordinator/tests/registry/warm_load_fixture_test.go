package registry_test

import (
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// Record the commands delivered to the same real lifecycle consumed by routing,
// rather than exposing the provider's mutable placement or retry timestamps.
type recordingWarmLoads struct {
	*warmplan.LoadState
	mu       sync.Mutex
	placedAt time.Time
	retryAt  time.Time
}

func (s *recordingWarmLoads) Place(now time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.LoadState.Place(now)
	s.placedAt = now
}

func (s *recordingWarmLoads) BackoffUntil(deadline time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.LoadState.BackoffUntil(deadline)
	s.retryAt = deadline
}

func (s *recordingWarmLoads) Reset() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.LoadState.Reset()
	s.placedAt, s.retryAt = time.Time{}, time.Time{}
}

func (s *recordingWarmLoads) placement() time.Time {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.placedAt
}

func (s *recordingWarmLoads) retryDeadline() time.Time {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.retryAt
}

func warmCandidateReason(r *production.Registry, model string, now time.Time) warmplan.ColdReason {
	fleet := warmFixtureFor(r).deps.Fleet(now)[model]
	if len(fleet.EligibleCold) != 0 {
		return warmplan.WarmColdEligible
	}
	for reason := range fleet.ColdDisq {
		return reason
	}
	panic("single-provider fleet had neither an eligible candidate nor a reason")
}
