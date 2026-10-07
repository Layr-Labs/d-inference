package registry_test

import (
	"math"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/deadline"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/pendingload"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/serviceretirement"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestDeadlineApplicabilityRequiresExplicitReviewedPosture(t *testing.T) {
	for _, tc := range []struct {
		name   string
		change func(*production.Provider, *deadline.Profile)
	}{
		{"missing thermal", func(p *production.Provider, _ *deadline.Profile) { p.SystemMetrics.ThermalState = "" }},
		{"unknown thermal", func(p *production.Provider, _ *deadline.Profile) { p.SystemMetrics.ThermalState = "unknown" }},
		{"missing capacity telemetry", func(p *production.Provider, _ *deadline.Profile) { p.BackendCapacity.Telemetry = nil }},
		{"missing low power", func(p *production.Provider, _ *deadline.Profile) { p.BackendCapacity.Telemetry.LowPowerMode = nil }},
		{"low power", func(p *production.Provider, _ *deadline.Profile) { *p.BackendCapacity.Telemetry.LowPowerMode = true }},
		{"omitted quiescence", func(p *production.Provider, _ *deadline.Profile) {
			p.BackendCapacity.Slots[0].DeadlineProfile.MinimumWholeMacQuiescenceMS = nil
		}},
		{"different quiescence", func(p *production.Provider, _ *deadline.Profile) {
			v := 0
			p.BackendCapacity.Slots[0].DeadlineProfile.MinimumWholeMacQuiescenceMS = &v
		}},
		{"omitted stability", func(p *production.Provider, _ *deadline.Profile) {
			p.BackendCapacity.Slots[0].DeadlineProfile.MinimumNominalStabilityMS = nil
		}},
		{"different stability", func(p *production.Provider, _ *deadline.Profile) {
			v := 6000
			p.BackendCapacity.Slots[0].DeadlineProfile.MinimumNominalStabilityMS = &v
		}},
		{"different power mode", func(p *production.Provider, _ *deadline.Profile) {
			p.BackendCapacity.Slots[0].DeadlineProfile.PowerMode = "high"
		}},
		{"unreviewed missing applicability", func(_ *production.Provider, profile *deadline.Profile) { profile.MinimumWholeMacQuiescenceMS = nil }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			now := time.Now()
			f := newCalibrationPolicyFixture(t, now)
			p, profile, pr := f.provider, f.profile, f.request
			if got := f.evaluate(pr, now).Estimate; got.PredictionSource != "qualified_calibration" {
				t.Fatalf("baseline: %+v", got)
			}
			tc.change(p, profile)
			got := f.evaluate(pr, now).Estimate
			// Missing posture cannot borrow the reviewed error envelope. The
			// ordinary observed-rate forecast remains independently available.
			p.BackendCapacity.Slots[0].DeadlineProfile = nil
			fallback := f.evaluate(pr, now).Estimate
			if got.PredictionSource != "" || got != fallback {
				t.Fatalf("posture borrowed reviewed evidence: %+v; fallback: %+v", got, fallback)
			}
		})
	}
}

