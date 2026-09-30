package registry

import (
	"sync"
	"testing"
	"time"
)

func TestFirstContentExplorationWaitsForServiceRetirement(t *testing.T) {
	for _, selection := range []string{"scan", "retained_plan", "commit_race"} {
		for _, ownership := range []string{"reported_service", "terminal_shadow"} {
			t.Run(selection+"/"+ownership, func(t *testing.T) {
				r := New(testLogger())
				const model = "exploration-service"
				qualified, idle := explorationPair(t, r, model, func(p *Provider, now time.Time) {
					p.firstContentMeasurements = nil
					p.registeredAt = now.Add(-10 * time.Minute)
					used := 0.0
					p.BackendCapacity.WholeMacServiceUsed = &used
					p.serviceRetirementProtocol = true
				})
				var held *PendingRequest
				acquire := func() {
					if ownership == "reported_service" {
						idle.mu.Lock()
						*idle.BackendCapacity.WholeMacServiceUsed = 1.0 / 24
						idle.mu.Unlock()
						return
					}
					held = planTestRequest("retiring", 500, 128)
					held.Model = model
					idle.AddPending(held)
					idle.mu.Lock()
					held.serviceHandoffAuthorized = true
					idle.mu.Unlock()
					idle.RemovePending(held.RequestID)
					idle.mu.Lock()
					shadows := len(idle.serviceRetirementShadows)
					idle.mu.Unlock()
					if shadows != 1 || idle.PendingCount() != 0 {
						t.Fatal("terminal must retain its lease without a pending request")
					}
				}
				if selection == "commit_race" {
					var once sync.Once
					r.reservationAfterScan = func(string) { once.Do(acquire) }
				} else {
					acquire()
				}

				pr := deadlineRequest()
				var selected *Provider
				if selection == "retained_plan" {
					plan := &DispatchPlan{model: model, attempted: map[string]struct{}{}, entries: []planEntry{
						{provider: idle, view: PlanEntry{ProviderID: idle.ID}},
						{provider: qualified, view: PlanEntry{ProviderID: qualified.ID}},
					}}
					selected, _, _ = r.ReserveNextFromPlan(pr, plan)
				} else {
					selected, _ = r.ReserveProviderEx(model, pr)
				}
				if selected != qualified {
					t.Fatal("exploration selected a provider that still owns service")
				}
				if idle.GetPending(pr.RequestID) != nil {
					t.Fatal("rejected exploration left a pending reservation")
				}
				qualified.RemovePending(pr.RequestID)
				r.reservationAfterScan = nil

				if held != nil {
					if !r.ReleaseServiceReservation(idle, held.ServiceReservationID()) {
						t.Fatal("exploration discarded the terminal lease before retirement")
					}
				} else {
					idle.mu.Lock()
					*idle.BackendCapacity.WholeMacServiceUsed = 0
					idle.mu.Unlock()
				}
				if selected, _ := r.ReserveProviderEx(model, deadlineRequest()); selected != idle {
					t.Fatal("retired provider did not regain exploration eligibility")
				}
			})
		}
	}
}
