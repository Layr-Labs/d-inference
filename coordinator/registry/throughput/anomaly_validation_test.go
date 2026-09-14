package throughput

import (
	"math"
	"testing"
)

func TestThroughputAnomalyNonFiniteConfigUsesDefaults(t *testing.T) {
	for _, in := range []AnomalyInput{
		{Model: "gpt-oss-20b", ChipClass: "M3 Max", ObservedTPS: 69, Samples: 10},
		{Model: "gemma-4-26b", ChipClass: "M3 Max", ObservedTPS: 21, Samples: 10},
	} {
		want := DefaultPolicy().EvaluateAnomaly(in, DefaultAnomalyConfig())
		for _, value := range []float64{math.NaN(), math.Inf(1), math.Inf(-1)} {
			for _, field := range []string{"efficiency", "ratio"} {
				cfg := DefaultAnomalyConfig()
				if field == "efficiency" {
					cfg.Efficiency = value
				} else {
					cfg.RatioThreshold = value
				}
				if got := DefaultPolicy().EvaluateAnomaly(in, cfg); got != want {
					t.Errorf("%s non-finite %s=%v changed verdict: got %+v want %+v", in.Model, field, value, got, want)
				}
			}
		}
	}
}

func TestThroughputAnomalyInvalidMeasurementsAreNotAnomalies(t *testing.T) {
	for _, value := range []float64{math.NaN(), math.Inf(1), math.Inf(-1)} {
		in := AnomalyInput{Model: "gpt-oss-20b", ChipClass: "M3 Max", ObservedTPS: value, Samples: 10}
		if got := DefaultPolicy().EvaluateAnomaly(in, DefaultAnomalyConfig()); got.Evaluated || got.Anomalous || got.SkipReason != "no_observation" {
			t.Errorf("invalid observation %v was evaluated: %+v", value, got)
		}
		in.ObservedTPS, in.BandwidthGBps = 69, value
		if got := DefaultPolicy().EvaluateAnomaly(in, DefaultAnomalyConfig()); !got.Evaluated || got.Anomalous || got.BandwidthGBps != 400 {
			t.Errorf("invalid bandwidth %v did not use class fallback: %+v", value, got)
		}
		for index := range 4 {
			inputs := []float64{3.6e9, BytesPerParam4Bit, 400, .8}
			inputs[index] = value
			if got := ExpectedDecodeTPS(inputs[0], inputs[1], inputs[2], inputs[3]); got != 0 {
				t.Errorf("invalid input %d=%v yielded expectation %v", index, value, got)
			}
		}
	}
	if got := ExpectedDecodeTPS(1, 1, math.MaxFloat64, 2); got != 0 {
		t.Errorf("overflowed expectation=%v", got)
	}
}
