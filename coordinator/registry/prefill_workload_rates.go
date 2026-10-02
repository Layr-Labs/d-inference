package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

type prefillWorkloadRate struct {
	promptBucket int
	tps          float64
	observedAt   time.Time
}

func snapshotPrefillWorkloadRates(m *protocol.PerformanceMeasurements, acceptedAt time.Time) []prefillWorkloadRate {
	if m == nil || acceptedAt.IsZero() {
		return nil
	}
	var rates []prefillWorkloadRate
	for _, b := range m.WorkloadBuckets {
		if len(rates) == 32 {
			break
		}
		if b.Phase != "prefill" || b.CacheState != "cold" || b.Contention != "isolated" ||
			b.OtherModelActivity || b.ConcurrentRequests > 1 || b.ConcurrentRequests < 0 ||
			!validWorkloadBucket(b.PromptTokenBucket) || !validPerformanceObservation(&b.Observation) {
			continue
		}
		rates = append(rates, prefillWorkloadRate{promptBucket: b.PromptTokenBucket,
			tps: b.Observation.TokensPerSecond,
			observedAt: acceptedAt.Add(-time.Duration(b.Observation.SampleAgeMS)*time.Millisecond -
				time.Duration(firstContentConservativeHandoffMs)*time.Millisecond)})
	}
	return rates
}

func prefillWorkloadBucket(tokens int) int {
	for _, ceiling := range [...]int{1024, 4096, 16384, 32768, 65536} {
		if tokens <= ceiling {
			return ceiling
		}
	}
	return 131072
}

// Shape measurements cap the aggregate rate; they never grant freshness,
// memory credit or authority to extrapolate a short cell to a longer domain.
func capPrefillByWorkload(rate float64, tokens int, samples []prefillWorkloadRate, now time.Time) float64 {
	if tokens <= 0 {
		return rate
	}
	for _, sample := range samples {
		if sample.promptBucket == prefillWorkloadBucket(tokens) && !now.Before(sample.observedAt) &&
			now.Sub(sample.observedAt) <= firstContentPerformanceFreshness && finitePositive(sample.tps) {
			rate = min(rate, sample.tps)
		}
	}
	return rate
}
