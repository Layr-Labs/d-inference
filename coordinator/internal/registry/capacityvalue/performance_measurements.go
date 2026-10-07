package capacityvalue

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

const MaxPerformanceSampleAgeMS = int64(7 * 24 * 60 * 60 * 1000)

func ValidPerformanceObservation(o *protocol.PerformanceRateObservation) bool {
	return validPerformanceObservationLimit(o, MaxPrefillTPS)
}

func validPerformanceObservationLimit(o *protocol.PerformanceRateObservation, maxRate float64) bool {
	return o != nil && FinitePositive(o.TokensPerSecond) && o.TokensPerSecond <= maxRate &&
		o.SampleCount > 0 && o.SampleAgeMS >= 0 && o.SampleAgeMS <= MaxPerformanceSampleAgeMS
}

func ClampPerformanceMeasurements(p *protocol.PerformanceMeasurements) {
	if p == nil {
		return
	}
	// Retain the object sentinel on invalid input so malformed new metadata can
	// never fall back to inference from changed legacy EWMAs.
	if p.Epoch == "" || len(p.Epoch) > 64 {
		*p = protocol.PerformanceMeasurements{}
		return
	}
	for _, o := range []**protocol.PerformanceRateObservation{&p.IsolatedPrefill, &p.ContendedPrefill, &p.Decode} {
		if !ValidPerformanceObservation(*o) {
			*o = nil
		}
	}
	// Buffered delivery can legitimately be much faster than engine compute.
	// These diagnostics never establish serving capacity.
	for _, o := range []**protocol.PerformanceRateObservation{&p.DeliveredDecode, &p.EndToEnd} {
		if !validPerformanceObservationLimit(*o, 1e12) {
			*o = nil
		}
	}
	out := make([]protocol.PerformanceWorkloadBucket, 0, min(len(p.WorkloadBuckets), 32))
	for _, b := range p.WorkloadBuckets {
		if len(out) == 32 {
			break
		}
		if (b.Phase != "prefill" && b.Phase != "decode" && b.Phase != "native_media_prefill") ||
			(b.CacheState != "cold" && b.CacheState != "reused") ||
			(b.Contention != "isolated" && b.Contention != "contended") ||
			(b.ConcurrentRequests < 0 || b.ConcurrentRequests > 64 || (b.ConcurrentRequests > 1 && b.Contention != "contended")) ||
			!ValidWorkloadBucket(b.PromptTokenBucket) || !ValidWorkloadBucket(b.ContextTokenBucket) ||
			!ValidPerformanceObservation(&b.Observation) {
			continue
		}
		if b.OtherModelActivity && b.Contention != "contended" {
			continue
		}
		out = append(out, b)
	}
	p.WorkloadBuckets = out
}

func ValidWorkloadBucket(n int) bool {
	switch n {
	case 1024, 4096, 16384, 32768, 65536, 131072:
		return true
	}
	return false
}
