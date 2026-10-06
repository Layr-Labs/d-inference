package registry_test

import (
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/identitygate"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

const (
	inferenceErrorWindow      = 60 * time.Second
	inferenceErrorCooldownTTL = 5 * time.Minute
	dispatchLoadCooldownTTL   = 2 * time.Minute
	gateIdleGrace             = 10 * time.Minute
)

type faultGateClock struct {
	mu sync.Mutex
	at time.Time
}

func (c *faultGateClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.at
}

func (c *faultGateClock) Advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.at = c.at.Add(d)
}

func (c *faultGateClock) Set(at time.Time) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.at = at
}

func newFaultGateFixture() (*production.Registry, *identitygate.Directory, *faultGateClock) {
	clock := &faultGateClock{at: time.Now()}
	options := identitygate.DefaultOptions()
	options.Now = clock.Now
	gates := identitygate.New(testLogger(), &options)
	reg := production.NewWithDependencies(testLogger(), production.Dependencies{IdentityGates: gates})
	return reg, gates, clock
}

func cooldownActive(gates *identitygate.Directory, providerID, modelID string, now time.Time) bool {
	return gates.ViewForSession(nil, providerID).DispatchLoadCooled(modelID, now)
}

func inferenceCooldownActiveAt(gates *identitygate.Directory, providerID, modelID, shape string, now time.Time) bool {
	return gates.ViewForSession(nil, providerID).InferenceErrorCooled(modelID, shape, now)
}
