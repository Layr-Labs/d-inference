package registry

import (
	"math"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestHeartbeatRejectsOverflowingSoloOccupancy(t *testing.T) {
	for _, counts := range [][2]int{{math.MaxInt, 1}, {1, math.MaxInt}, {math.MaxInt, math.MaxInt}} {
		reg := New(testLogger())
		registration := testRegisterMessage()
		provider := reg.Register("busy", nil, registration)
		model := registration.Models[0].ID
		if !reg.Heartbeat(provider.ID, &protocol.HeartbeatMessage{
			BackendCapacity: &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{{
				Model: model, State: "running", NumRunning: counts[0], NumWaiting: counts[1],
				ObservedDecodeTPS: 40,
			}}},
		}) {
			t.Fatal("otherwise valid heartbeat was rejected")
		}
		// Load-inclusive service estimates still accept the reading; a busy
		// box cannot donate the same reading as an uncontended quality rate.
		if got := reg.tpsRegistry.Median(model, registration.Hardware.ChipFamily); got != 40 {
			t.Fatalf("load-inclusive sample was lost: %v", got)
		}
		if rate, samples := reg.tpsRegistry.SoloMedian(model, chipClassKey(registration.Hardware)); rate != 0 || samples != 0 {
			t.Errorf("running/waiting %v produced solo rate %v from %d samples", counts, rate, samples)
		}
	}
}

func TestSoloSampleEligibilityCountsWithoutOverflow(t *testing.T) {
	for _, tc := range []struct {
		name  string
		slots []protocol.BackendSlotCapacity
		want  bool
	}{
		{"idle", nil, true},
		{"single decode", []protocol.BackendSlotCapacity{{NumRunning: 1}}, true},
		{"single waiting", []protocol.BackendSlotCapacity{{NumWaiting: 1}}, true},
		{"peers across slots", []protocol.BackendSlotCapacity{{NumRunning: 1}, {NumWaiting: 1}}, false},
		{"negative report ignored", []protocol.BackendSlotCapacity{{NumRunning: -1}, {NumRunning: 1}}, true},
		{"negative cannot hide peers", []protocol.BackendSlotCapacity{{NumRunning: -1, NumWaiting: 2}}, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := soloSampleEligible(&protocol.BackendCapacity{Slots: tc.slots}); got != tc.want {
				t.Fatalf("solo eligible = %v, want %v", got, tc.want)
			}
		})
	}
	if soloSampleEligible(nil) {
		t.Fatal("missing capacity is not a solo sample")
	}
}
