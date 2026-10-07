package registry_test

import (
	"fmt"
	"testing"
	"testing/synctest"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/forecast"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestExplorationPricingExplicitRatePresence(t *testing.T) {
	for _, tc := range []struct {
		name        string
		change      func(*protocol.PerformanceMeasurements)
		legacy      bool
		wantDecode  float64
		wantPrefill float64
	}{
		{"missing_decode", func(m *protocol.PerformanceMeasurements) { m.Decode = nil }, false, pricingDecodeMedian, 700},
		{"zero_decode_count", func(m *protocol.PerformanceMeasurements) { m.Decode.SampleCount = 0 }, false, pricingDecodeMedian, 700},
		{"invalid_decode_age", func(m *protocol.PerformanceMeasurements) { m.Decode.SampleAgeMS = -1 }, false, pricingDecodeMedian, 700},
		{"invalid_decode_rate", func(m *protocol.PerformanceMeasurements) { m.Decode.TokensPerSecond = 0 }, false, pricingDecodeMedian, 700},
		{"invalid_epoch", func(m *protocol.PerformanceMeasurements) { m.Epoch = "" }, false, pricingDecodeMedian, pricingPrefillMedian},
		{"regressed_decode_count", func(m *protocol.PerformanceMeasurements) { m.Decode.SampleCount = 1 }, false, pricingDecodeMedian, 700},
		{"decode_changed_without_sample", func(m *protocol.PerformanceMeasurements) {
			m.Decode.SampleCount, m.Decode.TokensPerSecond = 2, 6
		}, false, pricingDecodeMedian, 700},
		{"missing_prefill", func(m *protocol.PerformanceMeasurements) { m.IsolatedPrefill = nil }, false, 5, pricingPrefillMedian},
		{"regressed_prefill_count", func(m *protocol.PerformanceMeasurements) { m.IsolatedPrefill.SampleCount = 1 }, false, 5, pricingPrefillMedian},
		{"fresh_explicit", func(*protocol.PerformanceMeasurements) {}, false, 5, 700},
		{"legacy_undated", func(*protocol.PerformanceMeasurements) {}, true, 5, 700},
	} {
		t.Run(tc.name, func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				f := newPricingFixture(t, forecast.EvidenceExplorationAfter+time.Minute, true)
				p := f.fresh(t)
				p.Mu().Lock()
				slot := &p.BackendCapacity.Slots[0]
				prefill, initialized := 700.0, true
				slot.ObservedDecodeTPS, slot.ObservedPrefillTPS = 5, prefill
				slot.Telemetry.IsolatedPrefillTPS, slot.Telemetry.EWMAInitialized = &prefill, &initialized
				slot.ActiveTokenBudgetMax = pricingPrompt + pricingMaxTokens
				slot.PerformanceMeasurements = localRateMeasurements(prefill, 5)
				slot.PerformanceMeasurements.IsolatedPrefill.SampleCount = 2
				slot.PerformanceMeasurements.Decode.SampleCount = 2
				f.histories[p.ID].Reconcile(p.BackendCapacity, time.Time{}, f.now.Add(-time.Minute), 0)
				if tc.legacy {
					f.histories[p.ID].Reset()
				}
				p.Mu().Unlock()
				capacity := p.BackendCapacitySnapshot()
				capacity.CapacitySeq = 1
				reported := capacity.Slots[0].PerformanceMeasurements
				reported.IsolatedPrefill.SampleCount, reported.Decode.SampleCount = 3, 3
				tc.change(reported)
				if tc.legacy {
					capacity.Slots[0].PerformanceMeasurements = nil
				}
				if !f.registry.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: capacity}) {
					t.Fatal("native performance heartbeat rejected")
				}
				request := pricingRequest(t.Name())
				selected, decision := f.registry.ReserveProviderEx(pricingModel, request)
				if selected != p {
					t.Fatalf("selected=%v, want the only provider: %+v", selected, decision)
				}
				gotPrefill, gotDecode := pricedRates(t, decision)
				assertRate(t, "decode", gotDecode, tc.wantDecode)
				assertRate(t, "prefill", gotPrefill, tc.wantPrefill)
				if tc.wantDecode == pricingDecodeMedian || tc.wantPrefill == pricingPrefillMedian {
					if decision.FirstContent.Status != production.FirstContentUnknown || !request.FirstContentExplored() {
						t.Fatalf("median pricing invented confidence or lost exploration: %+v", decision.FirstContent)
					}
					if _, noted := production.RecordTTFTObservation(request.RequestID, request.Attempt, decision.RawTTFTMs); noted {
						t.Fatal("calibrator learned from median pricing")
					}
				}
				if p.GetPending(request.RequestID) != request || p.BackendCapacitySnapshot().Slots[0].ObservedDecodeTPS != 5 {
					t.Fatal("pricing bypassed reservation or mutated the retained decode rate")
				}
				if candidates, _, _ := f.registry.QuickCapacityCheck(pricingModel, 1, 1, production.RequestTraits{}); candidates != 0 {
					t.Fatal("median pricing bypassed the physical token reservation")
				}
			})
		})
	}
}

func TestExplicitMissingDecodeRecoversSelection(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		f := newPricingFixture(t, forecast.EvidenceExplorationAfter+time.Minute, true)
		f.peer(t)
		p := f.fresh(t)
		capacity := p.BackendCapacitySnapshot()
		capacity.CapacitySeq = 1
		slot := &capacity.Slots[0]
		slot.ObservedDecodeTPS, slot.ObservedPrefillTPS = 5, pricingPrefillMedian
		slot.PerformanceMeasurements = localRateMeasurements(pricingPrefillMedian, 5)
		slot.PerformanceMeasurements.Decode = nil
		if !f.registry.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: capacity}) {
			t.Fatal("native posture-change heartbeat rejected")
		}
		wins := 0
		for i := range 64 {
			request := pricingRequest(fmt.Sprintf("explicit-missing-%d", i))
			selected, decision := f.registry.ReserveProviderEx(pricingModel, request)
			if selected == nil {
				t.Fatal("no provider selected")
			}
			if selected == p {
				wins++
				assertRate(t, "decode", decision.EffectiveTPS, pricingDecodeMedian)
			}
			selected.RemovePending(request.RequestID)
		}
		if wins == 0 {
			t.Fatal("explicitly missing decode remained starved on the retained 5 TPS EWMA")
		}
	})
}