func TestCooledDeadlineRejectsBusyAndUnknownMacWork(t *testing.T) {
	for _, tc := range []struct {
		name   string
		change func(*production.Provider, *pendingload.Ledger, *serviceretirement.Ledger)
	}{
		{"pending", func(p *production.Provider, _ *pendingload.Ledger, _ *serviceretirement.Ledger) {
			p.AddPending(&production.PendingRequest{RequestID: "pending", Model: "model"})
		}},
		{"retirement shadow", func(_ *production.Provider, _ *pendingload.Ledger, retirement *serviceretirement.Ledger) {
			retirement.Retain("held", .1)
		}},
		{"reported service", func(p *production.Provider, _ *pendingload.Ledger, _ *serviceretirement.Ledger) {
			*p.BackendCapacity.WholeMacServiceUsed = .1
		}},
		{"unknown service", func(p *production.Provider, _ *pendingload.Ledger, _ *serviceretirement.Ledger) {
			p.BackendCapacity.WholeMacServiceUsed = nil
		}},
		{"malformed service", func(p *production.Provider, _ *pendingload.Ledger, _ *serviceretirement.Ledger) {
			*p.BackendCapacity.WholeMacServiceUsed = math.NaN()
		}},
		{"unknown work", func(p *production.Provider, _ *pendingload.Ledger, _ *serviceretirement.Ledger) {
			p.BackendCapacity.Slots[0].DeadlineWork.Known = false
		}},
		{"epoch mismatch", func(p *production.Provider, _ *pendingload.Ledger, _ *serviceretirement.Ledger) {
			p.BackendCapacity.Slots[0].DeadlineWork.Epoch = "old"
		}},
		{"running", func(p *production.Provider, _ *pendingload.Ledger, _ *serviceretirement.Ledger) {
			p.BackendCapacity.Slots[0].NumRunning = 1
		}},
		{"queued", func(p *production.Provider, _ *pendingload.Ledger, _ *serviceretirement.Ledger) {
			p.BackendCapacity.Slots[0].NumWaiting = 1
		}},
		{"eval", func(p *production.Provider, _ *pendingload.Ledger, _ *serviceretirement.Ledger) {
			p.BackendCapacity.Slots[0].EvalInFlightMs = 1
		}},
		{"maintenance", func(p *production.Provider, _ *pendingload.Ledger, _ *serviceretirement.Ledger) {
			p.BackendCapacity.Slots[0].IdleClearInFlightMs = 1
		}},
		{"load transition", func(p *production.Provider, _ *pendingload.Ledger, _ *serviceretirement.Ledger) {
			v := true
			p.BackendCapacity.LoadTransitionActive = &v
		}},
		{"unreported load", func(p *production.Provider, loads *pendingload.Ledger, _ *serviceretirement.Ledger) {
			loads.Reserve(pendingload.Key{ProviderID: p.ID, ModelID: "other"}, time.Now().Add(time.Minute), time.Time{})
		}},
		{"other unknown model", func(p *production.Provider, _ *pendingload.Ledger, _ *serviceretirement.Ledger) {
			p.BackendCapacity.Slots = append(p.BackendCapacity.Slots, protocol.BackendSlotCapacity{Model: "other", State: "idle"})
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			now := time.Now()
			loads, retirement := &pendingload.Ledger{}, &serviceretirement.Ledger{}
			f := newCalibrationPolicyFixtureWithDependencies(t, now, func(deps *production.Dependencies) {
				deps.PendingLoads = loads
				deps.ServiceRetirements = func(string) *serviceretirement.Ledger { return retirement }
			})
			tc.change(f.provider, loads, retirement)
			if f.deadlineApplicable(f.profile, now) || f.evaluate(f.request, now).Estimate.PredictionSource != "" {
				t.Fatal("busy or unknown Mac qualified for cooled cells")
			}
		})
	}
}

func TestCooledDeadlineWaitsAfterTerminalAndActualRetirement(t *testing.T) {
	for _, tracked := range []bool{false, true} {
		t.Run(map[bool]string{false: "never handed off", true: "delayed retirement"}[tracked], func(t *testing.T) {
			now := time.Now()
			posture := newDeadlineObservations()
			f := newCalibrationPolicyFixtureWithDependencies(t, now, posture.configure)
			r, p, profile, pr := f.registry, f.provider, f.profile, f.request
			before := f.evaluate(pr, now).Estimate
			if tracked {
				capacity := p.BackendCapacitySnapshot()
				capacity.WholeMacServiceRetirementProtocol = 1
				if !r.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: capacity, SystemMetrics: p.SystemMetrics}) {
					t.Fatal("retirement capability heartbeat rejected")
				}
			}
			active := &production.PendingRequest{RequestID: "previous", Model: "model", ProviderID: p.ID}
			p.AddPending(active)
			if tracked {
				if err := p.NewInferenceHandoff(active).Authorize(); err != nil {
					t.Fatal(err)
				}
			}
			p.RemovePending(active.RequestID)
			// Reuse the same fresh idle frame. Consumer terminal cannot make it
			// valid again, even for a never-acquired pipeline.
			end := posture.forProvider(p.ID).lastActivity()
			if f.deadlineApplicable(profile, end) {
				t.Fatal("terminal immediately restored cooled evidence")
			}
			if tracked {
				if f.deadlineApplicable(profile, end.Add(time.Minute)) {
					t.Fatal("time released a real retirement shadow")
				}
				if !r.ReleaseServiceReservation(p, active.ServiceReservationID()) {
					t.Fatal("release proof rejected")
				}
				end = posture.forProvider(p.ID).lastActivity()
				if r.ReleaseServiceReservation(p, active.ServiceReservationID()) || posture.forProvider(p.ID).lastActivity() != end {
					t.Fatal("duplicate release reset cooldown")
				}
			}
			for _, delta := range []time.Duration{-time.Second, 0, 20*time.Second - time.Nanosecond} {
				if f.deadlineApplicable(profile, end.Add(delta)) {
					t.Fatalf("premature recovery after %v", delta)
				}
			}
			if !f.deadlineApplicable(profile, end.Add(20*time.Second)) {
				t.Fatal("qualified idle provider never recovered")
			}
			// Fallback leaves the original deadline intact.
			after := f.evaluate(pr, now).Estimate
			if after.PredictionSource != "" || before.BudgetMs != after.BudgetMs {
				t.Fatalf("fallback changed clock: %+v vs %+v", before, after)
			}
		})
	}
}

