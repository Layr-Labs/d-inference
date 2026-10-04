package registry_test

import (
	"math"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/capacityvalue"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/performance"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/google/uuid"
)

func serviceReservationProvider(t *testing.T) (*production.Provider, *production.ServiceReservations) {
	t.Helper()
	profile := syntheticServingProfile()
	reservations := &production.ServiceReservations{}
	r := production.NewWithDependencies(testLogger(), production.Dependencies{
		PerformanceProfiles: performance.NewCatalog(profile),
		ServiceReservations: func(string) *production.ServiceReservations { return reservations },
	})
	p := r.Register("service-reservations", nil, testRegisterMessage())
	backend := "paged"
	p.Version = "test"
	p.Hardware = protocol.Hardware{ChipName: profile.ChipName, GPUCores: 80, MemoryGB: 192}
	p.Models = []protocol.ModelInfo{{ID: "model", WeightHash: profile.ArtifactSHA256}}
	p.BackendCapacity = &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{{
		Model: "model", MaxConcurrency: 16, ActiveTokenBudgetMax: 100000,
		KVBackend: &backend, PerformanceProfile: &protocol.ServingPerformanceProfileReference{
			ID: profile.ID, RuntimeRevision: profile.RuntimeRevision, ContextTokens: 32768},
	}}}
	return p, reservations
}

func serviceReservationHeadroom(p *production.Provider, reservations *production.ServiceReservations, model string) bool {
	p.Mu().Lock()
	defer p.Mu().Unlock()
	return reservations.HasHeadroom(model)
}

func TestWholeMacServiceDelayedLocalReportDoesNotCoverPendingWork(t *testing.T) {
	p, reservations := serviceReservationProvider(t)
	pending := []*production.PendingRequest{{RequestID: "one", Model: "model"}, {RequestID: "two", Model: "model"}}
	for _, pr := range pending {
		p.AddPending(pr)
	}
	// This old provider snapshot arrives after coordinator reservation. Its
	// 14 local leases cannot be evidence that either remote lease was included.
	p.CapacityAcceptedAt = time.Now().Add(time.Second)
	used := 14.0 / 16
	p.BackendCapacity.WholeMacServiceUsed = &used
	if serviceReservationHeadroom(p, reservations, "model") {
		t.Fatal("delayed local usage concealed two unreported coordinator reservations")
	}
	// Explicitly echoed identities make those same two charges overlap.
	for _, pr := range pending {
		p.BackendCapacity.WholeMacServiceReservations = append(p.BackendCapacity.WholeMacServiceReservations,
			protocol.WholeMacServiceReservation{ID: pr.ServiceReservationID(), UsedFraction: 1.0 / 16})
	}
	if !serviceReservationHeadroom(p, reservations, "model") {
		t.Fatal("correlated provider charges counted twice")
	}
}

func TestWholeMacServiceReservationIdentityChangesAcrossRetries(t *testing.T) {
	p, reservations := serviceReservationProvider(t)
	pending := &production.PendingRequest{RequestID: "same-request", Model: "model"}
	p.AddPending(pending)
	firstID := pending.ServiceReservationID()
	if firstID == pending.RequestID || len(firstID) != 36 || uuid.Validate(firstID) != nil {
		t.Fatalf("invalid opaque reservation ID: %q", firstID)
	}
	p.RemovePending(pending.RequestID)
	p.AddPending(pending)
	if pending.ServiceReservationID() == firstID {
		t.Fatal("retry reused the old attempt's reservation identity")
	}
	used := 15.0 / 16
	p.BackendCapacity.WholeMacServiceUsed = &used
	p.BackendCapacity.WholeMacServiceReservations = []protocol.WholeMacServiceReservation{{ID: firstID, UsedFraction: 1.0 / 16}}
	if serviceReservationHeadroom(p, reservations, "model") {
		t.Fatal("stale attempt report concealed the retry's new charge")
	}
}

