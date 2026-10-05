package identitygate

import "time"

// ClassifyRejection distinguishes unhealthy nodes from transient capacity while
// confirming a captured session view after a shared-identity rebind. The caller
// holds its provider critical section throughout the lazy policy callbacks.
func (v View) ClassifyRejection(model string, now time.Time, ignoreBreaker bool, identity func() string, draining func() bool, eligible func() bool) (breaker, capacity bool) {
	for {
		breaker = !ignoreBreaker && (v.BreakerOpenAt(now.UnixNano()) ||
			(v.directory.EjectionEnabled() && v.EjectionOpenFor(identity(), now.UnixNano())))
		capacity = (draining() || v.CapacityCooled(model, now)) && eligible()
		if !v.Confirm() {
			return breaker, capacity
		}
	}
}
