package registry_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestWholeMacServiceReconcilesFreshReservations(t *testing.T) {
	reg, p, _ := reviewedServingProvider(t)
	overlap := &production.PendingRequest{RequestID: "overlap", Model: "model"}
	p.AddPending(overlap)
	now := time.Now()
	used := 14.0 / 16
	p.Mu().Lock()
	p.CapacityAcceptedAt = now
	p.BackendCapacity.WholeMacServiceUsed = &used
	p.BackendCapacity.WholeMacServiceReservations = []protocol.WholeMacServiceReservation{{
		ID: overlap.ServiceReservationID(), UsedFraction: 1.0 / 16,
	}}
	p.Mu().Unlock()
	p.AddPending(&production.PendingRequest{RequestID: "fresh", Model: "model"})
	headroom := func() bool {
		candidates, _, _ := reg.QuickCapacityCheck("model", 0, 1, production.RequestTraits{})
		return candidates == 1
	}
	if !headroom() {
		t.Fatal("last whole-Mac slot unavailable")
	}
	p.AddPending(&production.PendingRequest{RequestID: "another", Model: "model"})
	if headroom() {
		t.Fatal("fresh work double-spent reported allowance")
	}
	p.RemovePending("another")
	if !headroom() {
		t.Fatal("retired reservation did not release headroom")
	}
	p.Mu().Lock()
	used = 1
	p.Mu().Unlock()
	if headroom() {
		t.Fatal("other-model allowance ignored")
	}
}

func TestWholeMacServiceChargeSurvivesProfileWithdrawal(t *testing.T) {
	reg, p, _ := reviewedServingProvider(t)
	used := 14.0 / 16
	p.Mu().Lock()
	p.CapacityAcceptedAt = time.Now().Add(-time.Second)
	p.BackendCapacity.WholeMacServiceUsed = &used
	p.Mu().Unlock()
	p.AddPending(&production.PendingRequest{RequestID: "one", Model: "model"})
	p.AddPending(&production.PendingRequest{RequestID: "two", Model: "model"})
	p.Mu().Lock()
	p.BackendCapacity.Slots[0].PerformanceProfile = nil
	p.Mu().Unlock()
	if candidates, _, _ := reg.QuickCapacityCheck("model", 0, 1, production.RequestTraits{}); candidates != 0 {
		t.Fatal("withdrawing the profile discounted outstanding reservation charges")
	}
}
