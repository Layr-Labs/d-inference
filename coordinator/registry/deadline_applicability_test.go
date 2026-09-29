package registry

import (
	"math"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func cooledDeadlineFixture(t *testing.T, now time.Time) (*Registry, *Provider, *deadlinePerformanceProfile, *PendingRequest) {
	t.Helper()
	r, p, profile, pr := calibratedCandidateFixture(t, now)
	quiescence := 20000
	profile.MinimumWholeMacQuiescenceMS = &quiescence
	p.BackendCapacity.Slots[0].DeadlineProfile.MinimumWholeMacQuiescenceMS = &quiescence
	p.ID = "cooled-provider"
	r.providers[p.ID] = p
	return r, p, profile, pr
}

func TestDeadlineApplicabilityRequiresExplicitReviewedPosture(t *testing.T) {
	for _, tc := range []struct {
		name   string
		change func(*Provider, *deadlinePerformanceProfile)
	}{
		{"missing thermal", func(p *Provider, _ *deadlinePerformanceProfile) { p.SystemMetrics.ThermalState = "" }},
		{"unknown thermal", func(p *Provider, _ *deadlinePerformanceProfile) { p.SystemMetrics.ThermalState = "unknown" }},
		{"missing capacity telemetry", func(p *Provider, _ *deadlinePerformanceProfile) { p.BackendCapacity.Telemetry = nil }},
		{"missing low power", func(p *Provider, _ *deadlinePerformanceProfile) { p.BackendCapacity.Telemetry.LowPowerMode = nil }},
		{"low power", func(p *Provider, _ *deadlinePerformanceProfile) { *p.BackendCapacity.Telemetry.LowPowerMode = true }},
		{"omitted quiescence", func(p *Provider, _ *deadlinePerformanceProfile) {
			p.BackendCapacity.Slots[0].DeadlineProfile.MinimumWholeMacQuiescenceMS = nil
		}},
		{"different quiescence", func(p *Provider, _ *deadlinePerformanceProfile) {
			v := 0
			p.BackendCapacity.Slots[0].DeadlineProfile.MinimumWholeMacQuiescenceMS = &v
		}},
		{"omitted stability", func(p *Provider, _ *deadlinePerformanceProfile) {
			p.BackendCapacity.Slots[0].DeadlineProfile.MinimumNominalStabilityMS = nil
		}},
		{"different stability", func(p *Provider, _ *deadlinePerformanceProfile) {
			v := 6000
			p.BackendCapacity.Slots[0].DeadlineProfile.MinimumNominalStabilityMS = &v
		}},
		{"different power mode", func(p *Provider, _ *deadlinePerformanceProfile) {
			p.BackendCapacity.Slots[0].DeadlineProfile.PowerMode = "high"
		}},
		{"unreviewed missing applicability", func(_ *Provider, profile *deadlinePerformanceProfile) { profile.MinimumWholeMacQuiescenceMS = nil }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			now := time.Now()
			r, p, profile, pr := cooledDeadlineFixture(t, now)
			if got := calibratedForecast(r, p, pr, now).firstContent; got.PredictionSource != "qualified_calibration" {
				t.Fatalf("baseline: %+v", got)
			}
			tc.change(p, profile)
			if got := calibratedForecast(r, p, pr, now).firstContent; got.PredictionSource != "" || got.ConservativeMs < 5500 {
				t.Fatalf("posture borrowed optimistic evidence: %+v", got)
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
		{0, 5000, "automatic", true}, {20000, 5000, "automatic", true}, {180000, 180000, "automatic", true},
		{-1, 5000, "automatic", false}, {180001, 5000, "automatic", false}, {0, 4999, "automatic", false},
		{0, 180001, "automatic", false}, {0, 5000, "", false}, {0, 5000, "high", false},
	} {
		if got := validDeadlineApplicability(&tc.quiescence, &tc.stability, tc.power); got != tc.valid {
			t.Fatalf("%+v: %v", tc, got)
		}
	}
	zero, five := 0, 5000
	if validDeadlineApplicability(nil, &five, "automatic") || validDeadlineApplicability(&zero, nil, "automatic") {
		t.Fatal("omission was treated as a zero requirement")
	}
}

func TestCooledDeadlineRejectsBusyAndUnknownMacWork(t *testing.T) {
	for _, tc := range []struct {
		name   string
		change func(*Registry, *Provider)
	}{
		{"pending", func(_ *Registry, p *Provider) { p.AddPending(&PendingRequest{RequestID: "pending", Model: "model"}) }},
		{"retirement shadow", func(_ *Registry, p *Provider) { p.serviceRetirementShadows = map[string]float64{"held": .1} }},
		{"reported service", func(_ *Registry, p *Provider) { *p.BackendCapacity.WholeMacServiceUsed = .1 }},
		{"unknown service", func(_ *Registry, p *Provider) { p.BackendCapacity.WholeMacServiceUsed = nil }},
		{"malformed service", func(_ *Registry, p *Provider) { *p.BackendCapacity.WholeMacServiceUsed = math.NaN() }},
		{"unknown work", func(_ *Registry, p *Provider) { p.BackendCapacity.Slots[0].DeadlineWork.Known = false }},
		{"epoch mismatch", func(_ *Registry, p *Provider) { p.BackendCapacity.Slots[0].DeadlineWork.Epoch = "old" }},
		{"running", func(_ *Registry, p *Provider) { p.BackendCapacity.Slots[0].NumRunning = 1 }},
		{"queued", func(_ *Registry, p *Provider) { p.BackendCapacity.Slots[0].NumWaiting = 1 }},
		{"eval", func(_ *Registry, p *Provider) { p.BackendCapacity.Slots[0].EvalInFlightMs = 1 }},
		{"maintenance", func(_ *Registry, p *Provider) { p.BackendCapacity.Slots[0].IdleClearInFlightMs = 1 }},
		{"load transition", func(_ *Registry, p *Provider) { v := true; p.BackendCapacity.LoadTransitionActive = &v }},
		{"unreported load", func(r *Registry, p *Provider) {
			r.pendingModelLoads[modelLoadKey{ProviderID: p.ID, ModelID: "other"}] = time.Now().Add(time.Minute)
		}},
		{"other unknown model", func(_ *Registry, p *Provider) {
			p.BackendCapacity.Slots = append(p.BackendCapacity.Slots, protocol.BackendSlotCapacity{Model: "other", State: "idle"})
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			now := time.Now()
			r, p, profile, pr := cooledDeadlineFixture(t, now)
			tc.change(r, p)
			if r.deadlineProfileApplicableLocked(p, profile, now) || calibratedForecast(r, p, pr, now).firstContent.PredictionSource != "" {
				t.Fatal("busy or unknown Mac qualified for cooled cells")
			}
		})
	}
}

func TestCooledDeadlineWaitsAfterTerminalAndActualRetirement(t *testing.T) {
	for _, tracked := range []bool{false, true} {
		t.Run(map[bool]string{false: "never handed off", true: "delayed retirement"}[tracked], func(t *testing.T) {
			now := time.Now()
			r, p, profile, pr := cooledDeadlineFixture(t, now)
			before := calibratedForecast(r, p, pr, now).firstContent
			p.serviceRetirementProtocol = tracked
			active := &PendingRequest{RequestID: "previous", Model: "model"}
			p.AddPending(active)
			active.serviceHandoffAuthorized = tracked
			p.RemovePending(active.RequestID)
			// Reuse the same fresh idle frame. Consumer terminal cannot make it
			// valid again, even for a never-acquired pipeline.
			end := p.deadlineActivityAt
			if r.deadlineProfileApplicableLocked(p, profile, end) {
				t.Fatal("terminal immediately restored cooled evidence")
			}
			if tracked {
				if r.deadlineProfileApplicableLocked(p, profile, end.Add(time.Minute)) {
					t.Fatal("time released a real retirement shadow")
				}
				if !r.ReleaseServiceReservation(p, active.ServiceReservationID()) {
					t.Fatal("release proof rejected")
				}
				end = p.deadlineActivityAt
				if r.ReleaseServiceReservation(p, active.ServiceReservationID()) || p.deadlineActivityAt != end {
					t.Fatal("duplicate release reset cooldown")
				}
			}
			for _, delta := range []time.Duration{-time.Second, 0, 20*time.Second - time.Nanosecond} {
				if r.deadlineProfileApplicableLocked(p, profile, end.Add(delta)) {
					t.Fatalf("premature recovery after %v", delta)
				}
			}
			if !r.deadlineProfileApplicableLocked(p, profile, end.Add(20*time.Second)) {
				t.Fatal("qualified idle provider never recovered")
			}
			// Fallback leaves the original deadline intact.
			after := calibratedForecast(r, p, pr, now).firstContent
			if after.PredictionSource != "" || before.BudgetMs != after.BudgetMs {
				t.Fatalf("fallback changed clock: %+v vs %+v", before, after)
			}
		})
	}
}

func TestDeadlineHeartbeatInvalidationRequiresNewQuietAndStableWindows(t *testing.T) {
	now := time.Now()
	r, p, profile, _ := cooledDeadlineFixture(t, now)
	idle := p.BackendCapacitySnapshot()
	busy := p.BackendCapacitySnapshot()
	busy.Slots[0].DeadlineWork.Known = false
	p.reconcileDeadlineApplicabilityLocked(busy, p.SystemMetrics, now)
	p.reconcileDeadlineApplicabilityLocked(idle, p.SystemMetrics, now.Add(time.Second))
	if r.deadlineProfileApplicableLocked(p, profile, now.Add(19*time.Second)) || !r.deadlineProfileApplicableLocked(p, profile, now.Add(20*time.Second)) {
		t.Fatal("fresh idle frame erased previous unknown activity")
	}
	zero := 0
	profile.MinimumWholeMacQuiescenceMS = &zero
	p.BackendCapacity.Slots[0].DeadlineProfile.MinimumWholeMacQuiescenceMS = &zero
	lowPower := p.BackendCapacitySnapshot()
	*lowPower.Telemetry.LowPowerMode = true
	p.reconcileDeadlineApplicabilityLocked(lowPower, p.SystemMetrics, now.Add(30*time.Second))
	p.reconcileDeadlineApplicabilityLocked(idle, p.SystemMetrics, now.Add(31*time.Second))
	if r.deadlineProfileApplicableLocked(p, profile, now.Add(35*time.Second-time.Nanosecond)) || !r.deadlineProfileApplicableLocked(p, profile, now.Add(35*time.Second)) {
		t.Fatal("posture recovery skipped reviewed stability window")
	}
}

func TestCooledDeadlineLoadClearInvalidatesOldIdleReference(t *testing.T) {
	now := time.Now()
	r, p, profile, _ := cooledDeadlineFixture(t, now)
	key := modelLoadKey{ProviderID: p.ID, ModelID: "other"}
	r.pendingModelLoads[key] = now.Add(time.Minute)
	r.pendingModelLoadStarted[key] = now
	r.ClearPendingModelLoad(p.ID, "other")
	end := p.deadlineActivityAt
	if end.IsZero() || r.deadlineProfileApplicableLocked(p, profile, end) || !r.deadlineProfileApplicableLocked(p, profile, end.Add(20*time.Second)) {
		t.Fatal("load completion did not invalidate old idle reference")
	}
}

func TestDeadlineAcceptedHeartbeatTracksUncataloguedWorkAndRejectsOldInvalidation(t *testing.T) {
	now := time.Now()
	r, p, profile, _ := cooledDeadlineFixture(t, now)
	p.Status, p.LastHeartbeat = StatusOnline, now
	busy := p.BackendCapacitySnapshot()
	busy.CapacitySeq = 2
	busy.Slots = append(busy.Slots, protocol.BackendSlotCapacity{Model: "outside-catalog", State: "running", NumRunning: 1})
	if !r.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: busy, SystemMetrics: p.SystemMetrics}) {
		t.Fatal("fresh heartbeat rejected")
	}
	end := p.deadlineActivityAt
	if end.IsZero() || len(p.BackendCapacity.Slots) != 1 {
		t.Fatal("unknown model work was lost with catalog filtering")
	}
	idle := p.BackendCapacitySnapshot()
	idle.CapacitySeq = 3
	if !r.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: idle, SystemMetrics: p.SystemMetrics}) {
		t.Fatal("fresh idle heartbeat rejected")
	}
	if p.deadlineActivityAt != end || r.deadlineProfileApplicableLocked(p, profile, end.Add(time.Second)) {
		t.Fatal("fresh idle frame erased the quiet-window fence")
	}
	// A rejected older frame must not reset either invalidation clock.
	busy.CapacitySeq = 1
	if r.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: busy}) ||
		p.deadlineActivityAt != end || !p.deadlinePostureInvalidAt.IsZero() {
		t.Fatal("stale heartbeat changed applicability clocks")
	}
}

