package registry

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"time"
)

const maxPerformanceSampleAgeMS = int64(7 * 24 * 60 * 60 * 1000)

func validPerformanceObservation(o *protocol.PerformanceRateObservation) bool {
	return validPerformanceObservationLimit(o, maxPrefillTPS)
}

func validPerformanceObservationLimit(o *protocol.PerformanceRateObservation, maxRate float64) bool {
	return o != nil && finitePositive(o.TokensPerSecond) && o.TokensPerSecond <= maxRate &&
		o.SampleCount > 0 && o.SampleAgeMS >= 0 && o.SampleAgeMS <= maxPerformanceSampleAgeMS
}

func clampPerformanceMeasurements(p *protocol.PerformanceMeasurements) {
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
		if !validPerformanceObservation(*o) {
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
		if (b.Phase != "prefill" && b.Phase != "decode") ||
			(b.CacheState != "cold" && b.CacheState != "reused") ||
			(b.Contention != "isolated" && b.Contention != "contended") ||
			!validWorkloadBucket(b.PromptTokenBucket) || !validWorkloadBucket(b.ContextTokenBucket) ||
			!validPerformanceObservation(&b.Observation) {
			continue
		}
		if b.OtherModelActivity && b.Contention != "contended" {
			continue
		}
		out = append(out, b)
	}
	p.WorkloadBuckets = out
}

func validWorkloadBucket(n int) bool {
	switch n {
	case 1024, 4096, 16384, 32768, 65536, 131072:
		return true
	}
	return false
}

// An unchanged sample can only get older. A changed rate with the same count
// is inconsistent and cannot create fresh evidence. The transport allowance
// conservatively covers ordinary heartbeat delivery in the same forecast model.
func explicitMeasurementTime(o *protocol.PerformanceRateObservation, oldCount int64, oldRate float64,
	oldAt, now time.Time, sameEpoch bool) (time.Time, int64) {
	if !validPerformanceObservation(o) {
		return time.Time{}, 0
	}
	at := now.Add(-time.Duration(o.SampleAgeMS)*time.Millisecond - time.Duration(firstContentConservativeHandoffMs)*time.Millisecond)
	if sameEpoch {
		if o.SampleCount < oldCount || (o.SampleCount == oldCount && o.TokensPerSecond != oldRate) {
			return time.Time{}, oldCount
		}
		if o.SampleCount == oldCount {
			if oldAt.IsZero() {
				return time.Time{}, oldCount
			}
			if oldAt.Before(at) {
				at = oldAt
			}
		}
	}
	return at, o.SampleCount
}
