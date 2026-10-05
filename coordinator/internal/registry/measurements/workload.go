package measurements

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/capacityvalue"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// WorkloadRate is a detached cold, isolated prompt-domain observation. It can
// constrain rates but cannot grant freshness, memory credit or calibration.
type WorkloadRate struct {
	PromptBucket int
	TPS          float64
	ObservedAt   time.Time
}

func SnapshotWorkloadRates(m *protocol.PerformanceMeasurements, acceptedAt time.Time, handoff time.Duration) []WorkloadRate {
	if m == nil || acceptedAt.IsZero() {
		return nil
	}
	var rates []WorkloadRate
	for _, b := range m.WorkloadBuckets {
		if len(rates) == 32 {
			break
		}
		if b.Phase != "prefill" || b.CacheState != "cold" || b.Contention != "isolated" ||
			b.OtherModelActivity || b.ConcurrentRequests > 1 || b.ConcurrentRequests < 0 ||
			!capacityvalue.ValidWorkloadBucket(b.PromptTokenBucket) || !capacityvalue.ValidPerformanceObservation(&b.Observation) {
			continue
		}
		rates = append(rates, WorkloadRate{PromptBucket: b.PromptTokenBucket,
			TPS:        b.Observation.TokensPerSecond,
			ObservedAt: acceptedAt.Add(-time.Duration(b.Observation.SampleAgeMS)*time.Millisecond - handoff)})
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

func CapPrefillByWorkload(rate float64, tokens int, samples []WorkloadRate, now time.Time, freshness time.Duration) float64 {
	if tokens <= 0 {
		return rate
	}
	for _, sample := range samples {
		if sample.PromptBucket == prefillWorkloadBucket(tokens) && !now.Before(sample.ObservedAt) &&
			now.Sub(sample.ObservedAt) <= freshness && capacityvalue.FinitePositive(sample.TPS) {
			rate = min(rate, sample.TPS)
		}
	}
	return rate
}
