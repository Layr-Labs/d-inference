package registry

import "sort"

// tps_median_cache.go — read-side aggregates for TPSRegistry.
//
// The routing scan reads Median / SoloMedian / SoloMedianAllChips once PER
// PROVIDER per scan (snapshotProviderLockedEx and the quality-concurrency cap
// via resolvedSoloModelTPSLocked). Computing a median on read meant copying
// and sorting up to 50 samples ~1,300 times per request at fleet scale, and
// SoloMedianAllChips additionally allocated a per-class map and copied every
// sample for the model. Samples are bounded (maxSamples per key) and only
// change on heartbeat ingest, so every aggregate is recomputed on WRITE
// (Record / RecordSolo) and read as an O(1) map lookup with zero allocation.
//
// Semantics are byte-for-byte those of the former read-time computation:
// the median of the retained FIFO ring (mean of the two middle values for an
// even count), 0 for an empty key; the AllChips minimum-of-class-medians,
// total sample count and contributing-class count exactly as before.

// tpsSampleStat is the cached aggregate for one (model, chip) sample ring.
type tpsSampleStat struct {
	median float64
	n      int
}

// soloAllChipsStat is the cached cross-class aggregate for one model (see
// SoloMedianAllChips): the minimum per-class solo median, the total sample
// count across every class, and the number of classes with a positive median.
type soloAllChipsStat struct {
	minMedian float64
	total     int
	classes   int
}

// medianOfRingLocked returns the median of samples without mutating them,
// sorting a private scratch copy owned by the registry. Caller holds r.mu for
// writing (the scratch buffer is not safe for concurrent use).
func (r *TPSRegistry) medianOfRingLocked(samples []float64) float64 {
	if len(samples) == 0 {
		return 0
	}
	if cap(r.scratch) < len(samples) {
		// A zero-value registry (maxSamples 0) has an unbounded ring, so the
		// scratch capacity must follow the ring, never the nominal bound.
		capacity := r.maxSamples
		if len(samples) > capacity {
			capacity = len(samples)
		}
		r.scratch = make([]float64, len(samples), capacity)
	}
	sorted := r.scratch[:len(samples)]
	copy(sorted, samples)
	return medianOfCopied(sorted)
}

// appendRingSample appends tps to a FIFO ring bounded at maxSamples, dropping
// the oldest sample when full. The backing array is reused once the ring is
// full (shift-left + overwrite) so steady-state ingest allocates nothing; the
// retained sequence is identical to the former re-slice-and-append form.
func appendRingSample(samples []float64, tps float64, maxSamples int) []float64 {
	if maxSamples > 0 && len(samples) >= maxSamples {
		copy(samples, samples[1:])
		samples[len(samples)-1] = tps
		return samples
	}
	return append(samples, tps)
}

// refreshSoloAllChipsLocked recomputes the cached cross-class aggregate for
// model from the per-class stats. O(classes for the model). Caller holds r.mu
// for writing.
func (r *TPSRegistry) refreshSoloAllChipsLocked(model string) {
	var agg soloAllChipsStat
	for _, stat := range r.soloByModel[model] {
		if stat.n == 0 {
			continue
		}
		agg.total += stat.n
		if stat.median <= 0 {
			continue
		}
		if agg.classes == 0 || stat.median < agg.minMedian {
			agg.minMedian = stat.median
		}
		agg.classes++
	}
	if r.soloAllChips == nil {
		r.soloAllChips = make(map[string]soloAllChipsStat)
	}
	r.soloAllChips[model] = agg
}

// medianOfCopied returns the median of samples, sorting in place (callers pass
// a private copy). 0 for an empty slice.
func medianOfCopied(sorted []float64) float64 {
	if len(sorted) == 0 {
		return 0
	}
	sort.Float64s(sorted)
	mid := len(sorted) / 2
	if len(sorted)%2 == 0 {
		return (sorted[mid-1] + sorted[mid]) / 2
	}
	return sorted[mid]
}
