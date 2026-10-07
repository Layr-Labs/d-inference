package registry_test

import (
	"fmt"
	"math"
	"testing"
	"testing/synctest"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/capacityvalue"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/deadline"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestServiceReportRejectsDifferentOwnerAndRevalidatesEachSnapshot(t *testing.T) {
	used := .5
	capacity := &protocol.BackendCapacity{WholeMacServiceUsed: &used,
		WholeMacServiceReservations: []protocol.WholeMacServiceReservation{{ID: "6e1f61d1-e22c-4d24-a3a7-d347772a48cb", UsedFraction: .25}}}
	report := capacityvalue.NewServiceReport(capacity)
	copy := *capacity
	if !report.ValidFor(capacity) || report.ValidFor(&copy) || report.ValidFor(nil) {
		t.Fatal("validation crossed its borrowed capacity owner")
	}
	for _, invalid := range []float64{-1, math.NaN(), math.Inf(1), 1.01} {
		used = invalid
		if capacityvalue.NewServiceReport(capacity).ValidFor(capacity) {
			t.Fatalf("fresh snapshot accepted invalid usage %v", invalid)
		}
	}
	used = .5
	capacity.WholeMacServiceReservations = append(capacity.WholeMacServiceReservations,
		protocol.WholeMacServiceReservation{ID: "6E1F61D1-E22C-4D24-A3A7-D347772A48CB", UsedFraction: .25})
	if capacityvalue.NewServiceReport(capacity).ValidFor(capacity) {
		t.Fatal("fresh snapshot accepted duplicate UUIDs with different case")
	}
	capacity.WholeMacServiceReservations = nil
	if !capacityvalue.NewServiceReport(capacity).ValidFor(capacity) {
		t.Fatal("a later valid report inherited earlier validation failure")
	}
}

func TestDeadlineWorkCannotBorrowAnotherProvidersServiceValidation(t *testing.T) {
	f := newCalibrationPolicyFixture(t, time.Now())
	identity := f.identity()
	capacityCopy := *identity.Capacity
	foreign := capacityvalue.NewServiceReport(&capacityCopy)
	if _, known := deadline.BoundSlotsWithReport(f.catalog, identity, f.request.Model, foreign); known {
		t.Fatal("deadline work accepted validation from a different producer owner")
	}
	report := capacityvalue.NewServiceReport(identity.Capacity)
	work, known := deadline.BoundSlotsWithReport(f.catalog, identity, f.request.Model, report)
	if !known || work.Finish().ActiveRequests != 0 {
		t.Fatal("the locked provider's own idle report did not qualify")
	}
}

func TestServiceReportReservationCountBoundary(t *testing.T) {
	used := .5
	capacity := &protocol.BackendCapacity{WholeMacServiceUsed: &used}
	for i := 0; i < capacityvalue.MaxWholeMacServiceReservations; i++ {
		capacity.WholeMacServiceReservations = append(capacity.WholeMacServiceReservations,
			protocol.WholeMacServiceReservation{ID: fmt.Sprintf("6e1f61d1-e22c-4d24-a3a7-%012x", i), UsedFraction: 1.0 / 128})
	}
	if !capacityvalue.NewServiceReport(capacity).ValidFor(capacity) {
		t.Fatal("the maximum bounded correlation report did not validate")
	}
	capacity.WholeMacServiceReservations = append(capacity.WholeMacServiceReservations,
		protocol.WholeMacServiceReservation{ID: "6e1f61d1-e22c-4d24-a3a7-d347772a48cb", UsedFraction: 1.0 / 128})
	if capacityvalue.NewServiceReport(capacity).ValidFor(capacity) {
		t.Fatal("an oversized report admitted its first bounded prefix")
	}
}

// Seventeen pending owners crosses the ordinary inline work buffer. Each model
// retains its own rate, absent slots use the provider fallback, and committed
// content retires prefill work without releasing its output/memory commitment.
func TestRoutingPendingSnapshotSpillAndRetainedQuotes(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		var planner *production.ReservationPlanner
		r := production.NewWithDependencies(testLogger(), production.Dependencies{
			Reservations: func(p *production.ReservationPlanner) production.ReservationPreparation { planner = p; return p },
		})
		p := makeSchedulerProvider(t, r, "pending-snapshot", "target", 128, "warm", "absent")
		p.Mu().Lock()
		p.PrefillTPS = 1024
		p.CapacityAcceptedAt = time.Now().Add(-time.Second)
		p.BackendCapacity.Slots = []protocol.BackendSlotCapacity{
			{Model: "target", State: "running", ActiveTokenBudgetMax: 1 << 20, ObservedDecodeTPS: 128, ObservedPrefillTPS: 1024},
			{Model: "warm", State: "running", ActiveTokenBudgetMax: 1 << 20, ObservedDecodeTPS: 64, ObservedPrefillTPS: 512},
		}
		p.Mu().Unlock()
		pending := make([]*production.PendingRequest, 17)
		models := []string{"target", "warm", "absent"}
		service, output := 0.0, 0.0
		for i := range pending {
			pending[i] = &production.PendingRequest{RequestID: fmt.Sprintf("existing-%d", i), Model: models[i%3], EstimatedPromptTokens: 128, RequestedMaxTokens: 64}
			if i%4 == 0 {
				pending[i].MarkContentCommitted()
			}
			p.AddPending(pending[i])
			decode, prefill := 128.0, 1024.0
			if pending[i].Model == "warm" {
				decode, prefill = 64, 512
			}
			output += 64 / decode * 1000
			service += 64 / decode * 1000
			if i%4 != 0 {
				service += 128 / prefill * 1000
			}
		}
		request := &production.PendingRequest{Model: "target", EstimatedPromptTokens: 128, RequestedMaxTokens: 64}
		quote := func() production.PlanEntry {
			t.Helper()
			scan := planner.ScanCandidates(request.Model, request, false)
			if len(scan.Candidates) != 1 {
				t.Fatalf("pending snapshot lost its eligible owner: %+v", scan)
			}
			return scan.Candidates[0].Quote()
		}
		retained := quote()
		if retained.FirstContent.ServiceMs != service {
			t.Fatalf("service=%v want=%v with inline-buffer spill", retained.FirstContent.ServiceMs, service)
		}
		for _, owner := range pending {
			owner.MarkContentCommitted()
		}
		if got := quote().FirstContent.ServiceMs; got != output {
			t.Fatalf("committed content changed output accounting: service=%v want=%v", got, output)
		}
		if retained.FirstContent.ServiceMs != service {
			t.Fatal("later content commitment changed a retained quote")
		}
		// Six target owners each retain 128 prompt + 64 output tokens even
		// after content has arrived. Cross the exact incoming-token boundary.
		request.RequestID = "boundary"
		p.Mu().Lock()
		p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 6*(128+64) + 128 + 64 - 1
		p.Mu().Unlock()
		if selected, _ := r.ReserveProviderEx(request.Model, request); selected != nil {
			t.Fatal("content commitment released pending memory before retirement")
		}
		p.Mu().Lock()
		p.BackendCapacity.Slots[0].ActiveTokenBudgetMax++
		p.Mu().Unlock()
		selected, decision := r.ReserveProviderEx(request.Model, request)
		if selected != p || decision.PendingForModel != 6 || decision.TotalPending != 17 {
			t.Fatalf("pending counts or exact token boundary changed: selected=%v decision=%+v", selected, decision)
		}
		p.RemovePending(request.RequestID)
		for _, owner := range pending {
			p.RemovePending(owner.RequestID)
		}
		if got := quote().FirstContent.ServiceMs; got != 0 {
			t.Fatalf("pending work survived owner retirement: %v", got)
		}
	})
}
