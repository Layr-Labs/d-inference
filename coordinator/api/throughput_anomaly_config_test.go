package api

import (
	"github.com/eigeninference/d-inference/coordinator/registry"
	"testing"
)

func TestThroughputAnomalyConfigRejectsNonFiniteOverrides(t *testing.T) {
	keys := []string{"EIGENINFERENCE_THROUGHPUT_ANOMALY_RATIO", "EIGENINFERENCE_THROUGHPUT_ANOMALY_EFFICIENCY", "EIGENINFERENCE_THROUGHPUT_ANOMALY_MIN_SAMPLES"}
	for _, key := range keys {
		t.Setenv(key, "")
	}
	want := registry.DefaultThroughputAnomalyConfig()
	for _, key := range keys[:2] {
		for _, value := range []string{"NaN", "+Inf", "-Inf"} {
			t.Run(key+"/"+value, func(t *testing.T) {
				t.Setenv(key, value)
				if got := throughputAnomalyConfigFromEnv(); got != want {
					t.Fatalf("startup config=%+v, want finite defaults %+v", got, want)
				}
			})
		}
	}
}