func TestDeadlineHeartbeatInvalidationRequiresNewQuietAndStableWindows(t *testing.T) {
	now := time.Now()
	heartbeatAt := now
	f := newCalibrationPolicyFixtureWithDependencies(t, now, func(deps *production.Dependencies) {
		deps.HeartbeatNow = func() time.Time { return heartbeatAt }
	})
	r, p, profile := f.registry, f.provider, f.profile
	idle := p.BackendCapacitySnapshot()
	busy := p.BackendCapacitySnapshot()
	busy.Slots[0].DeadlineWork.Known = false
	heartbeat := func(capacity *protocol.BackendCapacity, at time.Time) {
		t.Helper()
		heartbeatAt = at
		if !r.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: capacity, SystemMetrics: p.SystemMetrics}) {
			t.Fatal("posture heartbeat rejected")
		}
	}
	heartbeat(busy, now)
	heartbeat(idle, now.Add(time.Second))
	if f.deadlineApplicable(profile, now.Add(19*time.Second)) || !f.deadlineApplicable(profile, now.Add(20*time.Second)) {
		t.Fatal("fresh idle frame erased previous unknown activity")
	}
	// The Mac has already been idle beyond 20s when the separate posture
	// invalidation starts; recovery still needs the full 5s stability window.
	lowPower := p.BackendCapacitySnapshot()
	*lowPower.Telemetry.LowPowerMode = true
	heartbeat(lowPower, now.Add(30*time.Second))
	heartbeat(idle, now.Add(31*time.Second))
	if f.deadlineApplicable(profile, now.Add(35*time.Second-time.Nanosecond)) || !f.deadlineApplicable(profile, now.Add(35*time.Second)) {
		t.Fatal("posture recovery skipped reviewed stability window")
	}
}

func TestCooledDeadlineLoadClearInvalidatesOldIdleReference(t *testing.T) {
	now := time.Now()
	posture := newDeadlineObservations()
	loads := &pendingload.Ledger{}
	f := newCalibrationPolicyFixtureWithDependencies(t, now, func(deps *production.Dependencies) {
		posture.configure(deps)
		deps.PendingLoads = loads
	})
	r, p, profile := f.registry, f.provider, f.profile
	key := pendingload.Key{ProviderID: p.ID, ModelID: "other"}
	loads.Reserve(key, now.Add(time.Minute), now)
	r.ClearPendingModelLoad(p.ID, "other")
	end := posture.forProvider(p.ID).lastActivity()
	if end.IsZero() || f.deadlineApplicable(profile, end) || !f.deadlineApplicable(profile, end.Add(20*time.Second)) {
		t.Fatal("load completion did not invalidate old idle reference")
	}
}

func TestDeadlineAcceptedHeartbeatTracksUncataloguedWorkAndRejectsOldInvalidation(t *testing.T) {
	now := time.Now()
	posture := newDeadlineObservations()
	f := newCalibrationPolicyFixtureWithDependencies(t, now, posture.configure)
	r, p, profile := f.registry, f.provider, f.profile
	p.Status, p.LastHeartbeat = production.StatusOnline, now
	busy := p.BackendCapacitySnapshot()
	busy.CapacitySeq = 2
	busy.Slots = append(busy.Slots, protocol.BackendSlotCapacity{Model: "outside-catalog", State: "running", NumRunning: 1})
	if !r.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: busy, SystemMetrics: p.SystemMetrics}) {
		t.Fatal("fresh heartbeat rejected")
	}
	end := posture.forProvider(p.ID).lastActivity()
	if end.IsZero() || len(p.BackendCapacity.Slots) != 1 {
		t.Fatal("unknown model work was lost with catalog filtering")
	}
	idle := p.BackendCapacitySnapshot()
	idle.CapacitySeq = 3
	if !r.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: idle, SystemMetrics: p.SystemMetrics}) {
		t.Fatal("fresh idle heartbeat rejected")
	}
	if posture.forProvider(p.ID).lastActivity() != end || f.deadlineApplicable(profile, end.Add(time.Second)) {
		t.Fatal("fresh idle frame erased the quiet-window fence")
	}
	// A rejected older frame must not reset either invalidation clock.
	busy.CapacitySeq = 1
	if r.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: busy}) ||
		posture.forProvider(p.ID).lastActivity() != end || !posture.forProvider(p.ID).lastInvalidation().IsZero() {
		t.Fatal("stale heartbeat changed applicability clocks")
	}
}

