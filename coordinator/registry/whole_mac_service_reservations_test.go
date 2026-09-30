package registry

import (
	"math"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/google/uuid"
)

func TestWholeMacServiceDelayedLocalReportDoesNotCoverPendingWork(t *testing.T) {
	p, _ := reviewedProfileFixture(t)
	p.pendingReqs = make(map[string]*PendingRequest)
	p.addPendingLocked(&PendingRequest{RequestID: "one", Model: "model"})
	p.addPendingLocked(&PendingRequest{RequestID: "two", Model: "model"})
	// This old provider snapshot arrives after coordinator reservation. Its
	// 14 local leases cannot be evidence that either remote lease was included.
	p.CapacityAcceptedAt = time.Now().Add(time.Second)
	used := 14.0 / 16
	p.BackendCapacity.WholeMacServiceUsed = &used
	if p.hasWholeMacServiceHeadroomLocked("model") {
		t.Fatal("delayed local usage concealed two unreported coordinator reservations")
	}
	// Explicitly echoed identities make those same two charges overlap.
	for _, pending := range p.pendingReqs {
		p.BackendCapacity.WholeMacServiceReservations = append(p.BackendCapacity.WholeMacServiceReservations,
			protocol.WholeMacServiceReservation{ID: pending.ServiceReservationID(), UsedFraction: 1.0 / 16})
	}
	if !p.hasWholeMacServiceHeadroomLocked("model") {
		t.Fatal("correlated provider charges counted twice")
	}
}

func TestWholeMacServiceReservationIdentityChangesAcrossRetries(t *testing.T) {
	p, _ := reviewedProfileFixture(t)
	p.pendingReqs = make(map[string]*PendingRequest)
	pending := &PendingRequest{RequestID: "same-request", Model: "model"}
	p.addPendingLocked(pending)
	firstID := pending.ServiceReservationID()
	if firstID == pending.RequestID || len(firstID) != 36 || uuid.Validate(firstID) != nil {
		t.Fatalf("invalid opaque reservation ID: %q", firstID)
	}
	delete(p.pendingReqs, pending.RequestID)
	p.addPendingLocked(pending)
	if pending.ServiceReservationID() == firstID {
		t.Fatal("retry reused the old attempt's reservation identity")
	}
	used := 15.0 / 16
	p.BackendCapacity.WholeMacServiceUsed = &used
	p.BackendCapacity.WholeMacServiceReservations = []protocol.WholeMacServiceReservation{{ID: firstID, UsedFraction: 1.0 / 16}}
	if p.hasWholeMacServiceHeadroomLocked("model") {
		t.Fatal("stale attempt report concealed the retry's new charge")
	}
}

func TestWholeMacServiceCorrelationPreservesTheLargerCharge(t *testing.T) {
	p, _ := reviewedProfileFixture(t)
	p.pendingReqs = make(map[string]*PendingRequest)
	pending := &PendingRequest{RequestID: "request", Model: "model"}
	p.addPendingLocked(pending)
	used := 15.0 / 16
	p.BackendCapacity.WholeMacServiceUsed = &used
	p.BackendCapacity.WholeMacServiceReservations = []protocol.WholeMacServiceReservation{{
		ID: pending.ServiceReservationID(), UsedFraction: 1.0 / 24,
	}}
	if p.hasWholeMacServiceHeadroomLocked("model") {
		t.Fatal("smaller reported lease discounted the frozen coordinator charge")
	}
	p.BackendCapacity.WholeMacServiceReservations[0].UsedFraction = 1.0 / 8
	if !p.hasWholeMacServiceHeadroomLocked("model") {
		t.Fatal("larger reported lease counted twice")
	}
	used = 1
	if p.hasWholeMacServiceHeadroomLocked("model") {
		t.Fatal("larger provider-held charge was subtracted from its reported total")
	}
}

func TestWholeMacServiceMalformedCorrelationFailsClosed(t *testing.T) {
	const id = "6e1f61d1-e22c-4d24-a3a7-d347772a48cb"
	type entry = protocol.WholeMacServiceReservation
	many := make([]entry, maxWholeMacServiceReservations+1)
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
			p, _ := reviewedProfileFixture(t)
			used := .5
			p.BackendCapacity.WholeMacServiceUsed = &used
			p.BackendCapacity.WholeMacServiceReservations = entries
			if p.hasWholeMacServiceHeadroomLocked("model") {
				t.Fatal("malformed correlation admitted work")
			}
			var accepted protocol.BackendCapacity
			cloneBackendCapacityFields(&accepted, p.BackendCapacity)
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
	cloneBackendCapacityFields(&accepted, report)
	if accepted.WholeMacServiceReservations[0].ID != id {
		t.Fatal("UUID identity not normalized")
	}
	accepted.WholeMacServiceReservations[0].UsedFraction = .1
	if report.WholeMacServiceReservations[0].UsedFraction != .25 {
		t.Fatal("capacity snapshot aliases live correlation")
	}
	p := &Provider{BackendCapacity: &protocol.BackendCapacity{}}
	if !p.hasWholeMacServiceHeadroomLocked("legacy") {
		t.Fatal("legacy provider without aggregate lost its admission behavior")
	}
}
