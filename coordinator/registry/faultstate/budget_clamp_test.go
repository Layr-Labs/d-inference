package faultstate

import (
	"time"
)

// ageBudgetClamp rewinds the pair's clamp time by d (simulating TTL passage
// without sleeping), keyed by the pair's CURRENT fault key.
func ageBudgetClamp(r *testManager, providerID, model string, d time.Duration) {
	withGateForSession(r, providerID, func(g *gateState) {
		if e, ok := g.budgetClamps[model]; ok {
			e.clampedAt = e.clampedAt.Add(-d)
		}
	})
}
