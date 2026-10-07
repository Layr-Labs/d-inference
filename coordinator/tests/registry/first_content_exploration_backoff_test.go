package registry_test

import (
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/connectiontime"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/identitygate"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/measurements"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

const explorationBackoffModel = "explore-backoff"

func backoffExplorationPair(t *testing.T, configure ...func(*production.Dependencies)) (*explorationFixture, *identitygate.Directory) {
	t.Helper()
	gates := identitygate.New(testLogger(), nil)
	throughput := production.NewTPSRegistry()
	for range 50 {
		throughput.Record(explorationBackoffModel, testRegisterMessage().Hardware.ChipFamily, 80)
	}
	configure = append(configure, func(deps *production.Dependencies) {
		deps.IdentityGates, deps.Throughput = gates, throughput
	})
	f := newExplorationPair(t, explorationBackoffModel, 10*time.Minute,
		func(_ *production.Provider, history *measurements.History, _ time.Time) { history.Reset() }, configure...)
	return f, gates
}

func reserveExploration(t *testing.T, f *explorationFixture, want *production.Provider, explored bool) {
	t.Helper()
	pr := deadlineRequest()
	selected, decision := f.registry.ReserveProviderEx(explorationBackoffModel, pr)
	if selected != want || pr.FirstContentExplored() != explored {
		t.Fatalf("selected=%v explored=%v, want %s explored=%v; %+v", selected, pr.FirstContentExplored(), want.ID, explored, decision)
	}
	selected.RemovePending(pr.RequestID)
}

func TestFirstContentExplorationBackoffRecheckedByEveryReservationPath(t *testing.T) {
	for _, selection := range []string{"scan", "retained_plan", "commit_race"} {
		t.Run(selection, func(t *testing.T) {
			preparation := &reservationPreparationFixture{}
			f, _ := backoffExplorationPair(t, func(deps *production.Dependencies) {
				deps.Reservations = func(planner *production.ReservationPlanner) production.ReservationPreparation {
					preparation.planner = planner
					return preparation
				}
			})
			reserveExploration(t, f, f.idle, true)
			plan := preparation.planner.ScanCandidates(explorationBackoffModel, deadlineRequest(), false).Plan(explorationBackoffModel, nil)
			fail := func() { f.registry.RecordFirstContentExplorationOutcome(f.idle.ID, explorationBackoffModel, false) }
			if selection == "commit_race" {
				var once sync.Once
				preparation.after = func(string) { once.Do(fail) }
			} else {
				fail()
			}
			pr := deadlineRequest()
			var selected *production.Provider
			if selection == "retained_plan" {
				selected, _, _ = f.registry.ReserveNextFromPlan(pr, plan)
			} else {
				selected, _ = f.registry.ReserveProviderEx(explorationBackoffModel, pr)
			}
			if selected != f.qualified || pr.FirstContentExplored() || f.idle.GetPending(pr.RequestID) != nil {
				t.Fatalf("%s did not recheck exploration suppression: selected=%v explored=%v", selection, selected, pr.FirstContentExplored())
			}
			selected.RemovePending(pr.RequestID)
			preparation.after = nil
			f.registry.RecordFirstContentExplorationOutcome(f.idle.ID, explorationBackoffModel, true)
			reserveExploration(t, f, f.idle, true)
		})
	}
}

func TestFirstContentExplorationRememberedSlowDecodeAffectsSelection(t *testing.T) {
	f, gates := backoffExplorationPair(t)
	ref := gates.ResolveSession(f.idle.ID, true)
	for i, rate := range []float64{10, 11.7, 10.1, 11.7} {
		gates.RecordFirstContentDecodeObservation(ref, explicitDecodeObservation(explorationBackoffModel, rate, int64(i+1), time.Now()), 80, time.Now())
	}
	// Four low observations cannot recreate the single-slow-sample lockout.
	reserveExploration(t, f, f.idle, true)
	gates.RecordFirstContentDecodeObservation(ref, explicitDecodeObservation(explorationBackoffModel, 12, 5, time.Now()), 80, time.Now())
	reserveExploration(t, f, f.qualified, false)
	gates.RecordFirstContentDecodeObservation(ref, explicitDecodeObservation(explorationBackoffModel, 40, 6, time.Now()), 80, time.Now())
	reserveExploration(t, f, f.idle, true)
}

func TestFirstContentExplorationSuppressionPreservesOrdinaryFallback(t *testing.T) {
	f, _ := backoffExplorationPair(t)
	f.registry.RecordFirstContentExplorationOutcome(f.idle.ID, explorationBackoffModel, false)
	pr := deadlineRequest()
	selected, _ := f.registry.ReserveProviderEx(explorationBackoffModel, pr, f.qualified.ID)
	if selected != f.idle || pr.FirstContentExplored() {
		t.Fatalf("suppression quarantined the only candidate or tagged ordinary fallback: selected=%v explored=%v", selected, pr.FirstContentExplored())
	}
	selected.RemovePending(pr.RequestID)
	// Neither recovery nor suppression can bypass physical admission.
	f.registry.RecordFirstContentExplorationOutcome(f.idle.ID, explorationBackoffModel, true)
	f.idle.Mu().Lock()
	slot := &f.idle.BackendCapacity.Slots[0]
	slot.ActiveTokenBudgetUsed = slot.ActiveTokenBudgetMax
	f.idle.Mu().Unlock()
	if selected, _ := f.registry.ReserveProviderEx(explorationBackoffModel, deadlineRequest(), f.qualified.ID); selected != nil {
		t.Fatal("exploration bypassed the token-budget admission gate")
	}
}

func TestFirstContentExplorationHeartbeatRemembersOnlyNewDecodeObservations(t *testing.T) {
	for _, explicit := range []bool{false, true} {
		name := "legacy"
		if explicit {
			name = "explicit"
		}
		t.Run(name, func(t *testing.T) {
			f, gates := backoffExplorationPair(t)
			capacity := f.idle.BackendCapacitySnapshot()
			capacity.CapacitySeq = 1
			slot := &capacity.Slots[0]
			slot.PerformanceMeasurements = nil
			if explicit {
				slot.PerformanceMeasurements = localRateMeasurements(1200, 10)
			}
			for i, rate := range []float64{10, 10, 11, 11, 12} {
				slot.ObservedDecodeTPS = rate
				if explicit {
					slot.PerformanceMeasurements.Decode.TokensPerSecond = rate
					slot.PerformanceMeasurements.Decode.SampleCount = int64(i/2 + 1)
				}
				if !f.registry.Heartbeat(f.idle.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: capacity}) {
					t.Fatal("fresh heartbeat rejected")
				}
				capacity.CapacitySeq++
				view := gates.ViewForSession(nil, f.idle.ID).Exploration(explorationBackoffModel, time.Now())
				if want := []int{1, 1, 2, 2, 3}[i]; view.DecodeSamples != want {
					t.Fatalf("report %d rate=%v remembered %d samples, want %d", i, rate, view.DecodeSamples, want)
				}
			}
			if explicit {
				// Equal rates with higher producer sample counts are new evidence.
				slot.PerformanceMeasurements.Decode.SampleCount++
				f.registry.Heartbeat(f.idle.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: capacity})
				if got := gates.ViewForSession(nil, f.idle.ID).Exploration(explorationBackoffModel, time.Now()).DecodeSamples; got != 4 {
					t.Fatalf("higher sample count did not add evidence: %d", got)
				}
				capacity.CapacitySeq++
			}
			before := gates.ViewForSession(nil, f.idle.ID).Exploration(explorationBackoffModel, time.Now())
			stale := f.idle.BackendCapacitySnapshot()
			stale.Slots[0].ObservedDecodeTPS = 13
			if f.registry.Heartbeat(f.idle.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: stale}) {
				t.Fatal("duplicate sequence accepted")
			}
			f.registry.Heartbeat(f.idle.ID, &protocol.HeartbeatMessage{Status: "idle"})
			if after := gates.ViewForSession(nil, f.idle.ID).Exploration(explorationBackoffModel, time.Now()); after != before {
				t.Fatalf("stale or nil capacity changed remembered rates: before=%+v after=%+v", before, after)
			}
		})
	}
}

