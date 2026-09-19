package api

import (
	"encoding/json"
	"math"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestAccountAffinityMetrics(t *testing.T) {
	for _, mode := range []string{"shadow", "on"} {
		t.Run(mode, func(t *testing.T) {
			server := &Server{metrics: NewMetrics()}
			observation := registry.AccountAffinityObservation{
				Mode: mode, Reason: "spill", Evaluated: true, WouldChange: true,
				Applied: mode == "on", Rank: 2, CandidateCount: 3, AddedTTFTMs: 125.5,
			}
			server.emitAccountAffinityMetrics(observation)
			snapshot := server.metrics.Snapshot()
			labels := []MetricLabel{{"mode", mode}, {"reason", "spill"}, {"would_change", "true"}, {"applied", "false"}}
			if observation.Applied {
				labels[3].Value = "true"
			}
			if got := snapshot.Counters[metricKey("routing.account_affinity", labels)]; got != 1 {
				t.Fatalf("decision count = %d, want 1", got)
			}
			for name, want := range map[string]float64{"candidates": 3, "rank": 2, "added_ttft_ms": 125.5} {
				key := metricKey("routing.account_affinity."+name, []MetricLabel{{"mode", mode}})
				if got := snapshot.Histograms[key]; got.Count != 1 || got.Sum != want {
					t.Errorf("%s = %+v, want one sample %v", name, got, want)
				}
			}
		})
	}
}

func TestAccountAffinityMetricsOffAndFallback(t *testing.T) {
	server := &Server{metrics: NewMetrics()}
	server.emitAccountAffinityMetrics(registry.AccountAffinityObservation{Mode: "off"})
	if snapshot := server.metrics.Snapshot(); len(snapshot.Counters) != 0 || len(snapshot.Histograms) != 0 {
		t.Fatal("unevaluated policy emitted metrics")
	}
	server.emitAccountAffinityMetrics(registry.AccountAffinityObservation{
		Mode: "on", Evaluated: true, Reason: "no_eligible_candidate", CandidateCount: 4,
	})
	if snapshot := server.metrics.Snapshot(); len(snapshot.Counters) != 1 || len(snapshot.Histograms) != 1 {
		t.Fatal("fallback must count candidates, without a fictitious zero-load affinity choice")
	}
	// Optional sinks and server lifecycle never affect inference.
	(&Server{}).emitAccountAffinityMetrics(registry.AccountAffinityObservation{Evaluated: true})
	(*Server)(nil).emitAccountAffinityMetrics(registry.AccountAffinityObservation{Evaluated: true})
}

func TestAccountAffinityMetricsRejectNonfiniteAndInvalidSamples(t *testing.T) {
	for _, loadIncrement := range []float64{-1, math.NaN(), math.Inf(1), math.Inf(-1)} {
		server := &Server{metrics: NewMetrics()}
		server.emitAccountAffinityMetrics(registry.AccountAffinityObservation{
			Mode: "on", Evaluated: true, Reason: "preferred", Rank: 1, CandidateCount: 1, AddedTTFTMs: loadIncrement,
		})
		if len(server.metrics.Snapshot().Histograms) != 2 {
			t.Fatalf("invalid load increment %v reached histogram", loadIncrement)
		}
	}
	server := &Server{metrics: NewMetrics()}
	server.emitAccountAffinityMetrics(registry.AccountAffinityObservation{
		Mode: "on", Evaluated: true, Rank: 2, CandidateCount: -1,
	})
	if len(server.metrics.Snapshot().Histograms) != 0 {
		t.Fatal("invalid candidate count or rank reached histogram")
	}
}

func TestAccountAffinityMetricsClosedVocabularyAndBothSinks(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()
	dd := newTestDD(t, collector)
	server := &Server{metrics: NewMetrics(), dd: dd}
	server.emitAccountAffinityMetrics(registry.AccountAffinityObservation{
		Mode: "private-account-id", Reason: "private-hardware-hash", Evaluated: true,
		Rank: 1, CandidateCount: 2, AddedTTFTMs: 0,
	})
	dd.Close()
	packets := collector.drain()
	if got := sumMetric(t, packets, "routing.account_affinity", "mode:unknown", "reason:unknown"); got != 1 {
		t.Fatalf("DogStatsD counter = %v, want 1; packets=%v", got, packets)
	}
	for _, name := range []string{"candidates", "rank", "added_ttft_ms"} {
		if !hasMetric(packets, "routing.account_affinity."+name+":") {
			t.Errorf("DogStatsD histogram %s missing", name)
		}
	}
	snapshotJSON, err := json.Marshal(server.metrics.Snapshot())
	if err != nil {
		t.Fatal(err)
	}
	output := string(snapshotJSON) + strings.Join(packets, "\n")
	for _, secret := range []string{"private-account-id", "private-hardware-hash"} {
		if strings.Contains(output, secret) {
			t.Fatalf("private identity reached metric: %s", secret)
		}
	}
	for _, reason := range []string{"off", "invalid_config", "missing_account", "missing_model", "vision", "no_candidates", "no_known_ttft", "no_identity", "no_eligible_candidate", "preferred", "spill", "plan_fallback"} {
		if got := accountAffinityMetricReason(reason); got != reason {
			t.Errorf("policy reason %q normalized to %q", reason, got)
		}
	}
}
