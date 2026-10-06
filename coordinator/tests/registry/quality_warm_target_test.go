package registry_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"
)

// TestWarmTargetDedicatedWholePool: for a dedicated model UNDER DEMAND the
// warm-pool target is the entire eligible pool (warm + eligibleCold), so idle
// dedicated boxes get warmed. With NO demand for that build it is left at the
// demand-derived count (so an idle/stale build — e.g. the previous build during
// an alias migration — is not force-warmed across the whole pool). A
// non-dedicated model with no pressure is left at its current warm count.
func TestWarmTargetDedicatedWholePool(t *testing.T) {
	reg := newQualityRegistry(testLogger())
	reg.SetDedicatedModels([]string{"gemma-4"})
	reg.ConfigureWarmPool(warmplan.Config{
		DecodeFloorTPS:             15,
		FallbackQualityConcurrency: 4,
		BurstBuffer:                1,
		AssumedPromptTokens:        512,
		AssumedCompletionTokens:    256,
		// Realistic pressure thresholds (≥1) so a zero-pressure snapshot registers NO
		// demand pressure — otherwise the 0>=0 default makes every model look pressured.
		CapacityRejectThreshold:   1,
		TTFTMissThreshold:         1,
		ColdDispatchThreshold:     1,
		SpeculativeStartThreshold: 1,
		SpeculativeWinThreshold:   1,
		WarmSaturationThreshold:   0.8,
	})
	c := reg.runtime
	params := c.TargetParams()
	now := time.Now()

	dedicated := warmplan.Fleet{
		Model:         gemmaBuild,
		Warm:          2,
		SoloDecodeTPS: 23,
		PrefillTPS:    276,
		EligibleCold: []warmplan.Candidate{
			{ProviderID: "c1"}, {ProviderID: "c2"}, {ProviderID: "c3"},
		},
	}
	svc := warmplan.EstimateServiceTime(dedicated.PrefillTPS, dedicated.SoloDecodeTPS, params)
	// Under demand (a capacity reject) → warm the whole eligible pool (2 + 3 = 5).
	underDemand := warmplan.Pressure{CapacityRejects: 1}
	if got := c.TargetWarm(dedicated, underDemand, warmplan.QueuePressure{}, params, svc, now); got != 5 {
		t.Fatalf("dedicated (under demand) warm target = %d, want 5 (warm 2 + eligibleCold 3 = whole pool)", got)
	}
	// No demand for this build → NOT force-warmed across the pool (left demand-derived).
	if got := c.TargetWarm(dedicated, warmplan.Pressure{}, warmplan.QueuePressure{}, params, svc, now); got == 5 {
		t.Fatalf("dedicated (no demand) warm target = %d, want < 5 (idle/stale build must not force-warm the whole pool)", got)
	}

	nonDedicated := warmplan.Fleet{
		Model:         qwenBuild,
		Warm:          2,
		SoloDecodeTPS: 57,
		PrefillTPS:    684,
		EligibleCold:  []warmplan.Candidate{{ProviderID: "c1"}, {ProviderID: "c2"}, {ProviderID: "c3"}},
	}
	svc2 := warmplan.EstimateServiceTime(nonDedicated.PrefillTPS, nonDedicated.SoloDecodeTPS, params)
	if got := c.TargetWarm(nonDedicated, warmplan.Pressure{}, warmplan.QueuePressure{}, params, svc2, now); got != 2 {
		t.Fatalf("non-dedicated warm target = %d, want 2 (no demand pressure → left as-is)", got)
	}
}