func TestFirstContentExplorationMedianPricingTaggedForDeadlineExemptAttempts(t *testing.T) {
	for _, vision := range []bool{false, true} {
		for _, suppressed := range []bool{false, true} {
			f := newPricingFixture(t, 10*time.Minute, true)
			p := f.fresh(t)
			p.Mu().Lock()
			p.Models[0].IsVision = vision
			p.Mu().Unlock()
			if suppressed {
				f.registry.RecordFirstContentExplorationOutcome(p.ID, pricingModel, false)
			}
			pr := pricingRequest("deadline-exempt")
			pr.FirstContentDeadline, pr.RequiresVision = time.Time{}, vision
			selected, decision := f.registry.ReserveProviderEx(pricingModel, pr)
			if selected != p || pr.FirstContentExplored() == suppressed {
				t.Fatalf("vision=%v suppressed=%v selected=%v explored=%v", vision, suppressed, selected, pr.FirstContentExplored())
			}
			prefill, _ := pricedRates(t, decision)
			want := pricingPrefillMedian
			if suppressed {
				want = pricingStaticPrefill
			}
			assertRate(t, "prefill", prefill, want)
		}
	}
}

func TestFirstContentExplorationHeartbeatRejectsInvalidExplicitDecodeEvidence(t *testing.T) {
	for _, tc := range []struct {
		name   string
		change func(*protocol.PerformanceMeasurements)
	}{
		{"changed_rate_without_count", func(m *protocol.PerformanceMeasurements) { m.Decode.TokensPerSecond++ }},
		{"regressed_count", func(m *protocol.PerformanceMeasurements) { m.Decode.SampleCount--; m.Decode.TokensPerSecond++ }},
		{"zero_count", func(m *protocol.PerformanceMeasurements) { m.Decode.SampleCount = 0; m.Decode.TokensPerSecond++ }},
		{"negative_age", func(m *protocol.PerformanceMeasurements) { m.Decode.SampleAgeMS = -1; m.Decode.TokensPerSecond++ }},
		{"oversized_age", func(m *protocol.PerformanceMeasurements) {
			m.Decode.SampleAgeMS = int64((8 * 24 * time.Hour) / time.Millisecond)
			m.Decode.TokensPerSecond++
		}},
		{"oversized_epoch", func(m *protocol.PerformanceMeasurements) {
			m.Epoch = strings.Repeat("x", 65)
			m.Decode.TokensPerSecond++
		}},
		{"missing_epoch", func(m *protocol.PerformanceMeasurements) { m.Epoch = ""; m.Decode.TokensPerSecond++ }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f, gates := backoffExplorationPair(t)
			capacity := f.idle.BackendCapacitySnapshot()
			capacity.CapacitySeq = 1
			m := localRateMeasurements(1200, 10)
			m.Decode.SampleCount = 10
			capacity.Slots[0].PerformanceMeasurements = m
			if !f.registry.Heartbeat(f.idle.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: capacity}) {
				t.Fatal("valid baseline heartbeat rejected")
			}
			for range 8 {
				capacity.CapacitySeq++
				tc.change(m)
				if !f.registry.Heartbeat(f.idle.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: capacity}) {
					t.Fatal("heartbeat must retain liveness while rejecting invalid evidence")
				}
			}
			view := gates.ViewForSession(nil, f.idle.ID).Exploration(explorationBackoffModel, time.Now())
			if view.DecodeSamples != 1 || view.RememberedSlow(80) {
				t.Fatalf("rejected explicit reports corroborated exploration suppression: %+v", view)
			}
		})
	}
}

