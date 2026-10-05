package identitygate

import "time"

type Reason uint8

const (
	Allowed Reason = iota
	DispatchLoadCooldown
	InferenceErrorCooldown
	CapacityCooldown
	ProviderBreaker
	HealthEjection
)

// Evaluation reports the first closed gate and the confirmed view's rebases.
type Evaluation struct {
	Reason  Reason
	Rereads int
}

func (r *Directory) EjectionEnabled() bool { return r.healthEjectionEnabled() }

// Evaluate preserves routing precedence and confirms the entire verdict before
// returning. The identity projection is lazy: earlier rejections and breaker
// bypasses must not perform the provider's identity lookup or allocate its key.
// The projection's caller retains its provider critical section throughout.
func (v *View) Evaluate(model, shape string, identity func() string, now time.Time, ignoreBreaker, ignoreCapacity bool) Evaluation {
	nowNS := now.UnixNano()
	for {
		reason := Allowed
		switch {
		case v.DispatchLoadCooled(model, now):
			reason = DispatchLoadCooldown
		case v.InferenceErrorCooled(model, shape, now):
			reason = InferenceErrorCooldown
		case !ignoreCapacity && v.CapacityCooled(model, now):
			reason = CapacityCooldown
		case !ignoreBreaker && v.BreakerOpenAt(nowNS):
			reason = ProviderBreaker
		case !ignoreBreaker && v.directory != nil && v.directory.EjectionEnabled() && identity != nil && v.EjectionOpenFor(identity(), nowNS):
			reason = HealthEjection
		}
		if !v.Confirm() {
			return Evaluation{Reason: reason, Rereads: v.rereads}
		}
	}
}