func TestDeadlineDisconnectClearsOnlySessionApplicabilityClocks(t *testing.T) {
	r, p := retirementProvider(t)
	p.deadlineActivityAt, p.deadlinePostureInvalidAt = time.Now(), time.Now()
	r.Disconnect(p.ID)
	if !p.deadlineActivityAt.IsZero() || !p.deadlinePostureInvalidAt.IsZero() {
		t.Fatal("disconnected session retained applicability history")
	}
}

func TestCooledDeadlineEveryLoadExpiryPathInvalidatesOldIdleReference(t *testing.T) {
	for _, expire := range []struct {
		name string
		run  func(*Registry, time.Time)
	}{
		{"legacy planner", func(r *Registry, now time.Time) { r.expirePendingModelLoads(now) }},
		{"active controller", func(r *Registry, now time.Time) { r.pendingModelLoadCount(now) }},
	} {
		t.Run(expire.name, func(t *testing.T) {
			now := time.Now()
			r, p, profile, _ := cooledDeadlineFixture(t, now)
			key := modelLoadKey{ProviderID: p.ID, ModelID: "other"}
			r.pendingModelLoads[key] = now.Add(-time.Nanosecond)
			r.pendingModelLoadStarted[key] = now.Add(-time.Minute)
			expire.run(r, now)
			if r.providerHasPendingLoad(p.ID) || p.deadlineActivityAt != now || r.deadlineProfileApplicableLocked(p, profile, now) {
				t.Fatal("expiring a load restored old cooled reference")
			}
			if !r.deadlineProfileApplicableLocked(p, profile, now.Add(20*time.Second)) {
				t.Fatal("load expiry permanently fenced idle provider")
			}
			// An empty pruning pass is not new work.
			expire.run(r, now.Add(time.Second))
			if p.deadlineActivityAt != now {
				t.Fatal("empty expiry pass reset quiet window")
			}
		})
	}
}
