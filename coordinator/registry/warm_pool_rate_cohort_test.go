package registry

import (
	"testing"
	"time"
)

func TestWarmPoolFleetRatesIncludeWarmAndEligibleColdOnly(t *testing.T) {
	reg := New(testLogger())
	model := "warm-pool-rate-cohort"
	warm := makeSchedulerProvider(t, reg, "warm", model, 23)
	warm.mu.Lock()
	warm.BackendCapacity.Slots[0].ObservedDecodeTPS = 73
	warm.BackendCapacity.Slots[0].ObservedPrefillTPS = 1000
	warm.mu.Unlock()
	makeWarmPoolColdProvider(t, reg, "cold", model, 57, 64, 8)
	ineligible := makeWarmPoolColdProvider(t, reg, "overheated", model, 1000, 64, 8)
	ineligible.mu.Lock()
	ineligible.SystemMetrics.ThermalState = "critical"
	ineligible.mu.Unlock()

	snap := reg.warmPoolFleetSnapshot(time.Now())[model]
	if snap.Warm != 1 || len(snap.EligibleCold) != 1 || snap.ColdIneligible != 1 || snap.ColdDisqualifiers[warmColdThermal] != 1 {
		t.Fatalf("unexpected warm/cold classification: %+v", snap)
	}
	if snap.SoloDecodeTPS != 40 || snap.ServiceDecodeTPS != 65 || snap.PrefillTPS != (1000+57*PrefillToDecodeRatio())/2 {
		t.Fatalf("rate medians must include warm and eligible cold providers only: %+v", snap)
	}
}
