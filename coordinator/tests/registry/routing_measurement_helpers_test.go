package registry_test

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func localRateMeasurements(prefill, decode float64) *protocol.PerformanceMeasurements {
	return &protocol.PerformanceMeasurements{Epoch: "fixture-local",
		IsolatedPrefill: &protocol.PerformanceRateObservation{TokensPerSecond: prefill, SampleCount: 1},
		Decode:          &protocol.PerformanceRateObservation{TokensPerSecond: decode, SampleCount: 1}}
}
