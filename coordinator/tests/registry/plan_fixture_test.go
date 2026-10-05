package registry_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/measurements"
	"github.com/eigeninference/d-inference/coordinator/protocol"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

type planRegistryFixture struct {
	registry    *production.Registry
	histories   map[string]*measurements.History
	preparation *reservationPreparationFixture
}

func planTestRequest(id string, prompt, maxTok int) *production.PendingRequest {
	return &production.PendingRequest{
		RequestID:             id,
		EstimatedPromptTokens: prompt,
		RequestedMaxTokens:    maxTok,
	}
}

func newPlanRegistryFixture() *planRegistryFixture {
	return newPlanRegistryFixtureWithDependencies(production.Dependencies{})
}

func newPlanRegistryFixtureWithDependencies(deps production.Dependencies) *planRegistryFixture {
	f := &planRegistryFixture{
		histories:   make(map[string]*measurements.History),
		preparation: &reservationPreparationFixture{},
	}
	deps.Measurements = func(id string) *measurements.History {
		history := &measurements.History{}
		f.histories[id] = history
		return history
	}
	deps.Reservations = func(planner *production.ReservationPlanner) production.ReservationPreparation {
		f.preparation.planner = planner
		return f.preparation
	}
	f.registry = production.NewWithDependencies(testLogger(), deps)
	return f
}

func (f *planRegistryFixture) provider(t *testing.T, id, model string, usedTokens int64) *production.Provider {
	t.Helper()
	decode := 1000 / (12.5 + float64(usedTokens))
	p := makeTokenBudgetProvider(t, f.registry, id, model, 100, usedTokens, 1_000_000, decode)
	p.Mu().Lock()
	defer p.Mu().Unlock()
	now := time.Now()
	p.CapacityAcceptedAt = now
	zero, initialized, rate := int64(0), true, 1200.0
	p.BackendCapacity.Slots[0].Telemetry = &protocol.SlotTelemetry{QueuedPrefillTokens: &zero, PartialPrefillRows: &zero, IsolatedPrefillTPS: &rate, EWMAInitialized: &initialized}
	p.BackendCapacity.Slots[0].PerformanceMeasurements = localRateMeasurements(rate, decode)
	// Arithmetic fixtures sample locally; root heartbeat ingestion retains its
	// conservative transport handoff allowance.
	f.histories[id].Reconcile(p.BackendCapacity, p.CapacityAcceptedAt, now, 0)
	return p
}