func TestWholeMacServiceCorrelationPreservesTheLargerCharge(t *testing.T) {
	p, reservations := serviceReservationProvider(t)
	pending := &production.PendingRequest{RequestID: "request", Model: "model"}
	p.AddPending(pending)
	used := 15.0 / 16
	p.BackendCapacity.WholeMacServiceUsed = &used
	p.BackendCapacity.WholeMacServiceReservations = []protocol.WholeMacServiceReservation{{
		ID: pending.ServiceReservationID(), UsedFraction: 1.0 / 24,
	}}
	if serviceReservationHeadroom(p, reservations, "model") {
		t.Fatal("smaller reported lease discounted the frozen coordinator charge")
	}
	p.BackendCapacity.WholeMacServiceReservations[0].UsedFraction = 1.0 / 8
	if !serviceReservationHeadroom(p, reservations, "model") {
		t.Fatal("larger reported lease counted twice")
	}
	used = 1
	if serviceReservationHeadroom(p, reservations, "model") {
		t.Fatal("larger provider-held charge was subtracted from its reported total")
	}
}

func TestWholeMacServiceMalformedCorrelationFailsClosed(t *testing.T) {
	const id = "6e1f61d1-e22c-4d24-a3a7-d347772a48cb"
	type entry = protocol.WholeMacServiceReservation
	many := make([]entry, capacityvalue.MaxWholeMacServiceReservations+1)
	for i := range many {
		many[i] = entry{ID: uuid.NewString(), UsedFraction: 0.001}
	}
	for name, entries := range map[string][]entry{
		"arbitrary_id":  {{ID: "not-a-uuid", UsedFraction: .1}},
		"oversized_id":  {{ID: strings.Repeat("x", 1024), UsedFraction: .1}},
		"too_many":      many,
		"duplicate":     {{ID: id, UsedFraction: .1}, {ID: strings.ToUpper(id), UsedFraction: .1}},
		"zero":          {{ID: id, UsedFraction: 0}},
		"negative":      {{ID: id, UsedFraction: -.1}},
		"nan":           {{ID: id, UsedFraction: math.NaN()}},
		"infinite":      {{ID: id, UsedFraction: math.Inf(1)}},
		"over_one":      {{ID: id, UsedFraction: 1.1}},
		"exceeds_total": {{ID: id, UsedFraction: .6}},
	} {
		t.Run(name, func(t *testing.T) {
			p, reservations := serviceReservationProvider(t)
			used := .5
			p.BackendCapacity.WholeMacServiceUsed = &used
			p.BackendCapacity.WholeMacServiceReservations = entries
			if serviceReservationHeadroom(p, reservations, "model") {
				t.Fatal("malformed correlation admitted work")
			}
			var accepted protocol.BackendCapacity
			capacityvalue.CloneBackendCapacityFields(&accepted, p.BackendCapacity)
			if *accepted.WholeMacServiceUsed != 1 || len(accepted.WholeMacServiceReservations) != 0 {
				t.Fatal("malformed correlation was retained instead of failing closed")
			}
		})
	}
}

func TestWholeMacServiceCorrelationCloneAndLegacyOmission(t *testing.T) {
	used := .5
	id := "6e1f61d1-e22c-4d24-a3a7-d347772a48cb"
	report := &protocol.BackendCapacity{WholeMacServiceUsed: &used,
		WholeMacServiceReservations: []protocol.WholeMacServiceReservation{{ID: strings.ToUpper(id), UsedFraction: .25}}}
	var accepted protocol.BackendCapacity
	capacityvalue.CloneBackendCapacityFields(&accepted, report)
	if accepted.WholeMacServiceReservations[0].ID != id {
		t.Fatal("UUID identity not normalized")
	}
	accepted.WholeMacServiceReservations[0].UsedFraction = .1
	if report.WholeMacServiceReservations[0].UsedFraction != .25 {
		t.Fatal("capacity snapshot aliases live correlation")
	}
	p, reservations := serviceReservationProvider(t)
	p.BackendCapacity = &protocol.BackendCapacity{}
	if !serviceReservationHeadroom(p, reservations, "legacy") {
		t.Fatal("legacy provider without aggregate lost its admission behavior")
	}
}
