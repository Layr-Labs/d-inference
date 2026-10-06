package registry_test

import (
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/measurements"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/serviceretirement"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestFirstContentExplorationWaitsForServiceRetirement(t *testing.T) {
	for _, selection := range []string{"scan", "retained_plan", "commit_race"} {
		for _, ownership := range []string{"reported_service", "terminal_shadow"} {
			t.Run(selection+"/"+ownership, func(t *testing.T) {
				preparation := &reservationPreparationFixture{}
				retirement := &serviceretirement.Ledger{}
				const model = "exploration-service"
				fixture := newExplorationPair(t, model, 10*time.Minute, func(p *production.Provider, history *measurements.History, now time.Time) {
					history.Reset()
					used := 0.0
					p.BackendCapacity.WholeMacServiceUsed = &used
				}, func(deps *production.Dependencies) {
					deps.Reservations = func(planner *production.ReservationPlanner) production.ReservationPreparation {
						preparation.planner = planner
						return preparation
					}
					deps.ServiceRetirements = func(id string) *serviceretirement.Ledger {
						if id == "idle" {
							return retirement
						}
						return &serviceretirement.Ledger{}
					}
				})
				r, qualified, idle := fixture.registry, fixture.qualified, fixture.idle
				capacity := idle.BackendCapacitySnapshot()
				capacity.CapacitySeq, capacity.WholeMacServiceRetirementProtocol = 1, 1
				r.Heartbeat(idle.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: capacity})
				idle.Mu().Lock()
				fixture.history.Reset()
				idle.Mu().Unlock()
				plan := preparation.planner.ScanCandidates(model, planTestRequest("request", 500, 128), false).Plan(model, nil)
				var held *production.PendingRequest
				acquire := func() {
					if ownership == "reported_service" {
						idle.Mu().Lock()
						*idle.BackendCapacity.WholeMacServiceUsed = 1.0 / 24
						idle.Mu().Unlock()
						return
					}
					held = planTestRequest("retiring", 500, 128)
					held.Model, held.ProviderID = model, idle.ID
					idle.AddPending(held)
					if err := idle.NewInferenceHandoff(held).Authorize(); err != nil {
						t.Fatal(err)
					}
					idle.RemovePending(held.RequestID)
					idle.Mu().Lock()
					shadows := retirement.Account(nil).Retiring
					idle.Mu().Unlock()
					if shadows != 1 || idle.PendingCount() != 0 {
						t.Fatal("terminal must retain its lease without a pending request")
					}
				}
				if selection == "commit_race" {
					var once sync.Once
					preparation.after = func(string) { once.Do(acquire) }
				} else {
					acquire()
				}

				pr := deadlineRequest()
				var selected *production.Provider
				if selection == "retained_plan" {
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
				preparation.after = nil

				if held != nil {
					if !r.ReleaseServiceReservation(idle, held.ServiceReservationID()) {
						t.Fatal("exploration discarded the terminal lease before retirement")
					}
				} else {
					idle.Mu().Lock()
					*idle.BackendCapacity.WholeMacServiceUsed = 0
					idle.Mu().Unlock()
				}
				if selected, _ := r.ReserveProviderEx(model, deadlineRequest()); selected != idle {
					t.Fatal("retired provider did not regain exploration eligibility")
				}
			})
		}
	}
}
