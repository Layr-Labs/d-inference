package registry_test

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/identitygate"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

const (
	providerBreakerConsecTrip   = 5
	providerBreakerWindow       = identitygate.BreakerWindow
	providerBreakerBaseCooldown = 60 * time.Second
	providerBreakerMaxCooldown  = 5 * time.Minute
)

func providerBreakerOpenAt(gates *identitygate.Directory, id string, now time.Time) bool {
	return gates.ViewForSession(nil, id).BreakerOpenAt(now.UnixNano())
}

// Trailing successes clear any intermediate trip without clearing the history.
// With a retained clock, this reaches the same ring and closed state as direct
// history seeding, using only the real terminal recorder.
func seedProviderHealthWindow(r *production.Registry, id string, pattern []bool) {
	for _, ok := range pattern {
		status := 500
		if ok {
			status = 200
		}
		r.RecordProviderOutcome(id, ok, status, "")
	}
}
