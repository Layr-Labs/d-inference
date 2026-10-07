package registry_test

import (
	"sync/atomic"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/serviceretirement"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

type serviceRetirementFixture struct {
	r            *production.Registry
	p            *production.Provider
	reservations *production.ServiceReservations
	retirement   *serviceretirement.Ledger
	writer       *writerFixture
	frames       atomic.Int32
}

func newServiceRetirementFixture(t *testing.T, optedIn bool) *serviceRetirementFixture {
	t.Helper()
	f := &serviceRetirementFixture{reservations: &production.ServiceReservations{}, retirement: &serviceretirement.Ledger{}}
	f.writer = newWriterFixture(8, 8, nil, nil, func([]byte) error { f.frames.Add(1); return nil }, nil)
	go f.writer.Run()
	configure := func(deps *production.Dependencies) {
		deps.Connections = retainedWriterFactory{writer: f.writer.Writer}
		deps.ServiceReservations = func(string) *production.ServiceReservations { return f.reservations }
		deps.ServiceRetirements = func(string) *serviceretirement.Ledger { return f.retirement }
	}
	if optedIn {
		f.r, f.p = retirementProvider(t, configure)
	} else {
		deps := production.Dependencies{}
		configure(&deps)
		f.r = production.NewWithDependencies(testLogger(), deps)
		f.p = makeSchedulerProvider(t, f.r, "p", "m", 100)
		used := 0.0
		f.p.BackendCapacity.WholeMacServiceUsed = &used
	}
	t.Cleanup(f.writer.Close)
	return f
}

func (f *serviceRetirementFixture) attempt(t *testing.T, id string, charge float64) *production.PendingRequest {
	t.Helper()
	pr := &production.PendingRequest{RequestID: id, Model: "m", ProviderID: f.p.ID}
	f.p.Mu().Lock()
	f.reservations.Add(pr, charge)
	f.p.Mu().Unlock()
	// Use the same final authorization operation as the writer rather than
	// assigning a private handoff flag or emitting an unrelated socket frame.
	if err := f.p.NewInferenceHandoff(pr).Authorize(); err != nil {
		t.Fatalf("authorize attempt: %v", err)
	}
	return pr
}

func (f *serviceRetirementFixture) account(reported ...protocol.WholeMacServiceReservation) serviceretirement.Account {
	f.p.Mu().Lock()
	defer f.p.Mu().Unlock()
	return f.retirement.Account(reported)
}

func (f *serviceRetirementFixture) headroom() bool {
	f.p.Mu().Lock()
	defer f.p.Mu().Unlock()
	return f.reservations.HasHeadroom("m")
}
