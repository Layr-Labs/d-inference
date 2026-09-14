package faultstate

import "time"

// Policy reports the immutable construction-time settings by value.
type Policy struct {
	CapacityCooldown struct {
		Threshold               int
		Window, BaseTTL, MaxTTL time.Duration
	}
	BudgetClamp struct {
		Enabled bool
		TTL     time.Duration
	}
	CapacityRate struct{ PenaltyMs float64 }
}

func (r *Manager[C]) Policy() Policy {
	return Policy{CapacityCooldown: r.capacityCooldownCfg, BudgetClamp: r.budgetClampCfg, CapacityRate: r.capacityRateCfg}
}
