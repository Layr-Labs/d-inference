package registry

import (
	"testing"
	"time"
)

// Exercise correlation through the real reservation, heartbeat, writer and
// registry reply binding. A forged reply must leave the bound probe usable;
// the bound reply must update its plan before its outcome is readable.
func TestDispatchPlanProbeRejectsWrongProviderBeforeBoundReply(t *testing.T) {
	reg := New(testLogger())
	model := "probe-binding-model"
	primary := planTestProvider(t, reg, "primary", model, 0)
	alternate := planTestProvider(t, reg, "alternate", model, 400)
	selected, _, plan := reg.ReserveProviderWithPlan(model, planTestRequest("binding-primary", 500, 256))
	if selected != primary || plan == nil || plan.Len() != 1 {
		t.Fatal("fixture did not retain the alternate")
	}
	t.Cleanup(func() { primary.RemovePending("binding-primary") })
	// Preserve the same model/capacity snapshot while proving this connection
	// speaks the quote protocol through the actual heartbeat transition.
	alternate.mu.Lock()
	capacity := *alternate.BackendCapacity
	alternate.mu.Unlock()
	capacity.CapacitySeq = 1
	hb := seqHeartbeat(1, 0)
	hb.BackendCapacity = &capacity
	reg.Heartbeat(alternate.ID, hb)
	if !alternate.capacityQuoteReady() {
		t.Fatal("heartbeat did not establish quote capability")
	}
	conn := attachTestWriter(t, alternate)
	outcomes := reg.ProbePlanCandidates(plan, CapacityProbeShape{Model: model, PromptTokens: 700, MaxOutputTokens: 256}, 5*time.Second)
	probe := readProbeFrame(t, conn)
	quote := testQuote(probe.QuoteID, true, 725)
	reg.HandleCapacityQuote(primary.ID, quote)
	select {
	case o := <-outcomes:
		t.Fatalf("wrong provider settled the bound probe: %+v", o)
	default:
	}
	if _, _, ok := plan.BestConfirmedBackup(); ok {
		t.Fatal("wrong provider confirmed the alternate")
	}
	reg.HandleCapacityQuote(alternate.ID, quote)
	select {
	case o, ok := <-outcomes:
		if !ok || o.ProviderID != alternate.ID || o.Quote != quote || o.Timeout || o.SendFailed {
			t.Fatalf("bound outcome = %+v, open=%v", o, ok)
		}
		id, p90, confirmed := plan.BestConfirmedBackup()
		if !confirmed || id != alternate.ID || p90 != 725*time.Millisecond {
			t.Fatalf("plan was not confirmed before publication: %q %v %v", id, p90, confirmed)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("bound reply did not settle the probe")
	}
	select {
	case _, ok := <-outcomes:
		if ok {
			t.Fatal("probe settled more than once")
		}
	case <-time.After(time.Second):
		t.Fatal("collector did not close after bound reply")
	}
}

// Nil and zero-value wrappers have distinct public refresh/attempted semantics.
// Keep those guards outside the inline owner without exposing its state.
func TestDispatchPlanNilAndZeroValueBindings(t *testing.T) {
	for _, tc := range []struct {
		name    string
		plan    *DispatchPlan
		nilPlan bool
	}{
		{"nil", nil, true}, {"zero", &DispatchPlan{}, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			plan := tc.plan
			if plan.Model() != "" || plan.Len() != 0 || plan.Remaining() != 0 || plan.EligibleCount() != 0 || plan.AdmissibleCount() != 0 || plan.DeadlineFeasibleCount() != 0 {
				t.Fatal("empty plan reported scan state")
			}
			if entry, ok := plan.PeekNext(); ok || entry != (PlanEntry{}) {
				t.Fatalf("empty peek: %+v %v", entry, ok)
			}
			if plan.RefreshUsed() != tc.nilPlan {
				t.Fatalf("refresh used=%v, want %v", plan.RefreshUsed(), tc.nilPlan)
			}
			ids := plan.AttemptedProviderIDs()
			if len(ids) != 0 || (ids == nil) != tc.nilPlan {
				t.Fatalf("attempted IDs=%v, nil=%v, want nil=%v", ids, ids == nil, tc.nilPlan)
			}
			plan.ConfirmEntry("absent", nil)
			plan.DemoteEntry("absent")
			if id, p90, ok := plan.BestConfirmedBackup(); id != "" || p90 != 0 || ok {
				t.Fatalf("empty backup: %q %v %v", id, p90, ok)
			}
			// The original empty-target fast path never touches registry dependencies.
			var reg *Registry
			select {
			case _, ok := <-reg.ProbePlanCandidates(plan, CapacityProbeShape{}, time.Second):
				if ok {
					t.Fatal("empty probe emitted outcome")
				}
			case <-time.After(time.Second):
				t.Fatal("empty probe did not close")
			}
		})
	}
}
