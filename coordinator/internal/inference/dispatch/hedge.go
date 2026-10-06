package dispatch

import (
	"github.com/eigeninference/d-inference/coordinator/internal/inference/hedge"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// AcquireHedge snapshots current capacity before atomically claiming the shared
// governor budget. A successful claim must be resolved once by the caller.
func (s *Dispatcher) AcquireHedge(g *hedge.Governor, model string, pr *registry.PendingRequest, excluded []string, primaryID string) (hedge.Verdict, bool) {
	if g == nil {
		return hedge.Allow, false
	}
	excluded = append(excluded, primaryID)
	idleAlt, queueDepth, fleetIdle, capacitySignals := s.registry.HedgeGovernorSnapshot(model, pr, excluded...)
	if !capacitySignals {
		return hedge.SuppressNoIdleCapacity, false
	}
	return g.TryAcquire(model, hedge.Inputs{
		IdleAlternativeExists: idleAlt,
		ModelQueueDepth:       queueDepth,
		FleetIdleSlots:        fleetIdle,
	})
}
