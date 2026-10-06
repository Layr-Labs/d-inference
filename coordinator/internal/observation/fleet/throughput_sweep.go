package fleet

import (
	"log/slog"
	"sort"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

type DetectorDependencies struct {
	Registry *registry.Registry
	Logger   *slog.Logger
	Incr     func(string, []string)
	Counter  func(model, chip string)
}
type ThroughputDetector struct{ deps DetectorDependencies }

func NewThroughputDetector(deps DetectorDependencies) *ThroughputDetector {
	return &ThroughputDetector{deps: deps}
}

// throughputBucket accumulates observed decode TPS (and reported bandwidths) for
// one (model, chip-class) group across the fleet.
type throughputBucket struct {
	model      string
	chipClass  string
	tpsSamples []float64
	bandwidths []float64
}

// sweepThroughputAnomalies snapshots the fleet, groups observed decode TPS by
// (model, chip-class), evaluates each bucket, and emits on anomalies.
func (s *ThroughputDetector) Sweep(cfg registry.ThroughputAnomalyConfig) {
	for _, b := range s.collectThroughputBuckets() {
		res := registry.EvaluateThroughputAnomaly(registry.ThroughputAnomalyInput{
			Model:         b.model,
			ChipClass:     b.chipClass,
			BandwidthGBps: medianFloat(b.bandwidths), // 0 ⇒ evaluator uses the chip table
			ObservedTPS:   medianFloat(b.tpsSamples),
			Samples:       len(b.tpsSamples),
		}, cfg)
		if res.Anomalous {
			s.emitThroughputAnomaly(res)
		}
	}
}

// collectThroughputBuckets reads every provider's per-model observed decode TPS
// under the provider lock, copies the scalars out, and groups them by
// (model, chip-class). All registry/provider locks are released before the
// caller evaluates or emits.
func (s *ThroughputDetector) collectThroughputBuckets() map[string]*throughputBucket {
	buckets := make(map[string]*throughputBucket)
	s.deps.Registry.ForEachProvider(func(p *registry.Provider) {
		p.Mu().Lock()
		hw := p.Hardware
		var slots []protocol.BackendSlotCapacity
		if p.BackendCapacity != nil {
			slots = append(slots, p.BackendCapacity.Slots...)
		}
		p.Mu().Unlock()

		chipClass := registry.ResolveChipClass(hw.ChipFamily, hw.ChipTier, hw.ChipName)
		if chipClass == "" {
			return
		}
		for _, slot := range slots {
			if slot.Model == "" || slot.ObservedDecodeTPS <= 0 {
				continue
			}
			// Only sample near-solo slots (batch <= 1). The expected-decode bound
			// is a batch≈1 memory-bandwidth ceiling; comparing it against a
			// batch-degraded observed rate would false-flag a healthy model under
			// load. Skipping loaded slots keeps the comparison apples-to-apples.
			if slot.NumRunning > 1 {
				continue
			}
			key := slot.Model + "\x00" + chipClass
			b := buckets[key]
			if b == nil {
				b = &throughputBucket{model: slot.Model, chipClass: chipClass}
				buckets[key] = b
			}
			b.tpsSamples = append(b.tpsSamples, slot.ObservedDecodeTPS)
			if hw.MemoryBandwidthGBs > 0 {
				b.bandwidths = append(b.bandwidths, hw.MemoryBandwidthGBs)
			}
		}
	})
	return buckets
}

// emitThroughputAnomaly records an anomaly to Datadog, the in-process metrics
// registry (visible at /v1/admin/metrics), and the log. The metric is
// routing.throughput_anomaly, tagged {model, chip_family}.
func (s *ThroughputDetector) emitThroughputAnomaly(res registry.ThroughputAnomalyResult) {
	s.deps.Incr("routing.throughput_anomaly", []string{
		"model:" + res.Model,
		"chip_family:" + res.ChipClass,
	})
	s.deps.Counter(res.Model, res.ChipClass)
	s.deps.Logger.Warn("throughput anomaly: model decoding far below active-param class",
		"model", res.Model,
		"chip_family", res.ChipClass,
		"observed_decode_tps", res.ObservedTPS,
		"expected_decode_tps", res.ExpectedTPS,
		"ratio", res.Ratio,
		"active_params", res.ActiveParams,
		"bandwidth_gbps", res.BandwidthGBps,
		"samples", res.Samples,
	)
}

// medianFloat returns the median of xs, or 0 for an empty slice.
func medianFloat(xs []float64) float64 {
	if len(xs) == 0 {
		return 0
	}
	sorted := append([]float64(nil), xs...)
	sort.Float64s(sorted)
	mid := len(sorted) / 2
	if len(sorted)%2 == 0 {
		return (sorted[mid-1] + sorted[mid]) / 2
	}
	return sorted[mid]
}
