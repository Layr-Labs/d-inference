package faultstate

import (
	"testing"
	"time"
)

func TestZeroValueViewAndPendingTransactionsHaveNoState(t *testing.T) {
	var view View[string]
	now := time.Now()
	if view.Present() || view.Key() != "" || view.Moved() || view.Rereads() != 0 || view.Forwarded() {
		t.Fatal("empty view retained a binding")
	}
	if view.BreakerOpenAt(now.UnixNano()) || view.EjectedAt(now.UnixNano()) || view.DispatchLoadCooled("m", now) || view.InferenceErrorCooled("m", "base", now) || view.CapacityCooled("m", now) || view.HasCapacityCooldown() || view.BudgetClampActive("m", now, 0, false, now) || view.EjectionOpenFor("serial:unknown", now.UnixNano()) {
		t.Fatal("empty view gated an unknown identity")
	}
	if penalty, rate := view.CapacityRatePenalty("m", now); penalty != 0 || rate != 0 {
		t.Fatalf("empty view penalty/rate = %v/%v", penalty, rate)
	}
	var accept CapacityAccept[string]
	if accept.NeedsBudgetSnapshot() || accept.Apply(now, 0, false) {
		t.Fatal("empty accept recorded an outcome")
	}
	var probe CapacityProbe[string]
	if probe.View().Present() || !probe.Claim("m", now) {
		t.Fatal("empty probe gated an unknown identity")
	}
}
