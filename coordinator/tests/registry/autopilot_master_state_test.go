package registry_test

import (
	"math"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/autopilotcontrol"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/autopilotstate"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/memorypolicy"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/serviceretirement"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/admission"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
)

func TestAutopilotCannotPlanOverRetiringLoadingOrUnattributedWork(t *testing.T) {
	for _, tc := range []struct {
		name   string
		change func(*production.Provider, *serviceretirement.Ledger)
	}{
		{"retirement shadow", func(_ *production.Provider, retirement *serviceretirement.Ledger) { retirement.Retain("retiring", .1) }},
		{"reported service", func(p *production.Provider, _ *serviceretirement.Ledger) {
			used := .1
			p.BackendCapacity.WholeMacServiceUsed = &used
		}},
		{"invalid service", func(p *production.Provider, _ *serviceretirement.Ledger) {
			used := math.NaN()
			p.BackendCapacity.WholeMacServiceUsed = &used
		}},
		{"unmatched service lease", func(p *production.Provider, _ *serviceretirement.Ledger) {
			used := .1
			p.BackendCapacity.WholeMacServiceUsed = &used
			p.BackendCapacity.WholeMacServiceReservations = []protocol.WholeMacServiceReservation{{ID: "6e1f61d1-e22c-4d24-a3a7-d347772a48cb", UsedFraction: .1}}
		}},
		{"load transition", func(p *production.Provider, _ *serviceretirement.Ledger) {
			active := true
			p.BackendCapacity.LoadTransitionActive = &active
		}},
		{"in-flight eval", func(p *production.Provider, _ *serviceretirement.Ledger) {
			p.BackendCapacity.Slots[0].EvalInFlightMs = 1
		}},
		{"idle clear", func(p *production.Provider, _ *serviceretirement.Ledger) {
			p.BackendCapacity.Slots[0].IdleClearInFlightMs = 1
		}},
		{"unreported token work", func(p *production.Provider, _ *serviceretirement.Ledger) {
			p.BackendCapacity.Slots[0].ActiveTokenBudgetUsed = 1
		}},
		{"unreported prompt work", func(p *production.Provider, _ *serviceretirement.Ledger) {
			queued := int64(1)
			p.BackendCapacity.Slots[0].Telemetry = &protocol.SlotTelemetry{QueuedPrefillTokens: &queued}
		}},
		{"unreported deadline work", func(p *production.Provider, _ *serviceretirement.Ledger) {
			p.BackendCapacity.Slots[0].DeadlineWork = &protocol.DeadlineWork{Known: true, RequestCount: 1}
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			retirement := &serviceretirement.Ledger{}
			r, c, now := newAutopilotControllerTest(t, false, func(deps *production.Dependencies) {
				deps.ServiceRetirements = func(string) *serviceretirement.Ledger { return retirement }
			})
			p := autopilotControllerProvider(t, r, "busy", now, autopilotTestDonor)
			if action := autopilotcontrol.Plan(c.Fleet(now), r.cfg, now); action == nil {
				t.Fatal("baseline should plan an idle load")
			}
			p.Mu().Lock()
			tc.change(p, retirement)
			p.Mu().Unlock()
			fleet := c.Fleet(now)
			if len(fleet.Demand) != 0 || len(fleet.Nodes) != 1 || fleet.Nodes[0].Idle || !fleet.Nodes[0].UnscopedBusy ||
				len(autopilot.NodeContribution(fleet.Nodes[0], fleet.Nodes[0].Residents, fleet.Demand)) != 0 ||
				autopilotcontrol.Plan(fleet, r.cfg, now) != nil {
				t.Fatalf("unattributed work supplied idle placement capacity: %+v", fleet)
			}
		})
	}
}

func TestAutopilotNativeMiMoLoadUsesCompleteCatalogQuotation(t *testing.T) {
	r, c, now := newAutopilotControllerTest(t, false)
	p := autopilotControllerProvider(t, r, "native", now)
	p.Mu().Lock()
	p.Models[0].ModelType = "mimo_v2"
	p.Models[0].NativeLoadTransientBytes = 2 << 30
	p.Models[0].EstimatedMemoryGB = float64(p.Models[0].SizeBytes+(2<<30)) / float64(uint64(1)<<30)
	p.Mu().Unlock()
	fit := c.Fleet(now).Nodes[0].Fits[autopilotTestTarget]
	p.Mu().Lock()
	if fit.WeightsGiB != p.Models[0].EstimatedMemoryGB {
		p.Mu().Unlock()
		t.Fatalf("complete native LOAD quote replaced by ordinary padding: %+v", fit)
	}
	*p.ModelAutopilot.FreeForLoadNoEvictGB = fit.WeightsGiB - .1
	p.Mu().Unlock()
	if action := autopilotcontrol.Plan(c.Fleet(now), r.cfg, now); action != nil {
		t.Fatalf("planner ignored native transient load allowance: %+v", action)
	}
}

