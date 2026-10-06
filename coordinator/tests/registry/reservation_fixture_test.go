package registry_test

import (
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

type reservationPreparationFixture struct {
	planner *production.ReservationPlanner
	after   func(string)
}

func (f *reservationPreparationFixture) Prepare(model string, pending *production.PendingRequest, excludeIDs ...string) *production.PreparedReservation {
	prepared := f.planner.Prepare(model, pending, excludeIDs...)
	if f.after != nil {
		f.after(model)
	}
	return prepared
}

func newReservationFixture() (*production.Registry, *reservationPreparationFixture) {
	fixture := &reservationPreparationFixture{}
	r := production.NewWithDependencies(testLogger(), production.Dependencies{
		Reservations: func(planner *production.ReservationPlanner) production.ReservationPreparation {
			fixture.planner = planner
			return fixture
		},
	})
	return r, fixture
}
