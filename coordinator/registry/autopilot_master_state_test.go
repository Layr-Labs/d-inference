package registry

import (
	"math"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
)

func TestAutopilotCannotPlanOverRetiringLoadingOrUnattributedWork(t *testing.T) {
	for _, tc := range []struct {
		name   string
		change func(*Provider)
	}{
		{"retirement shadow", func(p *Provider) { p.serviceRetirementShadows = map[string]float64{"retiring": .1} }},
		{"reported service", func(p *Provider) { used := .1; p.BackendCapacity.WholeMacServiceUsed = &used }},
		{"invalid service", func(p *Provider) { used := math.NaN(); p.BackendCapacity.WholeMacServiceUsed = &used }},
		{"unmatched service lease", func(p *Provider) {
			used := .1
			p.BackendCapacity.WholeMacServiceUsed = &used
			p.BackendCapacity.WholeMacServiceReservations = []protocol.WholeMacServiceReservation{{ID: "6e1f61d1-e22c-4d24-a3a7-d347772a48cb", UsedFraction: .1}}
		}},
		{"load transition", func(p *Provider) { active := true; p.BackendCapacity.LoadTransitionActive = &active }},
		{"in-flight eval", func(p *Provider) { p.BackendCapacity.Slots[0].EvalInFlightMs = 1 }},
		{"idle clear", func(p *Provider) { p.BackendCapacity.Slots[0].IdleClearInFlightMs = 1 }},
		{"unreported token work", func(p *Provider) { p.BackendCapacity.Slots[0].ActiveTokenBudgetUsed = 1 }},
		{"unreported prompt work", func(p *Provider) {
			queued := int64(1)
			p.BackendCapacity.Slots[0].Telemetry = &protocol.SlotTelemetry{QueuedPrefillTokens: &queued}
		}},
		{"unreported deadline work", func(p *Provider) {
			p.BackendCapacity.Slots[0].DeadlineWork = &protocol.DeadlineWork{Known: true, RequestCount: 1}
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r, c, now := newAutopilotControllerTest(t, false)
			p := autopilotControllerProvider(t, r, "busy", now, autopilotTestDonor)
			if action := planAutopilotAction(r.autopilotFleetSnapshot(c, now), c.config, now); action == nil {
				t.Fatal("baseline should plan an idle load")
			}
			p.mu.Lock()
			tc.change(p)
			p.mu.Unlock()
			fleet := r.autopilotFleetSnapshot(c, now)
			if len(fleet.Demand) != 0 || len(fleet.Nodes) != 1 || fleet.Nodes[0].Idle || !fleet.Nodes[0].UnscopedBusy ||
				len(autopilot.NodeContribution(fleet.Nodes[0], fleet.Nodes[0].Residents, fleet.Demand)) != 0 ||
				planAutopilotAction(fleet, c.config, now) != nil {
				t.Fatalf("unattributed work supplied idle placement capacity: %+v", fleet)
			}
		})
	}
}

func TestAutopilotNativeMiMoLoadUsesCompleteCatalogQuotation(t *testing.T) {
	r, c, now := newAutopilotControllerTest(t, false)
	p := autopilotControllerProvider(t, r, "native", now)
	p.mu.Lock()
	p.Models[0].ModelType = "mimo_v2"
	p.Models[0].NativeLoadTransientBytes = 2 << 30
	p.Models[0].EstimatedMemoryGB = float64(p.Models[0].SizeBytes+(2<<30)) / float64(uint64(1)<<30)
	fit := r.autopilotModelFitLocked(p, autopilotTestTarget, autopilot.DemandView{}, c.config)
	if fit.WeightsGiB != p.Models[0].EstimatedMemoryGB {
		p.mu.Unlock()
		t.Fatalf("complete native LOAD quote replaced by ordinary padding: %+v", fit)
	}
	*p.ModelAutopilot.FreeForLoadNoEvictGB = fit.WeightsGiB - .1
	p.mu.Unlock()
	if action := planAutopilotAction(r.autopilotFleetSnapshot(c, now), c.config, now); action != nil {
		t.Fatalf("planner ignored native transient load allowance: %+v", action)
	}
}

func TestAutopilotPlacementInvalidatesDeadlineApplicabilityUntilRetired(t *testing.T) {
	r, c, now := newAutopilotControllerTest(t, false)
	p := autopilotControllerProvider(t, r, "controlled", now)
	command, ok := r.reserveAutopilotAction(c, autopilotControllerPlan(t, r, c, now), now)
	if !ok || !p.deadlineActivityAt.Equal(now) {
		t.Fatal("real placement did not invalidate reviewed deadline quiescence")
	}
	finishedAt := now.Add(time.Second)
	state := autopilotControllerState(autopilotTestTarget)
	state.LastCommandID, state.LastCommandStatus = command.CommandID, protocol.LoadModelStatusSucceeded
	p.mu.Lock()
	p.capacitySeq = 11
	p.BackendCapacity = autopilotControllerCapacity(11, autopilotTestTarget)
	r.reconcileAutopilotHeartbeatLocked(p, state, p.BackendCapacity, finishedAt)
	p.mu.Unlock()
	if p.autopilotPending != nil || !p.deadlineActivityAt.Equal(finishedAt) {
		t.Fatal("placement completion failed to restart reviewed quiescence window")
	}
	cooled, provider, profile, _ := cooledDeadlineFixture(t, now)
	provider.autopilotPending = &autopilotPendingCommand{}
	if cooled.deadlineProfileApplicableLocked(provider, profile, now.Add(time.Hour)) {
		t.Fatal("pending Autopilot accepted an old cooled deadline certificate")
	}
}

func TestAutopilotCapacityUsesReviewedMasterBatchCurveWithoutExtrapolation(t *testing.T) {
	p, profile := reviewedProfileFixture(t)
	r := New(testLogger())
	r.SetModelCatalog([]CatalogEntry{{ID: "model", SizeGB: 8, MinRAMGB: 16}})
	p.PrefillTPS, p.DecodeTPS = 2000, 100
	cfg := autopilot.DefaultConfig()
	demand := autopilot.DemandView{Requests: 1, PromptTokens: 600, TailPromptTokens: 600, OutputTokens: 100, RequestedMaxTokens: 100, DeadlineKnown: true}
	for _, width := range []int{16, 2} {
		p.BackendCapacity.Slots[0].MaxConcurrency = width
		fit := r.autopilotModelFitLocked(p, "model", demand, cfg)
		point, _ := profile.batchAt(width)
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
