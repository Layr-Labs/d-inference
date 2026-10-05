package registry_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// Reset runs inside Disconnect's registry write transaction. Blocking this real
// dependency holds the same lock the waiting reservation must recheck after.
type deadlineLockLifecycle struct {
	warmplan.LoadState
	entered chan struct{}
	release chan struct{}
}

func (l *deadlineLockLifecycle) Reset() {
	close(l.entered)
	<-l.release
	l.LoadState.Reset()
}

// A caller refreshes before reservation, then waits
// behind a registry writer until its absolute first-content deadline expires.
// Full scans recheck after that wait. A retained-plan reservation must too.
func TestDispatchPlanExpiryAfterRegistryLockWait(t *testing.T) {
	for _, tc := range []struct {
		name         string
		fromPlan     bool
		hard         bool
		providerLock bool
	}{
		{"full_scan_hard", false, true, false},
		{"retained_plan_hard", true, true, false},
		{"retained_plan_soft", true, false, false},
		{"retained_plan_provider_lock", true, true, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			lock := &deadlineLockLifecycle{entered: make(chan struct{}), release: make(chan struct{})}
			fixture := newPlanRegistryFixtureWithDependencies(production.Dependencies{
				WarmLifecycle: func(id string) warmplan.LoadLifecycle {
					if id == "lock-owner" {
						return lock
					}
					return &warmplan.LoadState{}
				},
			})
			reg := fixture.registry
			reg.Register("lock-owner", nil, &protocol.RegisterMessage{})
			model := "expiry-recheck-" + tc.name
			primary := fixture.provider(t, "primary", model, 0)
			alternate := fixture.provider(t, "alternate", model, 400)
			selected, _, plan := reg.ReserveProviderWithPlan(model, planTestRequest("initial", 1, 16))
			if selected == nil || selected.ID != primary.ID || plan == nil || plan.Len() != 1 {
				t.Fatal("fixture did not retain one alternate")
			}
			primary.RemovePending("initial")
			pr := planTestRequest("retry", 1, 16)
			pr.FirstContentDeadline = time.Now().Add(100 * time.Millisecond)
			if tc.hard {
				pr.MaxTTFTMs = 100
			}
			if !pr.RefreshFirstContentBudget(time.Now()) {
				t.Fatal("fixture began expired")
			}
			disconnected := make(chan struct{})
			if tc.providerLock {
				alternate.Mu().Lock()
			} else {
				go func() { reg.Disconnect("lock-owner"); close(disconnected) }()
				<-lock.entered
			}
			result := make(chan *production.Provider, 1)
			go func() {
				if tc.fromPlan {
					p, _, _ := reg.ReserveNextFromPlan(pr, plan, primary.ID)
					result <- p
					return
				}
				p, _ := reg.ReserveProviderEx(model, pr, primary.ID)
				result <- p
			}()
			<-time.After(time.Until(pr.FirstContentDeadline) + 20*time.Millisecond)
			if tc.providerLock {
				alternate.Mu().Unlock()
			} else {
				close(lock.release)
				<-disconnected
			}
			select {
			case p := <-result:
				if p != nil {
					p.RemovePending(pr.RequestID)
					t.Fatalf("reserved %q after deadline expired; stale ceiling_ms=%.0f wire_budget_ms=%d", p.ID, pr.MaxTTFTMs, pr.FirstContentBudgetMS)
				}
			case <-time.After(time.Second):
				t.Fatal("reservation did not finish after registry lock release")
			}
		})
	}
}

// A retained entry can still have time left but no longer enough for its
// prediction. Preserve soft selection while tightening the hard ceiling.
func TestDispatchPlanRefreshesRemainingPredictiveCeiling(t *testing.T) {
	for _, hard := range []bool{false, true} {
		name := "soft"
		if hard {
			name = "hard"
		}
		t.Run(name, func(t *testing.T) {
			fixture := newPlanRegistryFixture()
			reg := fixture.registry
			model := "plan-remaining-budget-" + name
			primary := fixture.provider(t, "primary", model, 0)
			alternate := fixture.provider(t, "alternate", model, 400)
			alternate.PrefillTPS = 100 // Incoming 400 tokens predict >4s.
			selected, _, plan := reg.ReserveProviderWithPlan(model, planTestRequest("initial", 1, 16))
			if selected == nil || selected.ID != primary.ID || plan == nil || plan.Len() != 1 {
				t.Fatal("fixture did not retain one alternate")
			}
			primary.RemovePending("initial")
			pr := planTestRequest("retry", 400, 16)
			now := time.Now()
			pr.FirstContentDeadline = now.Add(3 * time.Second)
			if hard {
				pr.MaxTTFTMs = 9_000
			}
			// Reproduce the caller's earlier refresh without a six-second sleep.
			if !pr.RefreshFirstContentBudget(now.Add(-6 * time.Second)) {
				t.Fatal("fixture began expired")
			}
			p, decision, _ := reg.ReserveNextFromPlan(pr, plan, primary.ID)
			if p != nil {
				defer p.RemovePending(pr.RequestID)
			}
			if pr.FirstContentBudgetMS <= 0 || pr.FirstContentBudgetMS > 3_000 {
				t.Fatalf("remaining wire budget=%d, want positive and <=3000", pr.FirstContentBudgetMS)
			}
			if hard {
				if p != nil || pr.MaxTTFTMs <= 0 || pr.MaxTTFTMs > 3_000 {
					t.Fatalf("hard reservation did not enforce remaining clock: selected=%v ceiling=%.0f", p != nil, pr.MaxTTFTMs)
				}
			} else if p == nil || pr.MaxTTFTMs != 0 || decision.TTFTMs <= float64(pr.FirstContentBudgetMS) {
				t.Fatalf("soft reservation incorrectly changed policy: selected=%v ceiling=%.0f prediction=%.0f", p != nil, pr.MaxTTFTMs, decision.TTFTMs)
			}
		})
	}
}
