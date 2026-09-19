package api

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestWarmPoolTelemetryFields(t *testing.T) {
	snap := registry.WarmPoolSnapshot{
		Model:              "model-a",
		TargetWarm:         7,
		WarmProviders:      3,
		EligibleCold:       2,
		ColdIneligible:     4,
		QueueDepth:         5,
		OldestQueueAge:     6 * time.Second,
		CapacityRejects:    8,
		TTFTMisses:         9,
		SpeculativeStarted: 10,
		SpeculativeWon:     11,
		ColdDispatches:     12,
		LoadDurationEWMA:   13 * time.Second,
		ObserveOnly:        true,
		RunningRequests:    14,
		WaitingRequests:    15,
		WarmSaturated:      16,
		WarmForeignBlocked: 17,
		SpillArrivalRate:   18.5,
		OccupancyRamp:      19.5,
		HeadroomProviders:  20,
		ServiceTime:        21 * time.Second,
		QualityConcurrency: 22,
		DemandConcurrency:  23.5,
		ColdDisqualifiers:  map[string]int{"pending_load_or_cooldown": 4},
	}

	fields := warmPoolTelemetryFields(snap)
	want := map[string]any{
		"model":                              "model-a",
		"target_warm":                        7,
		"warm":                               3,
		"eligible_cold":                      2,
		"cold_ineligible":                    4,
		"warm_saturated":                     16,
		"warm_foreign_blocked":               17,
		"occupancy_ramp":                     19.5,
		"headroom_providers":                 20,
		"running":                            14,
		"waiting":                            15,
		"queue_depth":                        5,
		"oldest_queue_age_ms":                int64(6000),
		"spill_arrival_rate":                 18.5,
		"service_time_ms":                    int64(21000),
		"quality_concurrency":                22,
		"demand_concurrency":                 23.5,
		"capacity_rejects":                   8,
		"ttft_misses":                        9,
		"speculative_started":                10,
		"speculative_won":                    11,
		"cold_dispatches":                    12,
		"load_duration_ewma_ms":              int64(13000),
		"actions":                            0,
		"observe_only":                       true,
		"cold_disq_pending_load_or_cooldown": 4,
	}
	if len(fields) != len(want) {
		t.Fatalf("field count = %d, want %d: %#v", len(fields), len(want), fields)
	}
	for key, value := range want {
		if got := fields[key]; got != value {
			t.Errorf("%s = %#v, want %#v", key, got, value)
		}
	}
	if _, nested := fields["cold_disqualifiers"]; nested {
		t.Fatal("cold_disqualifiers must be flattened for Datadog scalar facets")
	}
}