func TestFirstContentExplorationHeartbeatInvalidMetadataCannotReplayDecode(t *testing.T) {
	for _, tc := range []struct {
		name   string
		change func(*protocol.PerformanceMeasurements)
	}{
		{"negative_age", func(m *protocol.PerformanceMeasurements) { m.Decode.SampleAgeMS = -1 }},
		{"zero_count", func(m *protocol.PerformanceMeasurements) { m.Decode.SampleCount = 0 }},
		{"missing_decode", func(m *protocol.PerformanceMeasurements) { m.Decode = nil }},
		{"missing_epoch", func(m *protocol.PerformanceMeasurements) { m.Epoch = "" }},
		{"oversized_epoch", func(m *protocol.PerformanceMeasurements) { m.Epoch = strings.Repeat("x", 65) }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f, gates := backoffExplorationPair(t)
			capacity := f.idle.BackendCapacitySnapshot()
			for i := range 9 {
				m := localRateMeasurements(1200, 10)
				m.Decode.SampleCount = 10
				if i%2 == 1 {
					tc.change(m)
				}
				capacity.CapacitySeq = uint64(i + 1)
				capacity.Slots[0].PerformanceMeasurements = m
				if !f.registry.Heartbeat(f.idle.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: capacity}) {
					t.Fatal("heartbeat must retain liveness while rejecting invalid evidence")
				}
			}
			view := gates.ViewForSession(nil, f.idle.ID).Exploration(explorationBackoffModel, time.Now())
			if view.DecodeSamples != 1 || view.RememberedSlow(80) {
				t.Fatalf("invalid metadata let one sample corroborate slow-rate suppression: %+v", view)
			}
			capacity.CapacitySeq++
			capacity.Slots[0].PerformanceMeasurements.Decode.SampleCount++
			if !f.registry.Heartbeat(f.idle.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: capacity}) {
				t.Fatal("new valid sample rejected")
			}
			if got := gates.ViewForSession(nil, f.idle.ID).Exploration(explorationBackoffModel, time.Now()).DecodeSamples; got != 2 {
				t.Fatalf("new sample after invalid metadata counted %d times, want 2 total", got)
			}
		})
	}
}

