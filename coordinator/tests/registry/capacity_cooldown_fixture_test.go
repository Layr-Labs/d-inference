package registry_test

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/identitygate"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func newCapacityCooldownRegistry(now func() time.Time) (*production.Registry, *identitygate.Directory) {
	options := identitygate.DefaultOptions()
	options.Now = now
	gates := identitygate.New(nil, &options)
	r := production.NewWithDependencies(nil, production.Dependencies{IdentityGates: gates})
	return r, gates
}

func capacityCooldownExpiryOf(gates *identitygate.Directory, provider, model string) (time.Time, bool) {
	assessment := gates.ViewForSession(nil, provider).CapacityAssessment(model)
	return assessment.Decision.RetryAfter, assessment.Present
}
