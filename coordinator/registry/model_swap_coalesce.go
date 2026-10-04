package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/swapplan"
)

type modelSwapPlanGate = swapplan.Controller

type SwapPlanningFactory func(swapplan.Dependencies) *swapplan.Controller

func (r *Registry) configureSwapPlanning(factory SwapPlanningFactory) {
	deps := swapplan.Dependencies{
		Queued: func() bool {
			queue := r.Queue()
			return queue != nil && queue.HasQueued()
		},
		Plan: r.TriggerModelSwaps,
	}
	if factory != nil {
		r.swapPlanGate = factory(deps)
	} else {
		r.swapPlanGate = swapplan.New(deps)
	}
}

// Only swap planning is coalesced; the heartbeat's actual queue drain still runs
// first, and the notification timestamp is captured after that drain completes.
func (r *Registry) triggerModelSwapsFromHeartbeat(now time.Time) bool {
	return r.swapPlanGate.Trigger(now)
}
