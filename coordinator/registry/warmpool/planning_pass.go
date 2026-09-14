package warmpool

import "time"

// planningPass keeps one configuration through target selection, reservation,
// snapshot publication and the tick's send decision. Controller state and live
// bindings remain shared; only the published configuration value is captured.
type planningPass[A any] struct {
	*Controller[A]
	config Config
}

func (c *Controller[A]) planningPass() planningPass[A] {
	return planningPass[A]{Controller: c, config: c.configuration()}
}

// Plan captures configuration once. Tick calls it while holding tickMu;
// Configure remains independent so live callbacks may safely reconfigure.
func (c *Controller[A]) Plan(now time.Time) []Snapshot[A] {
	return c.planningPass().plan(now)
}

func (c *Controller[A]) PlanObserveOnly(now time.Time, reserve func([]A, time.Time) []A) []Snapshot[A] {
	return c.planningPass().planObserveOnly(now, reserve)
}

func (c *Controller[A]) TargetParams() Params { return c.planningPass().targetParams() }

func (c *Controller[A]) TargetWarm(fleet FleetModel, pressure Pressure, queue QueuePressure, params Params, svc time.Duration, now time.Time) int {
	return c.planningPass().targetWarm(fleet, pressure, queue, params, svc, now)
}