func TestCooledDeadlineEveryLoadExpiryPathInvalidatesOldIdleReference(t *testing.T) {
	for _, expire := range []struct {
		name string
		run  func(*production.ModelLoadPlanner, warmplan.Dependencies[production.ModelLoadAction], time.Time)
	}{
		{"legacy planner", func(planner *production.ModelLoadPlanner, _ warmplan.Dependencies[production.ModelLoadAction], now time.Time) {
			planner.Expire(now)
		}},
		{"active controller", func(_ *production.ModelLoadPlanner, planning warmplan.Dependencies[production.ModelLoadAction], now time.Time) {
			planning.PendingLoads(now)
		}},
	} {
		t.Run(expire.name, func(t *testing.T) {
			now := time.Now()
			posture := newDeadlineObservations()
			loads := &pendingload.Ledger{}
			var planner *production.ModelLoadPlanner
			var planning warmplan.Dependencies[production.ModelLoadAction]
			f := newCalibrationPolicyFixtureWithDependencies(t, now, func(deps *production.Dependencies) {
				posture.configure(deps)
				deps.PendingLoads = loads
				deps.ModelLoadPlanning = func(actual *production.ModelLoadPlanner) production.ModelLoadPlanning {
					planner = actual
					return actual
				}
				deps.WarmPlanning = func(actual warmplan.Dependencies[production.ModelLoadAction]) *warmplan.Controller[production.ModelLoadAction] {
					planning = actual
					return warmplan.NewController(actual)
				}
			})
			f.registry.ConfigureWarmPool(warmplan.Config{})
			p, profile := f.provider, f.profile
			key := pendingload.Key{ProviderID: p.ID, ModelID: "other"}
			loads.Reserve(key, now.Add(-time.Nanosecond), now.Add(-time.Minute))
			expire.run(planner, planning, now)
			if loads.HasProvider(p.ID) || posture.forProvider(p.ID).lastActivity() != now || f.deadlineApplicable(profile, now) {
				t.Fatal("expiring a load restored old cooled reference")
			}
			if !f.deadlineApplicable(profile, now.Add(20*time.Second)) {
				t.Fatal("load expiry permanently fenced idle provider")
			}
			// An empty pruning pass is not new work.
			expire.run(planner, planning, now.Add(time.Second))
			if posture.forProvider(p.ID).lastActivity() != now {
				t.Fatal("empty expiry pass reset quiet window")
			}
		})
	}
}

func TestDeadlineApplicabilityRejectsMissingAndOutOfRangeCatalogPolicy(t *testing.T) {
	for _, tc := range []struct {
		quiescence, stability int
		power                 string
		valid                 bool
	}{
		{0, 5000, "automatic", false}, {20000, 5000, "automatic", true}, {180000, 180000, "automatic", false},
		{19999, 5000, "automatic", false}, {20001, 5000, "automatic", false}, {20000, 5001, "automatic", false},
		{-1, 5000, "automatic", false}, {180001, 5000, "automatic", false}, {0, 4999, "automatic", false},
		{0, 180001, "automatic", false}, {0, 5000, "", false}, {0, 5000, "high", false},
	} {
		if got := deadline.ValidApplicability(&tc.quiescence, &tc.stability, tc.power); got != tc.valid {
			t.Fatalf("%+v: %v", tc, got)
		}
	}
	zero, five := 0, 5000
	if deadline.ValidApplicability(nil, &five, "automatic") || deadline.ValidApplicability(&zero, nil, "automatic") {
		t.Fatal("omission was treated as a zero requirement")
	}
}

func TestDeadlineDisconnectClearsOnlySessionApplicabilityClocks(t *testing.T) {
	posture := newDeadlineObservations()
	r, p := retirementProvider(t, posture.configure)
	posture.forProvider(p.ID).Activity(time.Now())
	posture.forProvider(p.ID).InvalidatePosture(time.Now())
	r.Disconnect(p.ID)
	quiescence, stability := 20000, 5000
	profile := &deadline.Profile{MinimumWholeMacQuiescenceMS: &quiescence, MinimumNominalStabilityMS: &stability, PowerMode: "automatic"}
	if !posture.forProvider(p.ID).lastActivity().IsZero() || !posture.forProvider(p.ID).lastInvalidation().IsZero() ||
		!posture.forProvider(p.ID).Allows(profile, true, time.Now()) {
		t.Fatal("disconnected session retained applicability history")
	}
}
