package registry_test

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/identitygate"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

const (
	capacityRateMinSample        = 8
	defaultCapacityRatePenaltyMs = 15_000.0
)

func newCapacityRateRegistry(now func() time.Time) (*production.Registry, *identitygate.Directory) {
	options := identitygate.DefaultOptions()
	options.Now = now
	gates := identitygate.New(testLogger(), &options)
	r := production.NewWithDependencies(testLogger(), production.Dependencies{IdentityGates: gates})
	return r, gates
}

// Read the same retained identity's penalty that the scheduler uses.
func capacityRatePenaltyOf(gates *identitygate.Directory, providerID, model string) (penaltyMs, rate float64) {
	return gates.ViewForSession(nil, providerID).CapacityRatePenalty(model, time.Now())
}
