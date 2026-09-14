package throughput

// RecordSolo adds a solo (uncontended-box) decode TPS sample for the given
// model and chip CLASS (chipClassKey — family+tier, not family alone). Callers
// must pre-gate on soloSampleEligible AND on the slot having an actual running
// decode (NumRunning > 0, see the heartbeat ingest in heartbeat.go) so a
// purely-queued box's retained EWMA is not sampled — this method itself only
// validates the sample value, mirroring Record. The tpsKey.ChipFamily field
// carries the chip-class string for solo entries.
func (r *Observations) RecordSolo(model, chipClass string, tps float64) {
	if tps <= 0 || model == "" {
		return
	}
	key := tpsKey{Model: model, ChipFamily: chipClass}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.soloSamples == nil { // zero-value registry
		r.soloSamples = make(map[tpsKey][]float64)
	}
	if r.soloByModel == nil {
		r.soloByModel = make(map[string]map[string]tpsSampleStat)
	}
	// FIFO ring, same shape as Record.
	samples := appendRingSample(r.soloSamples[key], tps, r.maxSamples)
	r.soloSamples[key] = samples
	byClass := r.soloByModel[model]
	if byClass == nil {
		byClass = make(map[string]tpsSampleStat)
		r.soloByModel[model] = byClass
	}
	byClass[chipClass] = tpsSampleStat{median: r.medianOfRingLocked(samples), n: len(samples)}
	r.refreshSoloAllChipsLocked(model)
}

// SoloMedian returns the median solo decode TPS for the given model and chip
// CLASS (chipClassKey) plus the number of samples behind it. (0, 0) when no
// solo samples exist. The count lets callers apply a min-sample trust floor
// before using the median for admission decisions.
func (r *Observations) SoloMedian(model, chipClass string) (float64, int) {
	r.mu.RLock()
	stat := r.soloByModel[model][chipClass]
	r.mu.RUnlock()
	return stat.median, stat.n
}

// SoloMedianAllChips is the CONSERVATIVE cross-class transfer used when a
// provider's own chip class has too few solo samples: it returns the MINIMUM
// of the per-class medians across every chip class that has at least one solo
// sample for the model, the TOTAL sample count across those classes, and the
// number of CLASSES that contributed a positive median.
//
// SAFETY INVARIANT: the resolver must never hand a slow box a rate faster than
// its own class demonstrated. Pooling every sample into one median (the old
// behavior) lets a fast, sample-heavy class dominate and return a rate above a
// slow box's real capability — over-capping it into the very quality collapse
// this cap prevents. Taking the min of per-class medians instead can never
// exceed the slowest class's typical rate: worst case it UNDER-caps a fast box
// (safe, quality-protective), never over-caps a slower one.
//
// That invariant has a precondition the resolver must check, which is why the
// class count is returned: the minimum is only a CROSS-CLASS bound when more
// than one class contributed. With a single sampled class the "min" is just
// that one class's own median wearing the name of a minimum, and handing it to
// a provider of a different, unsampled class bounds nothing at all — one M4
// Max sample would set an unsampled M1 Pro's rate. See
// resolvedSoloModelTPSLocked, which refuses that transfer unless a seed or the
// provider's own samples bound it.
//
// The total sample count keeps the resolver's >= qualityCapSoloMinSamples trust
// floor unchanged. The tpsKey.ChipFamily field carries the chip-class string
// for solo entries, so grouping by key.Model + key.ChipFamily groups by class.
//
// O(1) and allocation-free on read: the aggregate is maintained by RecordSolo
// (medians.go), which is what lets the routing scan resolve the
// quality cap for every provider without copying and sorting the fleet's
// samples per provider.
func (r *Observations) SoloMedianAllChips(model string) (tps float64, samples, classes int) {
	r.mu.RLock()
	agg := r.soloAllChips[model]
	r.mu.RUnlock()
	return agg.minMedian, agg.total, agg.classes
}