func TestAutopilotPlacementInvalidatesDeadlineApplicabilityUntilRetired(t *testing.T) {
	posture := newDeadlineObservations()
	var receivedAt time.Time
	r, c, now := newAutopilotControllerTest(t, false, posture.configure, func(deps *production.Dependencies) {
		deps.HeartbeatNow = func() time.Time { return receivedAt }
	})
	receivedAt = now
	p := autopilotControllerProvider(t, r, "controlled", now)
	// Restore the original fixture's zero activity after establishing sequence 10.
	posture.forProvider(p.ID).Reset()
	command, ok := c.Reserve(autopilotControllerPlan(t, r, c, now), now)
	if !ok || !posture.forProvider(p.ID).lastActivity().Equal(now) {
		t.Fatal("real placement did not invalidate reviewed deadline quiescence")
	}
	finishedAt := now.Add(time.Second)
	state := autopilotControllerState(autopilotTestTarget)
	state.LastCommandID, state.LastCommandStatus = command.CommandID, protocol.LoadModelStatusSucceeded
	receivedAt = finishedAt
	r.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: autopilotControllerCapacity(11, autopilotTestTarget), ModelAutopilot: state})
	if r.states[p.ID].Transition(nil) || !posture.forProvider(p.ID).lastActivity().Equal(finishedAt) {
		t.Fatal("placement completion failed to restart reviewed quiescence window")
	}
	// The heartbeat records its own activity before reconciliation. Require both
	// callbacks so that it cannot mask a missing Autopilot completion invalidation.
	observer := posture.forProvider(p.ID)
	observer.mu.Lock()
	activityCalls := 0
	for i := len(observer.operations) - 1; i >= 0; i-- {
		if observer.operations[i].kind == "reset" {
			break
		}
		if observer.operations[i].kind == "activity" {
			activityCalls++
		}
	}
	observer.mu.Unlock()
	if activityCalls != 3 {
		t.Fatalf("activity callbacks=%d, want reservation, heartbeat and Autopilot completion", activityCalls)
	}
	var planner *production.ReservationPlanner
	pending := &autopilotstate.State{}
	_, provider, profile, _ := calibratedCandidateFixtureWithDependencies(t, now, func(deps *production.Dependencies) {
		posture.configure(deps)
		deps.AutopilotState = func(string) *autopilotstate.State { return pending }
		deps.Reservations = func(actual *production.ReservationPlanner) production.ReservationPreparation {
			planner = actual
			return actual
		}
	})
	quiescence := 20000
	profile.MinimumWholeMacQuiescenceMS = &quiescence
	provider.BackendCapacity.Slots[0].DeadlineProfile.MinimumWholeMacQuiescenceMS = &quiescence
	provider.Mu().Lock()
	pending.Reserve(protocol.ModelAutopilotMessage{}, 0, now, 0)
	provider.Mu().Unlock()
	eligibility := planner.PrepareEligibility()
	defer eligibility.Close()
	if eligibility.DeadlineApplicable(provider.ID, profile, now.Add(time.Hour)) {
		t.Fatal("pending Autopilot accepted an old cooled deadline certificate")
	}
}

func TestAutopilotCapacityUsesReviewedMasterBatchCurveWithoutExtrapolation(t *testing.T) {
	identity, profile, profiles := reviewedProfileEvidence(t)
	entry := production.CatalogEntry{ID: "model", SizeGB: 8, MinRAMGB: 16}
	evidence := autopilotcontrol.FitEvidence{
		Model: entry.ID, PrefillTPS: 2000, SoloTPS: 100,
		DecodeFloorTPS: 15, LoadFactor: effectiveTPSLoadFactor,
		Slots: identity.Capacity.Slots,
	}
	cfg := autopilot.DefaultConfig()
	demand := autopilot.DemandView{Requests: 1, PromptTokens: 600, TailPromptTokens: 600, OutputTokens: 100, RequestedMaxTokens: 100, DeadlineKnown: true}
	for _, width := range []int{16, 2} {
		identity.Capacity.Slots[0].MaxConcurrency = width
		evidence.MaxConcurrency = identity.Capacity.Slots[0].MaxConcurrency
		evidence.Profile = profiles.Qualified(identity, entry.ID)
		fit := autopilotcontrol.ModelFit(evidence, demand, cfg, func() autopilotcontrol.FitLimits {
			return autopilotcontrol.FitLimits{
				WeightsGiB:      entry.SizeGB * admission.ColdLoadCatalogGBToMemGiB,
				HardwareFits:    admission.ModelFitsHardware(entry.MinRAMGB, entry.SizeGB, float64(identity.Hardware.MemoryGB)),
				ColdTokenBudget: memorypolicy.ColdTokenBudgetWithOffload(float64(identity.Hardware.MemoryGB), entry.SizeGB, 0, 0, entry.ID),
			}
		})
		point, _ := profile.BatchAt(width)
		decode := point.AggregateDecodeTPS / float64(width)
		if point.Width != width {
			decode = point.DecodeP10TPS
		}
		want := float64(demand.PromptTokens)/point.PrefillTPS + float64(demand.OutputTokens)/decode
		if math.Abs(fit.ServiceSeconds-want) > 1e-9 {
			t.Fatalf("width=%d: stale solo heuristic displaced master's qualified curve: service=%v want=%v", width, fit.ServiceSeconds, want)
		}
	}
}
