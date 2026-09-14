package readiness

// SetDraining toggles the coordinator's graceful-drain state. When true the
// drain gate rejects new inference requests (429 + Retry-After) while in-flight
// requests finish, and /readyz reports not-ready. Pass false to un-drain (e.g.
// to roll back an aborted upgrade). Safe for concurrent use.
func (s *Controller) SetDraining(draining bool) {
	s.coordinatorDraining.Store(draining)
}

// IsDraining reports whether the coordinator is currently draining for a
// restart/upgrade. Safe for concurrent use.
func (s *Controller) IsDraining() bool {
	return s.coordinatorDraining.Load()
}

// Inflight returns the number of inference requests currently being served
// through the drain gate. Safe for concurrent use.
func (s *Controller) Inflight() int64 {
	return s.httpInflight.Load()
}

// incInflight records the entry of an inference request into the drain gate and
// returns the new in-flight count.
func (s *Controller) incInflight() int64 {
	return s.httpInflight.Add(1)
}

// decInflight records the exit of an inference request from the drain gate and
// returns the new in-flight count.
func (s *Controller) decInflight() int64 {
	return s.httpInflight.Add(-1)
}
