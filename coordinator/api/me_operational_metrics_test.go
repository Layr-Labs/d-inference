package api

import (
	"encoding/json"
	"reflect"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestProviderOperationalMetricsPreserveCountersWithoutScore(t *testing.T) {
	live := buildMyProvider(nil, &registry.Provider{
		ID: "live",
		Reputation: registry.Reputation{
			TotalJobs: 120, SuccessfulJobs: 118, FailedJobs: 2,
			TotalUptime: 25 * time.Hour, AvgResponseTime: 842 * time.Millisecond,
			ChallengesPassed: 10, ChallengesFailed: 1,
		},
	})
	offline := buildMyProvider(&store.ProviderRecord{ID: "offline"}, nil)
	applyStoredReputation(&offline, &store.ReputationRecord{
		TotalJobs: 120, SuccessfulJobs: 118, FailedJobs: 2,
		TotalUptimeSeconds: 90000, AvgResponseTimeMs: 842,
		ChallengesPassed: 10, ChallengesFailed: 1,
	})
	want := map[string]int64{
		"total_jobs": 120, "successful_jobs": 118, "failed_jobs": 2,
		"total_uptime_seconds": 90000, "avg_response_time_ms": 842,
		"challenges_passed": 10, "challenges_failed": 1,
	}
	for name, provider := range map[string]myProvider{"live": live, "offline": offline} {
		t.Run(name, func(t *testing.T) {
			data, err := json.Marshal(provider)
			if err != nil {
				t.Fatal(err)
			}
			var response struct {
				Reputation map[string]int64 `json:"reputation"`
			}
			if err := json.Unmarshal(data, &response); err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(response.Reputation, want) {
				t.Fatalf("operational metrics = %v, want only %v", response.Reputation, want)
			}
		})
	}
}
