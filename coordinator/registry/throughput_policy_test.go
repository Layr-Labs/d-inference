package registry

import "testing"

// Existing callers may replace the exported tables, not only mutate entries.
// Exercise the registry entrypoint so a stale default-policy alias cannot hide
// the caller's replacement after the implementation moves to throughput.
func TestThroughputPolicyPreservesReplacedTables(t *testing.T) {
	models, chips := ModelDecodeClasses, ChipBandwidthGBps
	t.Cleanup(func() {
		ModelDecodeClasses, ChipBandwidthGBps = models, chips
	})
	ModelDecodeClasses = map[string]ModelDecodeClass{
		"custom": {ActiveParams: 1e9, BytesPerParam: 2},
	}
	ChipBandwidthGBps = map[string]float64{"custom chip": 200}
	in := ThroughputAnomalyInput{Model: "custom", ChipClass: "custom chip", ObservedTPS: 10, Samples: 3}
	cfg := ThroughputAnomalyConfig{Efficiency: 0.5, RatioThreshold: 0.35, MinSamples: 3}
	result := EvaluateThroughputAnomaly(in, cfg)
	if !result.Evaluated || !result.Anomalous || result.ExpectedTPS != 50 || result.Ratio != 0.2 {
		t.Fatalf("replacement policy result = %+v, want expected 50 TPS and anomalous ratio 0.2", result)
	}
	ChipBandwidthGBps["custom chip"] = 100
	result = EvaluateThroughputAnomaly(in, cfg)
	if !result.Evaluated || result.Anomalous || result.ExpectedTPS != 25 || result.Ratio != 0.4 {
		t.Fatalf("mutated policy result = %+v, want expected 25 TPS and healthy ratio 0.4", result)
	}
}