func TestFirstContentExplorationHeartbeatCountsValidDecodeEpochChange(t *testing.T) {
	f, gates := backoffExplorationPair(t)
	capacity := f.idle.BackendCapacitySnapshot()
	capacity.CapacitySeq = 1
	m := localRateMeasurements(1200, 10)
	m.Decode.SampleCount = 10
	capacity.Slots[0].PerformanceMeasurements = m
	for i := range 2 {
		if !f.registry.Heartbeat(f.idle.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: capacity}) {
			t.Fatal("valid heartbeat rejected")
		}
		if got := gates.ViewForSession(nil, f.idle.ID).Exploration(explorationBackoffModel, time.Now()).DecodeSamples; got != i+1 {
			t.Fatalf("epoch %d: got %d observations, want %d", i, got, i+1)
		}
		capacity.CapacitySeq++
		m.Epoch, m.Decode.SampleCount = "restarted", 1
	}
}

func TestFirstContentExplorationReviewedProfileIsNotMedianPriced(t *testing.T) {
	now := time.Now()
	throughput := production.NewTPSRegistry()
	r, p, profile := reviewedServingProvider(t, func(deps *production.Dependencies) {
		deps.Throughput = throughput
		deps.ConnectionOrigin = func(string, time.Time) *connectiontime.Origin { return connectiontime.New(now.Add(-time.Hour)) }
	})
	for range 10 {
		throughput.Record(profile.ModelID, p.Hardware.ChipFamily, 52)
		throughput.RecordPrefill(profile.ModelID, p.Hardware.ChipFamily, 2000)
	}
	p.Mu().Lock()
	p.CapacityAcceptedAt = now
	zero, initialized := int64(0), false
	p.BackendCapacity.Slots[0].Telemetry = &protocol.SlotTelemetry{QueuedPrefillTokens: &zero, PartialPrefillRows: &zero, EWMAInitialized: &initialized}
	p.Mu().Unlock()
	pr := &production.PendingRequest{RequestID: "reviewed-median", Model: profile.ModelID, EstimatedPromptTokens: 500, RequestedMaxTokens: 128}
	selected, decision := r.ReserveProviderEx(profile.ModelID, pr)
	if selected != p || pr.FirstContentExplored() {
		t.Fatalf("reviewed profile misclassified as explored: selected=%v explored=%v", selected, pr.FirstContentExplored())
	}
	assertRate(t, "profile decode", decision.EffectiveTPS, 90)
	if _, noted := production.RecordTTFTObservation(pr.RequestID, pr.Attempt, decision.RawTTFTMs); !noted {
		t.Fatal("qualified profile prediction was incorrectly withheld from calibration")
	}
}
