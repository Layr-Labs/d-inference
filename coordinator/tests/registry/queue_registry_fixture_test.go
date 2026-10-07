package registry_test

import (
	"sync/atomic"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/queuedrain"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

type drainRegistryFixture struct {
	*production.Registry
	clock       *drainTestClockHandle
	scheduler   *drainFixtureScheduler
	suppression *queuedrain.Suppressor
	claims      *drainClaimConsumer
	planner     *drainPreparationCounter
}

type drainClaimConsumer struct {
	actual     *production.RequestQueue
	beforePop  func(string)
	afterOffer func()
}

func (c *drainClaimConsumer) PopNextFresh(model string) *production.QueuedRequest {
	if c.beforePop != nil {
		c.beforePop(model)
	}
	return c.actual.PopNextFresh(model)
}

func (c *drainClaimConsumer) RequeueFront(req *production.QueuedRequest) { c.actual.RequeueFront(req) }

func (c *drainClaimConsumer) PrepareProviderAssignment(req *production.QueuedRequest, provider *production.Provider, cleanup func()) (*production.ProviderAssignment, bool) {
	assignment, offered := c.actual.PrepareProviderAssignment(req, provider, cleanup)
	if offered && c.afterOffer != nil {
		c.afterOffer()
	}
	return assignment, offered
}

type drainPreparationCounter struct {
	actual  *production.ReservationPlanner
	enabled atomic.Bool
	scans   atomic.Int64
}

func (c *drainPreparationCounter) Prepare(model string, pending *production.PendingRequest, excluded ...string) *production.PreparedReservation {
	prepared := c.actual.Prepare(model, pending, excluded...)
	if c.enabled.Load() {
		c.scans.Add(1)
	}
	return prepared
}

type drainFixtureScheduler struct {
	real      atomic.Bool
	completed chan struct{}
}

func (s *drainFixtureScheduler) Schedule(delay time.Duration, run func()) {
	if !s.real.Load() {
		return
	}
	queuedrain.WallScheduler{}.Schedule(delay, func() {
		run()
		s.completed <- struct{}{}
	})
}

func newDrainRegistry() *drainRegistryFixture {
	f := &drainRegistryFixture{
		clock: &drainTestClockHandle{}, scheduler: &drainFixtureScheduler{completed: make(chan struct{}, 4)},
	}
	f.scheduler.real.Store(true)
	f.suppression = queuedrain.NewSuppressor(func() time.Time {
		if now := f.clock.v.Load(); now != nil {
			return *now
		}
		return time.Now()
	}, f.scheduler)
	f.Registry = production.NewWithDependencies(testLogger(), production.Dependencies{
		DrainSuppression: f.suppression,
		QueueClaims: func(queue *production.RequestQueue) production.QueueClaims {
			f.claims = &drainClaimConsumer{actual: queue}
			return f.claims
		},
		Reservations: func(actual *production.ReservationPlanner) production.ReservationPreparation {
			f.planner = &drainPreparationCounter{actual: actual}
			return f.planner
		},
	})
	return f
}
